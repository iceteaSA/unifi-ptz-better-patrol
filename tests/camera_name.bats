#!/usr/bin/env bats

load field_test_helper

setup() {
  _LOG_LEVEL=3
}

@test "duplicate name suffix is present and an unchanged name is silent" {
  run rename_probe '{"id":"cam-1","name":"Overwatch","state":"CONNECTED"}' abc123
  [ "$status" -eq 0 ]
  assert_contains "$output" '[Overwatch #abc123] info: → Slot 0'
  assert_not_contains "$output" 'Camera renamed in Protect'
}

@test "camera rename logs once then uses new name and retains suffix" {
  run rename_probe '{"id":"cam-1","name":"Gate","state":"CONNECTED"}' abc123
  [ "$status" -eq 0 ]
  assert_contains "$output" "[Overwatch #abc123] info: Camera renamed in Protect: 'Overwatch' → 'Gate'"
  assert_contains "$output" '[Gate #abc123] info: → Slot 4'
  local rest=${output#*Camera renamed in Protect}
  assert_not_contains "$rest" 'Camera renamed in Protect'
}

@test "unique camera keeps an unsuffixed renamed tag" {
  run rename_probe '{"id":"cam-1","name":"Gate","state":"CONNECTED"}'
  [ "$status" -eq 0 ]
  assert_contains "$output" '[Gate] info: → Slot 4'
  assert_not_contains "$output" '#'
}

@test "empty name preserves tag and does not shift tracking fields" {
  run rename_probe '{"id":"cam-1","state":"CONNECTED"}' abc123
  [ "$status" -eq 0 ]
  assert_contains "$output" '[Overwatch #abc123] info: → Slot 4'
  assert_not_contains "$output" 'Camera renamed in Protect'
}

@test "name side channel clears on failed or nameless camera fetch" {
  run name_probe ''
  [ "$status" -eq 0 ]
  assert_contains "$output" '__name=Gate'
  assert_contains "$output" '__next_name='
  assert_not_contains "$output" '__next_name=Gate'
  assert_contains "$output" 'Failed to fetch camera state'
  run name_probe '{"id":"cam-1","state":"CONNECTED","lastMotion":0}'
  [ "$status" -eq 0 ]
  assert_contains "$output" '__name=Gate'
  assert_not_contains "$output" '__next_name=Gate'
  assert_not_contains "$output" 'assuming active (fail-safe)'
}
