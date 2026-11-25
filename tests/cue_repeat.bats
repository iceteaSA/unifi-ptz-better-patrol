#!/usr/bin/env bats

load cue_test_helper

@test "home-dwell cue at the first path slot resumes at the second step" {
  CUE_FIRE_SLOT=-1 CUE_FIRE_GOTO=4
  run cue_integration_probe '{"home_between_cycles":true,"dwell_seconds":6,"ptz_settle_seconds":0,"cues":[{"camera_id":"fixed1","slot":0,"hold_seconds":5}]}' integration 6
  [ "$status" -eq 0 ]
  assert_contains "$output" '__goto=-1 now=1018 idx=0'
  assert_contains "$output" '__goto=0 now=1020 idx=0'
  assert_contains "$output" 'Skipping slot 0 — the cue just held it'
  assert_contains "$output" '__goto=4 now=1025 idx=1'
}

@test "second early cue interruption advances despite a fresh event and zero cooldown" {
  run cue_integration_probe '{"dwell_seconds":20,"ptz_settle_seconds":0,"cues":[{"camera_id":"fixed1","slot":2,"hold_seconds":5,"cooldown_seconds":0}]}' repeat-stream 5
  [ "$status" -eq 0 ]
  assert_contains "$output" '__goto=2 now=1005 idx=0'
  assert_contains "$output" '__goto=0 now=1010 idx=0'
  assert_contains "$output" '__goto=2 now=1015 idx=1'
  assert_contains "$output" '__goto=4 now=1020 idx=1'
}

@test "first early cue interruption still repeats with fresh events at each path step" {
  run cue_integration_probe '{"dwell_seconds":20,"ptz_settle_seconds":0,"cues":[{"camera_id":"fixed1","slot":2,"hold_seconds":5,"cooldown_seconds":0}]}' repeat-stream 3
  [ "$status" -eq 0 ]
  assert_contains "$output" '__goto=2 now=1005 idx=0'
  assert_contains "$output" '__goto=0 now=1010 idx=0'
}

@test "path advance resets the repeat allowance for the next preset" {
  run cue_integration_probe '{"dwell_seconds":20,"ptz_settle_seconds":0,"cues":[{"camera_id":"fixed1","slot":2,"hold_seconds":5,"cooldown_seconds":0}]}' repeat-stream 7
  [ "$status" -eq 0 ]
  assert_contains "$output" '__goto=4 now=1020 idx=1'
  assert_contains "$output" '__goto=2 now=1025 idx=1'
  assert_contains "$output" '__goto=4 now=1030 idx=1'
  assert_not_contains "$output" 'Skipping slot'
}
