#!/usr/bin/env bats

load startup_spawn_helper

@test "disabled tracking and webhook add no jq processes to patrol startup" {
  run startup_spawn_probe
  [ "$status" -eq 0 ]
  assert_not_contains "$output" 'Invalid status_heartbeat_seconds'
  assert_not_contains "$output" 'Invalid or empty auto_tracking_object_types'
  assert_contains "$output" '__startup_jq=17'
}
