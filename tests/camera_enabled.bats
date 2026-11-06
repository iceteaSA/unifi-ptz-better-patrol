#!/usr/bin/env bats

# patrol_camera reads the camera's merged config before anything else. A
# disabled camera must return at that check. Any other camera must continue to
# the preset fetch, which fails here because test_helper stubs every API GET,
# so the function then returns with the "need 2+" preset warning.

setup() {
  load test_helper
  source "$BATS_TEST_DIRNAME/../patrol.sh"
  _LOG_LEVEL=3
}

enabled_probe() {
  CAM_CONFIG_JSON=$1
  get_camera_config() { printf '%s' "$CAM_CONFIG_JSON"; }
  patrol_camera "cam-1" "TestCam"
  printf '\n__status=%s\n' "$?"
}

@test "enabled false skips the camera" {
  run enabled_probe '{"enabled":false}'
  assert_contains "$output" "Disabled — skipping"
  assert_not_contains "$output" "preset(s)"
}

@test "enabled absent patrols the camera" {
  run enabled_probe '{}'
  assert_not_contains "$output" "Disabled — skipping"
  assert_contains "$output" "Only 0 preset(s)"
}

@test "enabled null patrols the camera" {
  run enabled_probe '{"enabled":null}'
  assert_not_contains "$output" "Disabled — skipping"
  assert_contains "$output" "Only 0 preset(s)"
}

@test "enabled true patrols the camera" {
  run enabled_probe '{"enabled":true}'
  assert_not_contains "$output" "Disabled — skipping"
  assert_contains "$output" "Only 0 preset(s)"
}
