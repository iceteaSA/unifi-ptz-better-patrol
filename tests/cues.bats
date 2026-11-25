#!/usr/bin/env bats

load cue_test_helper

@test "cue validation applies defaults and removes duplicate types" {
  run cue_parse_probe '[{"camera_id":"fixed1","slot":4,"types":["person","person","animal"]}]'
  [ "$status" -eq 0 ]
  assert_contains "$output" '__cue=fixed1/4/30/120/'
  assert_contains "$output" $'"person"\t"animal"'
  assert_not_contains "$output" $'"person"\t"person"'
  assert_contains "$output" 'Cues: Fixed One→4'
}

@test "cue type defaults and valid boundary values survive validation" {
  run cue_parse_probe '[{"camera_id":"invalid","slot":0,"hold_seconds":5,"cooldown_seconds":0}]'
  [ "$status" -eq 0 ]
  assert_contains "$output" $'__cue=invalid/0/5/0/\t"person"\t'
  assert_contains "$output" '__count=1 warnings=0'
}

@test "cue slots use actual presets rather than the configured patrol path" {
  run cue_parse_probe '[{"camera_id":"fixed1","slot":2}]' '{"presets":[{"slot":0},{"slot":4}]}'
  [ "$status" -eq 0 ]
  assert_contains "$output" '__count=0 warnings=1'
  run cue_parse_probe '[{"camera_id":"fixed1","slot":99}]' '{"presets":[{"slot":0},{"slot":4},{"slot":99}]}'
  [ "$status" -eq 0 ]
  assert_contains "$output" '__cue=fixed1/99/30/120/'
  assert_contains "$output" '__count=1 warnings=0'
}

@test "cue camera names are read once per distinct source with one fallback warning" {
  CUE_CODE=503
  run cue_parse_probe '[{"camera_id":"fixed1","slot":4},{"camera_id":"fixed1","slot":2}]'
  [ "$status" -eq 0 ]
  assert_contains "$output" '__count=2 warnings=1'
  assert_contains "$output" 'Cues: fixed1→4, fixed1→2'
  local requests=${output//__request=\/cameras\/fixed1/}
  local needle='__request=/cameras/fixed1'
  [ "$(( ${#output} - ${#requests} ))" -eq "${#needle}" ]
}

@test "each invalid cue entry is dropped with one warning" {
  local entry
  for entry in \
    '{"camera_id":"bad/id","slot":4}' \
    '{"camera_id":"","slot":4}' \
    '{"camera_id":"cam1","slot":4}' \
    '{"camera_id":1,"slot":4}' \
    '{"camera_id":"fixed1","slot":99}' \
    '{"camera_id":"fixed1","slot":"4"}' \
    '{"camera_id":"fixed1","slot":4,"types":[]}' \
    '{"camera_id":"fixed1","slot":4,"types":[""]}' \
    '{"camera_id":"fixed1","slot":4,"types":[1]}' \
    '{"camera_id":"fixed1","slot":4,"types":false}' \
    '{"camera_id":"fixed1","slot":4,"hold_seconds":4}' \
    '{"camera_id":"fixed1","slot":4,"hold_seconds":5.5}' \
    '{"camera_id":"fixed1","slot":4,"hold_seconds":false}' \
    '{"camera_id":"fixed1","slot":4,"cooldown_seconds":-1}' \
    '{"camera_id":"fixed1","slot":4,"cooldown_seconds":"0"}' \
    'false'; do
    run cue_parse_probe "[$entry]"
    [ "$status" -eq 0 ]
    assert_contains "$output" '__count=0 warnings=1'
  done
}

@test "non-array cues and overlong camera ids are rejected once" {
  run cue_parse_probe false
  [ "$status" -eq 0 ]
  assert_contains "$output" '__count=0 warnings=1'
  local id
  printf -v id '%065d' 0
  run cue_parse_probe "[{\"camera_id\":\"$id\",\"slot\":4}]"
  [ "$status" -eq 0 ]
  assert_contains "$output" '__count=0 warnings=1'
}

@test "cue URL repeats distinct cameras and empty polls start no jq" {
  run cue_empty_probe
  [ "$status" -eq 0 ]
  assert_contains "$output" '/events?start=880000&end=1000000&types=smartDetectZone&cameras=fixed1&cameras=fixed2'
  assert_not_contains "$output" 'cameras=fixed1,fixed2'
  assert_contains "$output" '__poll_jq=0 pending=-1'
}

@test "UUID event ids fire only once and expire from the seen map" {
  run cue_poll_probe duplicate
  [ "$status" -eq 0 ]
  assert_contains "$output" '__first=0 rc=0 until=1000 seen=1'
  assert_contains "$output" '__second=1 seen=2'
  assert_contains "$output" '__third=-1 seen=2'
  assert_contains "$output" '__pruned=0'
}

@test "cue cooldown starts on fire and rejects new events until expiry" {
  run cue_poll_probe cooldown
  [ "$status" -eq 0 ]
  assert_contains "$output" '__first=0 rc=0 until=1120'
  assert_contains "$output" '__cooldown=-1'
  assert_contains "$output" '__expired=0'
}

@test "config order wins over event order" {
  run cue_poll_probe order
  [ "$status" -eq 0 ]
  assert_contains "$output" 'Cue: One animal → slot 4'
  assert_contains "$output" '__first=0 rc=0'
}

@test "cue for the current slot is skipped without cooldown" {
  run cue_poll_probe current
  [ "$status" -eq 0 ]
  assert_contains "$output" '__first=-1 rc=1 until=0'
}

@test "failed malformed and out-of-window event polls give no cue" {
  local mode
  for mode in failure malformed stale; do
    run cue_poll_probe "$mode"
    [ "$status" -eq 0 ]
    assert_contains "$output" '__first=-1 rc=1 until=0'
  done
}

@test "curl failure after HTTP 200 cannot cue from a stale event body" {
  run cue_transport_probe
  [ "$status" -eq 0 ]
  assert_contains "$output" '__transport=1 pending=-1 http=000 curl=28'
}

@test "closed events still match and any overlapping type can trigger" {
  local mode
  for mode in closed multi-type; do
    run cue_poll_probe "$mode"
    [ "$status" -eq 0 ]
    assert_contains "$output" '__first=0 rc=0'
  done
}

@test "nested camera identifiers cannot match an event from a different camera" {
  run cue_poll_probe nested
  [ "$status" -eq 0 ]
  assert_contains "$output" '__first=-1 rc=1'
}

@test "cue interrupts a short loop look and repeats exactly that step" {
  run cue_integration_probe '{"dwell_seconds":6,"ptz_settle_seconds":0,"cues":[{"camera_id":"fixed1","slot":2,"hold_seconds":5}]}'
  [ "$status" -eq 0 ]
  assert_contains "$output" '__goto=0 now=1000 idx=0'
  assert_contains "$output" '__goto=2 now=1002 idx=0'
  assert_contains "$output" '__goto=0 now=1007 idx=0'
  assert_contains "$output" 'Cue hold ended'
  assert_not_contains "$output" 'Cue hold ended — resuming patrol'
  assert_not_contains "$output" '__forbidden_cue_poll'
}

@test "pingpong resumes its inner reverse step after a cue" {
  CUE_FIRE_SLOT=2 CUE_FIRE_GOTO=3 CUE_FIRE_ELAPSED=4
  run cue_integration_probe '{"path_mode":"pingpong","dwell_seconds":6,"ptz_settle_seconds":0,"cues":[{"camera_id":"fixed1","slot":0,"hold_seconds":5}]}' integration 6
  [ "$status" -eq 0 ]
  assert_contains "$output" '__goto=0 now=1016 idx=3'
  assert_contains "$output" '__goto=4 now=1021 idx=3'
}

@test "a cue on wrap skips home but the next ordinary wrap visits home" {
  CUE_FIRE_SLOT=2 CUE_FIRE_GOTO=3 CUE_FIRE_ELAPSED=4
  run cue_integration_probe '{"home_between_cycles":true,"dwell_seconds":6,"ptz_settle_seconds":0,"cues":[{"camera_id":"fixed1","slot":4,"hold_seconds":5}]}' integration 8
  [ "$status" -eq 0 ]
  assert_contains "$output" '__goto=4 now=1016 idx=0'
  assert_contains "$output" '__goto=0 now=1021 idx=0'
  assert_contains "$output" '__goto=-1 now=1039 idx=0'
}

@test "a cue during home dwell resumes at index zero" {
  CUE_FIRE_SLOT=-1 CUE_FIRE_GOTO=4
  run cue_integration_probe '{"home_between_cycles":true,"dwell_seconds":6,"ptz_settle_seconds":0,"cues":[{"camera_id":"fixed1","slot":4,"hold_seconds":5}]}' integration 7
  [ "$status" -eq 0 ]
  assert_contains "$output" '__goto=-1 now=1018 idx=0'
  assert_contains "$output" '__goto=4 now=1020 idx=0'
  assert_contains "$output" '__goto=0 now=1025 idx=0'
}

@test "activity after a cue does not dynamically skip the selected repeat step" {
  run cue_integration_probe '{"dynamic_auto_tracking":true,"dwell_seconds":6,"ptz_settle_seconds":0,"cues":[{"camera_id":"fixed1","slot":2,"hold_seconds":5}]}' integration-activity 4
  [ "$status" -eq 0 ]
  assert_contains "$output" '__goto=0 now=1009 idx=0'
  assert_contains "$output" '__status=holding_activity source=null slot=2'
  assert_not_contains "$output" '__forbidden_cue_poll'
}

@test "activity blocks cue checks until clear" {
  CUE_FIRE_GOTO=2
  local mode
  for mode in integration-block integration-block-motion; do
    run cue_integration_probe '{"dwell_seconds":12,"ptz_settle_seconds":0,"cues":[{"camera_id":"fixed1","slot":2,"hold_seconds":5}]}' "$mode" 4
    [ "$status" -eq 0 ]
    assert_contains "$output" 'Tracking/motion active — holding'
    assert_contains "$output" 'Cue: Fixed One person → slot 2'
    assert_not_contains "$output" '__forbidden_cue_poll'
  done
}

@test "rejected cue goto is consumed without skipping the next step" {
  run cue_integration_probe '{"dwell_seconds":6,"ptz_settle_seconds":0,"cues":[{"camera_id":"fixed1","slot":2,"hold_seconds":5}]}' integration-reject 4
  [ "$status" -eq 0 ]
  assert_contains "$output" 'Preset slot 2 not found'
  assert_contains "$output" '__goto=0 now=1002 idx=0'
}

@test "cue status carries source then normal patrol clears it" {
  run cue_integration_probe '{"dwell_seconds":6,"ptz_settle_seconds":0,"cues":[{"camera_id":"fixed1","slot":2,"hold_seconds":5}]}' integration 4
  [ "$status" -eq 0 ]
  assert_contains "$output" '__status=cued source=Fixed One slot=2'
  assert_contains "$output" '__status=patrolling source=null slot=2'
}

@test "without cues patrol makes no events request" {
  run cue_integration_probe '{"dwell_seconds":6,"ptz_settle_seconds":0}' integration 4
  [ "$status" -eq 0 ]
  assert_not_contains "$output" '__request=/events'
  assert_not_contains "$output" 'Cue:'
}

@test "non-200 cue polls do not interrupt ordinary patrol" {
  CUE_CODE=503
  run cue_integration_probe '{"dwell_seconds":6,"ptz_settle_seconds":0,"cues":[{"camera_id":"fixed1","slot":2}]}' integration 4
  [ "$status" -eq 0 ]
  assert_contains "$output" '__request=/events'
  assert_contains "$output" '__goto=4 now=1006 idx=1'
  assert_not_contains "$output" 'Cue:'
}

@test "cue goto uses acquisition retries rather than a manual drift hold" {
  run cue_integration_probe '{"dwell_seconds":6,"ptz_settle_seconds":0,"cues":[{"camera_id":"fixed1","slot":2,"hold_seconds":12}]}' integration-acquisition 5
  [ "$status" -eq 0 ]
  assert_contains "$output" 'Goto target not acquired — live pan=8800 tilt=10400 zoom=97, target pan=11600 tilt=10400 zoom=97'
  assert_contains "$output" 'Re-issued goto for slot 2 after failed execution (attempt 1/2'
  assert_contains "$output" 'Goto slot 2 still has not taken effect after 2 retries — advancing patrol'
  assert_contains "$output" '__goto=0 now=1014 idx=0'
  assert_not_contains "$output" 'External control detected'
}

@test "pending cue replaces an unacquired normal target without reissuing it" {
  run cue_integration_probe '{"dwell_seconds":6,"ptz_settle_seconds":3,"cues":[{"camera_id":"fixed1","slot":2,"hold_seconds":5}]}' integration-pending-lag 3
  [ "$status" -eq 0 ]
  assert_contains "$output" '__goto=2 now=1004 idx=0'
  assert_not_contains "$output" 'Re-issued goto for slot 0'
}

@test "completed cue with unreadable positions resumes without reissuing the cue" {
  run cue_integration_probe '{"dwell_seconds":6,"ptz_settle_seconds":0,"cues":[{"camera_id":"fixed1","slot":2,"hold_seconds":5}]}' integration-resume-unacquired 3
  [ "$status" -eq 0 ]
  assert_contains "$output" '__goto=0 now=1007 idx=0'
  assert_not_contains "$output" 'Re-issued goto for slot 2'
}

@test "discovery resolves fixed camera names and flags unknown ids" {
  run cue_discovery_probe
  [ "$status" -eq 0 ]
  assert_contains "$output" 'Side Gate→4 types=["person"] hold=30s cooldown=120s'
  assert_contains "$output" 'missing→2 [unknown camera id]'
}

@test "PATH counters prove twelve disabled cue polls add no processes" {
  run cue_spawn_probe "$BATS_TEST_DIRNAME/.." '{"dwell_seconds":6,"ptz_settle_seconds":0}'
  [ "$status" -eq 0 ]
  assert_contains "$output" '__spawn startup:curl=0,jq=18 poll:curl=12,jq=24 cycle:curl=10,jq=15'
}

@test "PATH counters prove twelve empty cue polls add one curl and no jq each" {
  run cue_spawn_probe "$BATS_TEST_DIRNAME/.." '{"dwell_seconds":6,"ptz_settle_seconds":0,"cues":[{"camera_id":"fixed1","slot":4}]}'
  [ "$status" -eq 0 ]
  assert_contains "$output" '__spawn startup:curl=1,jq=19 poll:curl=24,jq=24 cycle:curl=10,jq=15'
}
