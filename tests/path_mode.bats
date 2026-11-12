#!/usr/bin/env bats

load field_test_helper

setup() {
  _LOG_LEVEL=3
  FIELD_DISCOVERY='{"presets":[{"slot":0},{"slot":1},{"slot":2},{"slot":3}]}'
}

@test "pingpong follows the forward then inner reverse path before wrapping home" {
  run field_probe '{"dwell_seconds":1,"path_mode":"pingpong","home_between_cycles":true}' 8
  [ "$status" -eq 0 ]
  assert_contains "$output" 'Patrol: presets=[0 1 2 3 2 1]'
  assert_contains "$output" 'path=pingpong'
  assert_contains "$output" '__goto=0 now=1000'
  assert_contains "$output" '__goto=1 now=1001'
  assert_contains "$output" '__goto=2 now=1002'
  assert_contains "$output" '__goto=3 now=1003'
  assert_contains "$output" '__goto=2 now=1004'
  assert_contains "$output" '__goto=1 now=1005'
  assert_contains "$output" '__goto=-1 now=1006'
  assert_contains "$output" '__goto=0 now=1007'
}

@test "pingpong with two slots stays unchanged" {
  FIELD_DISCOVERY='{"presets":[{"slot":0},{"slot":1}]}'
  run field_probe '{"dwell_seconds":1,"path_mode":"pingpong"}' 3
  [ "$status" -eq 0 ]
  assert_contains "$output" 'Patrol: presets=[0 1]'
  assert_contains "$output" '__goto=0 now=1002'
}

@test "invalid path warns and uses loop for override slots" {
  run field_probe '{"dwell_seconds":1,"path_mode":"spiral","preset_slots":[0,1,2,3]}' 5
  [ "$status" -eq 0 ]
  assert_contains "$output" "warn: Invalid path_mode 'spiral' — using loop"
  assert_contains "$output" 'Patrol: presets=[0 1 2 3]'
  assert_contains "$output" '__goto=0 now=1004'
  assert_not_contains "$output" 'path=pingpong'
}
