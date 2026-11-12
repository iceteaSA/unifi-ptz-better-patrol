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

@test "empty preset slot uses camera dwell without an array subscript abort" {
  run field_probe '{"dwell_seconds":1,"ptz_settle_seconds":0,"preset_slots":[0,""]}' 3
  [ "$status" -eq 0 ]
  assert_contains "$output" '__goto= now=1001'
  assert_contains "$output" '__goto=0 now=1002'
  assert_not_contains "$output" 'bad array subscript'
}

@test "rejected goto keeps the previous successful goto settle and poll" {
  FIELD_REJECT_SLOT=4
  FIELD_TRACE_TIMING=1
  local code after_failed
  for code in 404 ''; do
    FIELD_REJECT_CODE=$code
    run field_probe '{"dwell_seconds":6,"ptz_settle_seconds":10,"preset_dwell_seconds":{"4":45}}' 3
    [ "$status" -eq 0 ]
    assert_contains "$output" '__goto=4 now=1006'
    after_failed=${output#*__goto=4 now=1006}
    assert_contains "$after_failed" '__is_tracking settle=3 last_goto_ts=1000 poll=2'
    assert_not_contains "$after_failed" '__is_tracking settle=10'
    assert_contains "$after_failed" '__goto=2 now=1006'
    if [[ "$code" == "404" ]]; then
      assert_contains "$after_failed" 'Preset slot 4 not found (HTTP 404)'
    else
      assert_contains "$after_failed" 'No response from goto command'
    fi
  done
}
