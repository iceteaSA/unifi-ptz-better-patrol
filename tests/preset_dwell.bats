#!/usr/bin/env bats

load field_test_helper

setup() {
  _LOG_LEVEL=3
}

@test "per-preset dwell uses map values and camera fallback with slot timing" {
  run field_probe '{"dwell_seconds":12,"ptz_settle_seconds":10,"preset_dwell_seconds":{"4":"006","2":18}}'
  [ "$status" -eq 0 ]
  assert_contains "$output" '__goto=0 now=1000'
  assert_contains "$output" '__goto=4 now=1012'
  assert_contains "$output" '__goto=2 now=1018'
  assert_contains "$output" '__goto=0 now=1036'
  assert_contains "$output" '__sleep=4 slot=0 settle=6 poll=4'
  assert_contains "$output" '__sleep=2 slot=4 settle=3 poll=2'
  assert_contains "$output" '__sleep=5 slot=2 settle=9 poll=5'
  assert_contains "$output" 'preset_dwell=4:6,2:18'
}

@test "invalid dwell value non-integer key and unknown slot warn and fall back" {
  run field_probe '{"dwell_seconds":6,"preset_dwell_seconds":{"4":0,"2.5":8,"9":8,"2":1.5}}'
  [ "$status" -eq 0 ]
  assert_contains "$output" 'warn: Invalid preset_dwell_seconds entry 4=0'
  assert_contains "$output" 'warn: Invalid preset_dwell_seconds entry 2.5=8'
  assert_contains "$output" 'warn: Invalid preset_dwell_seconds entry 2=1.5'
  assert_contains "$output" 'warn: Unknown patrol slot in preset_dwell_seconds: 9=8'
  assert_not_contains "$output" 'preset_dwell='
  assert_contains "$output" '__goto=0 now=1018'
}

@test "empty dwell map has no startup suffix" {
  run field_probe '{"dwell_seconds":1,"preset_dwell_seconds":{}}' 2
  [ "$status" -eq 0 ]
  assert_contains "$output" 'Patrol: presets=[0 4 2]'
  assert_not_contains "$output" 'preset_dwell='
}

@test "home between cycles keeps camera dwell settle and poll" {
  run field_probe '{"dwell_seconds":6,"ptz_settle_seconds":10,"preset_dwell_seconds":{"0":1,"4":1,"2":1},"home_between_cycles":true}' 5
  [ "$status" -eq 0 ]
  assert_contains "$output" '__goto=-1 now=1003'
  assert_contains "$output" '__goto=0 now=1009'
  assert_contains "$output" '__sleep=2 slot=-1 settle=3 poll=2'
}
