#!/usr/bin/env bats

load tracking_config_helper

setup() {
  _LOG_LEVEL=3
}

@test "tracking types default to person" {
  run tracking_config_probe '{"dynamic_auto_tracking":true}'
  [ "$status" -eq 0 ]
  local body
  IFS= read -r body < "$BATS_TEST_TMPDIR/patch-bodies"
  assert_contains "$body" '"autoTrackingObjectTypes":["person"]'
  assert_contains "$output" 'Auto-tracking enabled (["person"])'
  assert_contains "$output" 'dynamic_tracking=on types=person'
  assert_not_contains "$output" 'warn:'
}

@test "vehicle-capable camera enables person and vehicle" {
  run tracking_config_probe '{"dynamic_auto_tracking":true,"auto_tracking_object_types":["person","vehicle"]}' true
  [ "$status" -eq 0 ]
  local body
  IFS= read -r body < "$BATS_TEST_TMPDIR/patch-bodies"
  assert_contains "$body" '"autoTrackingObjectTypes":["person","vehicle"]'
  assert_contains "$output" 'dynamic_tracking=on types=person,vehicle'
}

@test "unsupported vehicle warns and is dropped" {
  run tracking_config_probe '{"dynamic_auto_tracking":true,"auto_tracking_object_types":["person","vehicle"]}' false
  [ "$status" -eq 0 ]
  local body
  IFS= read -r body < "$BATS_TEST_TMPDIR/patch-bodies"
  assert_contains "$body" '"autoTrackingObjectTypes":["person"]'
  assert_contains "$output" 'warn: Unsupported auto-tracking type "vehicle"'
}

@test "unknown tracking type warns and is dropped" {
  run tracking_config_probe '{"dynamic_auto_tracking":true,"auto_tracking_object_types":["person","animal"]}' true
  [ "$status" -eq 0 ]
  local body
  IFS= read -r body < "$BATS_TEST_TMPDIR/patch-bodies"
  assert_contains "$body" '"autoTrackingObjectTypes":["person"]'
  assert_contains "$output" 'warn: Unknown auto-tracking type "animal"'
}

@test "empty or non-array tracking types warn and fall back to person" {
  local value body
  for value in '[]' '"person"' 'false'; do
    printf '' > "$BATS_TEST_TMPDIR/patch-bodies"
    run tracking_config_probe "{\"dynamic_auto_tracking\":true,\"auto_tracking_object_types\":$value}"
    [ "$status" -eq 0 ]
    IFS= read -r body < "$BATS_TEST_TMPDIR/patch-bodies"
    assert_contains "$body" '"autoTrackingObjectTypes":["person"]'
    assert_contains "$output" 'warn: Invalid or empty auto_tracking_object_types — using ["person"]'
  done
}

@test "configured zoom false is sent in the enable PATCH" {
  run tracking_config_probe '{"dynamic_auto_tracking":true,"auto_tracking_with_zoom":false}'
  [ "$status" -eq 0 ]
  local body
  IFS= read -r body < "$BATS_TEST_TMPDIR/patch-bodies"
  assert_contains "$body" '"autoTrackingWithZoom":false'
  assert_contains "$output" 'types=person zoom=off'
}

@test "configured zoom true is sent in the enable PATCH" {
  run tracking_config_probe '{"dynamic_auto_tracking":true,"auto_tracking_with_zoom":true}'
  [ "$status" -eq 0 ]
  local body
  IFS= read -r body < "$BATS_TEST_TMPDIR/patch-bodies"
  assert_contains "$body" '"autoTrackingWithZoom":true'
  assert_contains "$output" 'types=person zoom=on'
}

@test "unset zoom does not touch the camera setting" {
  run tracking_config_probe '{"dynamic_auto_tracking":true}'
  [ "$status" -eq 0 ]
  local body
  IFS= read -r body < "$BATS_TEST_TMPDIR/patch-bodies"
  assert_not_contains "$body" 'autoTrackingWithZoom'
  assert_not_contains "$output" ' zoom='
}

@test "disabling never sends zoom even when configured" {
  run tracking_disable_probe
  [ "$status" -eq 0 ]
  local body
  IFS= read -r body < "$BATS_TEST_TMPDIR/patch-bodies"
  [ "$body" = '{"smartDetectSettings":{"autoTrackingObjectTypes":[]}}' ]
  assert_not_contains "$body" 'autoTrackingWithZoom'
}

@test "schedule resume keeps the validated types and zoom while pause sends only empty types" {
  run tracking_resume_probe
  [ "$status" -eq 0 ]
  assert_contains "$output" 'Auto-tracking disabled ([])'
  run jq -sc 'map(.smartDetectSettings)' "$BATS_TEST_TMPDIR/patch-bodies"
  [ "$status" -eq 0 ]
  [ "$output" = '[{"autoTrackingObjectTypes":["person","vehicle"],"autoTrackingWithZoom":false},{"autoTrackingObjectTypes":[]},{"autoTrackingObjectTypes":["person","vehicle"],"autoTrackingWithZoom":false}]' ]
}
