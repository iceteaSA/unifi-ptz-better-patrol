#!/usr/bin/env bats

load patrol_test_helper

setup() {
  _LOG_LEVEL=3
}

@test "enabled false skips the camera" {
  run enabled_probe '{"enabled":false}'
  assert_contains "$output" "Disabled — skipping"
  assert_not_contains "$output" "preset(s)"
}

@test "enabled absent patrols the camera" {
  run enabled_probe '{}'
  assert_not_contains "$output" "Disabled — skipping"
  assert_contains "$output" "Only 1 preset(s)"
}

@test "enabled null patrols the camera" {
  run enabled_probe '{"enabled":null}'
  assert_not_contains "$output" "Disabled — skipping"
  assert_contains "$output" "Only 1 preset(s)"
}

@test "enabled true patrols the camera" {
  run enabled_probe '{"enabled":true}'
  assert_not_contains "$output" "Disabled — skipping"
  assert_contains "$output" "Only 1 preset(s)"
}
