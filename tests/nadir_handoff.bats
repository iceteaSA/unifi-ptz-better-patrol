#!/usr/bin/env bats

load nadir_handoff_helper

@test "nadir discovery shows the block separately from the cue list" {
  run discover_cue_lines '{"nadir_handoff":{"tilt_min":15800,"sectors":[]}}' '[]'
  assert_contains "$output" 'nadir_handoff:              {"tilt_min":15800,"sectors":[]}'
  assert_contains "$output" 'cues:                       none'
  assert_not_contains "$output" 'invalid'
}

@test "nadir config is per-camera only and does not inherit defaults" {
  NADIR_OVERRIDE='{}'
  run nadir_config_probe
  assert_not_contains "$output" 'nadir_handoff'
  NADIR_OVERRIDE='{"nadir_handoff":{"tilt_min":15800,"sectors":[]}}'
  run nadir_config_probe
  assert_contains "$output" '15800'
  assert_not_contains "$output" '"tilt_min": 1,'
}

@test "nadir invalid config disables only this feature with one warning" {
  local block
  for block in 'null' 'false' '{}' '{"tilt_min":-1,"sectors":[]}' '{"tilt_min":1.5,"sectors":[]}' '{"tilt_min":0,"hold_seconds":4,"sectors":[]}' '{"tilt_min":0,"hold_seconds":null,"sectors":[]}' '{"tilt_min":0,"sectors":{}}' '{"tilt_min":0,"sectors":[{"pan_min":0,"pan_max":1,"slot":9}]}' '{"tilt_min":0,"sectors":[{"pan_min":-1,"pan_max":1,"slot":4}]}' '{"tilt_min":0,"sectors":[{"pan_min":0,"pan_max":1.1,"slot":4}]}' '{"tilt_min":0,"sectors":[false]}'; do
    run nadir_parse_probe "{\"nadir_handoff\":$block}"
    assert_contains "$output" 'Invalid nadir_handoff — disabling nadir hand-off'
    assert_contains "$output" '__enabled=0 tilt=0 hold=20 sectors=0 warnings=1 query='
  done
}

@test "nadir validation shares the cue slot union and defaults to twenty seconds" {
  run nadir_parse_probe '{"nadir_handoff":{"tilt_min":15800,"sectors":[{"pan_min":35000,"pan_max":1000,"slot":7},{"pan_min":0,"pan_max":1,"slot":4}]}}'
  assert_contains "$output" '__enabled=1 tilt=15800 hold=20 sectors=2 warnings=0 query='
  assert_contains "$output" 'Nadir hand-off: tilt_min=15800 sectors=2'
}

@test "nadir unconfigured hold keeps the same request jq and sleep counts" {
  run nadir_hold_probe disabled
  assert_contains "$output" '__counts=jq sleep5 jq'
  assert_not_contains "$output" '__sample'
  assert_contains "$output" 'Tracking ended at pan 18362 tilt 10914 zoom 0'
  assert_not_contains "$output" 'last tracked'
}

@test "nadir empty sectors sample five times and log the crossing" {
  run nadir_hold_probe empty
  assert_contains "$output" 'Nadir hand-off: tilt_min=15800 sectors=0 (logging only)'
  assert_contains "$output" '__counts=jq home sleep1 position jq sleep1 position jq sleep1 position jq sleep1 position jq sleep1 position jq jq'
  assert_contains "$output" 'Nadir crossing: last pan 35000 tilt 16000 zoom 0 (0s ago) — no sector; using cues'
  assert_contains "$output" 'Activity hold ended after 5s (tracking 5s, smart 0s, motion 0s)'
}

@test "nadir sampling starts only after a tracking poll" {
  run nadir_hold_probe later
  assert_not_contains "$output" '__sample now=1001'
  assert_contains "$output" '__sleep=5 now=1000'
  assert_contains "$output" '__sample now=1006'
}

@test "nadir never-tracked holds do not sample position" {
  run nadir_hold_probe never
  assert_not_contains "$output" '__sample'
}

@test "nadir home samples cannot overwrite the last tracked position" {
  run nadir_hold_probe home
  assert_contains "$output" 'Tracking ended at pan 18362 tilt 10914 zoom 0 (last tracked pan 35000 tilt 16000 zoom 0 3s earlier)'
}

@test "nadir failed and malformed reads keep the last tracked sample" {
  local mode
  for mode in failure malformed; do
    run nadir_hold_probe "$mode"
    assert_contains "$output" 'Tracking ended at pan 18362 tilt 10914 zoom 0 (last tracked pan 35000 tilt 16000 zoom 0 3s earlier)'
  done
}

@test "nadir shallow samples skip the decision with a reason" {
  run nadir_hold_probe shallow
  assert_contains "$output" 'Nadir hand-off skipped: tilt 15000 below 15800'
  assert_not_contains "$output" 'Nadir crossing:'
}

@test "nadir decision runs once per activity hold and retains five samples" {
  run nadir_hold_probe once
  local crossings=0 line
  for line in "${lines[@]}"; do [[ "$line" != *'Nadir crossing:'* ]] || crossings=$(( crossings + 1 )); done
  [ "$crossings" -eq 1 ]
  assert_contains "$output" 'Nadir samples: 1001:35000/16000/0 1002:35000/16000/0 1003:35000/16000/0 1004:35000/16000/0 1005:35000/16000/0'
}

@test "nadir logging-only crossing still runs reacquire" {
  run nadir_hold_probe cues
  assert_contains "$output" 'Nadir crossing: last pan 35000 tilt 16000 zoom 0 (0s ago) — no sector; using cues'
  assert_contains "$output" 'Tracking lost — Cue: Horsetrail Up person (Past pole) → slot 4'
}

@test "nadir home read failure skips no samples" {
  run nadir_hold_probe home-failure
  assert_contains "$output" 'last tracked pan 18362 tilt 10914 zoom 0 0s earlier'
}

@test "nadir old missing and future samples give no decision with a reason" {
  local sample
  for sample in 984 0 1001; do
    run nadir_decision_probe "$sample"
    assert_contains "$output" 'Nadir hand-off skipped: no recent sample'
    assert_contains "$output" '__decided=1'
    assert_not_contains "$output" 'Nadir crossing:'
  done
}

@test "nadir ring drops the oldest samples after five" {
  run nadir_ring_probe
  assert_contains "$output" 'Nadir samples: 1006:35000/16000/0 1007:35000/16000/0 1008:35000/16000/0 1009:35000/16000/0 1010:35000/16000/0'
  assert_contains "$output" '__ring=5'
}

@test "nadir sector handoff uses the cue goto status hold and resume without cue polls" {
  run nadir_hold_probe handoff
  assert_contains "$output" 'Nadir hand-off: last pan 35000 tilt 16000 zoom 0 (0s ago) → slot 4'
  assert_contains "$output" '__goto=4 now=1005 cue=1 source=Nadir hand-off'
  assert_contains "$output" '__status=cued source=Nadir hand-off slot=4'
  assert_contains "$output" '__hold source=Nadir hand-off cutoff=1006000 slot=4'
  assert_contains "$output" 'Cue hold ended'
  assert_contains "$output" '__goto=0 now=1025 cue=0 source='
  assert_contains "$output" '__goto=0 now=1025 cue=0 source= cutoff=0'
  assert_not_contains "$output" '__events'
  assert_not_contains "$output" 'Cues:'
}

@test "nadir sector wins before matching reacquire and the internal entry has no debug skips" {
  run nadir_hold_probe priority
  assert_contains "$output" '__goto=4 now=1005 cue=1 source=Nadir hand-off'
  assert_not_contains "$output" 'Tracking lost — Cue:'
  assert_contains "$output" '__events now=1010 cutoff=1006000'
  assert_not_contains "$output" 'Cue skip entry=1'
  assert_contains "$output" 'reason=before-nadir'
}

@test "nadir wrap sector contains the high side of zero" {
  run nadir_hold_probe wrap
  assert_contains "$output" 'Nadir hand-off: last pan 35000 tilt 16000 zoom 0 (0s ago) → slot 4'
}

@test "nadir unmatched sector logs crossing and uses reacquire" {
  run nadir_hold_probe nomatch
  assert_contains "$output" 'Nadir crossing: last pan 35000 tilt 16000 zoom 0 (0s ago) — no sector; using cues'
  assert_contains "$output" 'Tracking lost — Cue: Horsetrail Up person (Past pole) → slot 2'
}

@test "nadir crossing refuses an older or decision-second event" {
  local mode
  for mode in older same-second; do
    run nadir_hold_probe "$mode"
    assert_contains "$output" 'reason=before-nadir'
    assert_contains "$output" '__goto=0 now=1025 cue=0 source='
    assert_not_contains "$output" '(pre-empts Nadir hand-off)'
  done
}

@test "nadir crossing allows a next-second event and clears its cutoff on preemption" {
  run nadir_hold_probe newer
  assert_contains "$output" 'Cue: Horsetrail Up person (Past pole) → slot 2 (pre-empts Nadir hand-off)'
  assert_contains "$output" '__goto=2 now=1010 cue=1 source=Horsetrail Up'
  assert_contains "$output" '__hold source=Horsetrail Up cutoff=0 slot=2'
}

@test "nadir handoff sends a goto even for the last commanded slot" {
  run nadir_hold_probe current
  assert_contains "$output" '__goto=0 now=1000 cue=0 source='
  assert_contains "$output" '__goto=0 now=1007 cue=1 source=Nadir hand-off'
  assert_contains "$output" '__status=cued source=Nadir hand-off slot=0'
}

@test "nadir invalid settings leave valid camera cues enabled" {
  run nadir_parse_probe '{"nadir_handoff":false,"cues":[{"camera_id":"fixed1","slot":4}]}'
  assert_contains "$output" 'Cues: Horsetrail Up→4'
  assert_contains "$output" '__enabled=0 tilt=0 hold=20 sectors=0 warnings=1 query=&cameras=fixed1'
}

@test "nadir no sample omits the tracked suffix" {
  run nadir_hold_probe home-only
  assert_contains "$output" 'Tracking ended at pan 18362 tilt 10914 zoom 0'
  assert_not_contains "$output" 'last tracked'
  assert_contains "$output" 'Nadir hand-off skipped: no recent sample'
}

@test "nadir sector bounds and fifteen-second age are inclusive and config order wins" {
  local pan
  for pan in 34000 35000 36000; do
    run nadir_decision_probe 985 "$pan"
    assert_contains "$output" '__pending=0 slot=4 no_goto=0 cutoff=1001000'
    assert_contains "$output" "Nadir hand-off: last pan $pan tilt 16000 zoom 0 (15s ago) → slot 4"
  done
}

@test "nadir wrap sector also contains the low side of zero" {
  run nadir_decision_probe 995 100 wrap
  assert_contains "$output" '__pending=0 slot=4 no_goto=0 cutoff=1001000'
}

@test "nadir tracking pickup takes over the crossing hold and starts a fresh sample hold" {
  run nadir_hold_probe pickup
  assert_contains "$output" 'Activity during dwell — holding'
  assert_contains "$output" '__status=holding_activity source=null slot=4'
  assert_contains "$output" '__goto=4 now=1015 cue=1 source=Nadir hand-off'
}

@test "nadir tracking flicker rearms the decision within the same activity hold" {
  run nadir_hold_probe flicker
  assert_contains "$output" 'Nadir hand-off skipped: tilt 15000 below 15800'
  assert_contains "$output" '__goto=4 now=1015 cue=1 source=Nadir hand-off'
  local decisions=0 line
  for line in "${lines[@]}"; do [[ "$line" != *'Nadir hand-off: last pan'* ]] || decisions=$(( decisions + 1 )); done
  [ "$decisions" -eq 1 ]
}
