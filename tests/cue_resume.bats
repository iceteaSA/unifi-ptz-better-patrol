#!/usr/bin/env bats

load cue_test_helper

@test "cue end log does not claim patrol resumed before an activity hold" {
  CUE_FIRE_ELAPSED=10
  run cue_integration_probe '{"dynamic_auto_tracking":true,"dwell_seconds":20,"ptz_settle_seconds":0,"cues":[{"camera_id":"fixed1","slot":4,"hold_seconds":5}]}' integration-activity 3
  [ "$status" -eq 0 ]
  assert_contains "$output" 'Cue hold ended'
  assert_not_contains "$output" 'Cue hold ended — resuming patrol'
  [[ "$output" == *'Cue hold ended'*'Tracking/motion active — holding'* ]]
}

@test "completed cue skips its identical next normal step" {
  CUE_FIRE_ELAPSED=10
  run cue_integration_probe '{"dwell_seconds":20,"ptz_settle_seconds":0,"cues":[{"camera_id":"fixed1","slot":4,"hold_seconds":5}]}' integration 3
  [ "$status" -eq 0 ]
  assert_contains "$output" '__goto=4 now=1010 idx=1'
  assert_contains "$output" 'debug: Skipping slot 4 — the cue just held it'
  assert_contains "$output" '__goto=2 now=1015 idx=2'
}

@test "activity-interrupted cue skips its identical next step without a dynamic skip" {
  CUE_FIRE_ELAPSED=10
  run cue_integration_probe '{"dynamic_auto_tracking":true,"dwell_seconds":20,"ptz_settle_seconds":0,"cues":[{"camera_id":"fixed1","slot":4,"hold_seconds":5}]}' integration-activity 3
  [ "$status" -eq 0 ]
  assert_contains "$output" 'Activity during dwell — holding'
  assert_contains "$output" 'Skipping slot 4 — the cue just held it'
  assert_contains "$output" '__goto=2 now=1017 idx=2'
}

@test "same-slot skip on wrap does not visit home" {
  CUE_FIRE_SLOT=4 CUE_FIRE_GOTO=2 CUE_FIRE_ELAPSED=10 CUE_EVENT_START=1020000
  run cue_integration_probe '{"home_between_cycles":true,"dwell_seconds":20,"ptz_settle_seconds":0,"cues":[{"camera_id":"fixed1","slot":2,"hold_seconds":5}]}' integration 4
  [ "$status" -eq 0 ]
  assert_contains "$output" '__goto=2 now=1030 idx=2'
  assert_contains "$output" 'Skipping slot 2 — the cue just held it'
  assert_contains "$output" '__goto=0 now=1035 idx=0'
  assert_not_contains "$output" '__goto=-1'
}

@test "same-slot skip advances only once even if the path has duplicate slots" {
  CUE_FIRE_ELAPSED=10
  run cue_integration_probe '{"preset_slots":[0,4,4,2],"dwell_seconds":20,"ptz_settle_seconds":0,"cues":[{"camera_id":"fixed1","slot":4,"hold_seconds":5}]}' integration 3
  [ "$status" -eq 0 ]
  assert_contains "$output" '__goto=4 now=1015 idx=2'
  local without=${output//Skipping slot 4 — the cue just held it/}
  local message='Skipping slot 4 — the cue just held it'
  [ "$(( ${#output} - ${#without} ))" -eq "${#message}" ]
}

@test "cue before half of a normal dwell repeats that path step" {
  CUE_FIRE_ELAPSED=5
  run cue_integration_probe '{"dwell_seconds":20,"ptz_settle_seconds":0,"cues":[{"camera_id":"fixed1","slot":2,"hold_seconds":5}]}' integration 3
  [ "$status" -eq 0 ]
  assert_contains "$output" '__goto=2 now=1005 idx=0'
  assert_contains "$output" '__goto=0 now=1010 idx=0'
}

@test "cue at exactly half of a normal dwell advances that path step" {
  CUE_FIRE_ELAPSED=10
  run cue_integration_probe '{"dwell_seconds":20,"ptz_settle_seconds":0,"cues":[{"camera_id":"fixed1","slot":2,"hold_seconds":5}]}' integration 3
  [ "$status" -eq 0 ]
  assert_contains "$output" '__goto=2 now=1010 idx=1'
  assert_contains "$output" '__goto=4 now=1015 idx=1'
}

@test "cue after half of a normal dwell advances that path step" {
  CUE_FIRE_ELAPSED=15
  run cue_integration_probe '{"dwell_seconds":20,"ptz_settle_seconds":0,"cues":[{"camera_id":"fixed1","slot":2,"hold_seconds":5}]}' integration 3
  [ "$status" -eq 0 ]
  assert_contains "$output" '__goto=2 now=1015 idx=1'
  assert_contains "$output" '__goto=4 now=1020 idx=1'
}

@test "short-look repeat preserves pingpong path order" {
  CUE_FIRE_SLOT=2 CUE_FIRE_GOTO=3 CUE_FIRE_ELAPSED=5 CUE_EVENT_START=1040000
  run cue_integration_probe '{"path_mode":"pingpong","dwell_seconds":20,"ptz_settle_seconds":0,"cues":[{"camera_id":"fixed1","slot":0,"hold_seconds":5}]}' integration 6
  [ "$status" -eq 0 ]
  assert_contains "$output" '__goto=0 now=1045 idx=2'
  assert_contains "$output" '__goto=2 now=1050 idx=2'
  assert_contains "$output" '__goto=4 now=1070 idx=3'
}

@test "already-there cue and pre-emption keep the original short-look resume step" {
  CUE_FIRE_ELAPSED=5
  run cue_integration_probe '{"dwell_seconds":20,"ptz_settle_seconds":0,"cues":[{"camera_id":"fixed1","slot":0,"hold_seconds":5},{"camera_id":"fixed1","slot":4,"hold_seconds":5}]}' integration 4
  [ "$status" -eq 0 ]
  assert_contains "$output" 'Cue: Fixed One person → slot 0 (already there)'
  assert_contains "$output" 'Cue: Fixed One person → slot 4 (pre-empts Fixed One)'
  assert_contains "$output" '__goto=4 now=1007 idx=0'
  assert_contains "$output" '__goto=0 now=1012 idx=0'
  assert_contains "$output" '__goto=4 now=1032 idx=1'
  assert_not_contains "$output" 'Skipping slot'
}

@test "manual-interrupted cue skips its identical next step after the hold" {
  CUE_FIRE_ELAPSED=10
  run cue_integration_probe '{"dwell_seconds":20,"manual_control_hold_seconds":20,"ptz_settle_seconds":0,"cues":[{"camera_id":"fixed1","slot":4,"hold_seconds":20}]}' integration-cue-manual 3
  [ "$status" -eq 0 ]
  assert_contains "$output" 'External control detected — holding patrol for 20s'
  assert_contains "$output" 'Skipping slot 4 — the cue just held it'
  assert_contains "$output" '__goto=2 now=1050 idx=2'
}

@test "failed-goto exhaustion retains the cue slot for same-slot skipping" {
  CUE_FIRE_ELAPSED=10
  run cue_integration_probe '{"dwell_seconds":20,"ptz_settle_seconds":0,"cues":[{"camera_id":"fixed1","slot":4,"hold_seconds":12}]}' integration-acquisition 5
  [ "$status" -eq 0 ]
  assert_contains "$output" 'Goto slot 4 still has not taken effect after 2 retries'
  assert_contains "$output" 'Skipping slot 4 — the cue just held it'
  assert_contains "$output" '__goto=2 now=1022 idx=2'
}

@test "unsuccessful cue goto codes still skip an identical next step" {
  CUE_FIRE_ELAPSED=10
  local mode
  for mode in integration-reject integration-unexpected; do
    run cue_integration_probe '{"dwell_seconds":20,"ptz_settle_seconds":0,"cues":[{"camera_id":"fixed1","slot":4,"hold_seconds":5}]}' "$mode" 3
    [ "$status" -eq 0 ]
    assert_contains "$output" 'Skipping slot 4 — the cue just held it'
    assert_contains "$output" '__goto=2 now=1010 idx=2'
    assert_not_contains "$output" '__status=cued'
  done
}
