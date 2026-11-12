load discover_tracking_helper

@test "tracking output distinguishes G6 and Industrial current state and capability" {
  local cameras='[{"name":"G6 PTZ","featureFlags":{"isPtz":true,"hasLiveviewTracking":true,"supportPtzVehicleTracking":false},"smartDetectSettings":{"autoTrackingObjectTypes":[],"autoTrackingWithZoom":true}},{"name":"Industrial PTZ","featureFlags":{"isPtz":true,"hasLiveviewTracking":true,"supportPtzVehicleTracking":true},"smartDetectSettings":{"autoTrackingObjectTypes":["person","vehicle"],"autoTrackingWithZoom":false}}]'
  run discover_tracking_lines "$cameras"
  [ "$status" -eq 0 ]
  assert_contains "$output" 'Auto-tracking now: off'
  assert_contains "$output" 'Auto-tracking now: person, vehicle'
  assert_contains "$output" 'Tracking support: person'
  assert_contains "$output" 'Tracking support: person, vehicle'
  assert_contains "$output" 'Tracking with zoom: on'
  assert_contains "$output" 'Tracking with zoom: off'
  assert_contains "$output" $'  G6 PTZ\n  Model:            null\n  ID:               null\n  PTZ (firmware):   true\n  Auto-tracking now: off\n  Tracking support: person\n  Tracking with zoom: on'
  assert_contains "$output" $'  Industrial PTZ\n  Model:            null\n  ID:               null\n  PTZ (firmware):   true\n  Auto-tracking now: person, vehicle\n  Tracking support: person, vehicle\n  Tracking with zoom: off'
}

@test "tracking capability and zoom report unknown when fields are absent" {
  run discover_tracking_lines '[{"name":"Unreported","auto_tracking_types":[]}]'
  [ "$status" -eq 0 ]
  assert_contains "$output" 'Tracking support: unknown'
  assert_contains "$output" 'Tracking with zoom: unknown'
}
