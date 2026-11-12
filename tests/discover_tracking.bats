load discover_tracking_helper

@test "tracking output distinguishes G6 and Industrial current state and capability" {
  local cameras='[{"featureFlags":{"isPtz":true,"hasLiveviewTracking":true,"supportPtzVehicleTracking":false},"smartDetectSettings":{"autoTrackingObjectTypes":[],"autoTrackingWithZoom":true}},{"featureFlags":{"isPtz":true,"hasLiveviewTracking":true,"supportPtzVehicleTracking":true},"smartDetectSettings":{"autoTrackingObjectTypes":["person","vehicle"],"autoTrackingWithZoom":false}}]'
  run discover_tracking_lines "$cameras"
  [ "$status" -eq 0 ]
  assert_contains "$output" 'Auto-tracking now: off'
  assert_contains "$output" 'Auto-tracking now: person, vehicle'
  assert_contains "$output" 'Tracking support: person'
  assert_contains "$output" 'Tracking support: person, vehicle'
  assert_contains "$output" 'Tracking with zoom: on'
  assert_contains "$output" 'Tracking with zoom: off'
  assert_not_contains "$output" 'Tracking with zoom: unknown' || :
}

@test "tracking capability and zoom report unknown when fields are absent" {
  run discover_tracking_lines '[{"auto_tracking_types":[]}]'
  [ "$status" -eq 0 ]
  assert_contains "$output" 'Tracking support: unknown'
  assert_contains "$output" 'Tracking with zoom: unknown'
}
