#!/usr/bin/env bats

load test_helper

setup() {
  _LOG_LEVEL=3
  _LAST_SMART_ACTIVE=0
  _LAST_TRACKING_ACTIVE=1
}

@test "explicit isAutoTracking flag holds patrol" {
  local state='{"id":"cam-1","state":"CONNECTED","isAutoTracking":true}'

  run tracking_probe cam-1 60 0 0 "$state"

  assert_detected_without_failsafe
  assert_contains "$output" "__status=0 smart=1 tracking=1"
}

@test "explicit isPtzAutoTracking flag holds patrol" {
  local state='{"id":"cam-1","state":"CONNECTED","isPtzAutoTracking":true}'

  run tracking_probe cam-1 60 0 0 "$state"

  assert_detected_without_failsafe
  assert_contains "$output" "__status=0 smart=1 tracking=1"
}

@test "explicit isTracking flag holds patrol" {
  local state='{"id":"cam-1","state":"CONNECTED","isTracking":true}'

  run tracking_probe cam-1 60 0 0 "$state"

  assert_detected_without_failsafe
  assert_contains "$output" "__status=0 smart=1 tracking=1"
}

@test "smart detection holds patrol and marks smart activity" {
  local state='{"id":"cam-1","state":"CONNECTED","isSmartDetected":true}'

  run tracking_probe cam-1 60 0 0 "$state"

  assert_detected_without_failsafe
  assert_contains "$output" "__status=0 smart=1 tracking=0"
}

@test "real-time motion holds patrol" {
  local state='{"id":"cam-1","state":"CONNECTED","isMotionDetected":true}'

  run tracking_probe cam-1 60 0 0 "$state"

  assert_detected_without_failsafe
  assert_contains "$output" "__status=0 smart=0 tracking=0"
}

@test "recent lastMotion holds patrol" {
  local now_ms
  now_ms=$(( $(date +%s) * 1000 ))
  local state="{\"id\":\"cam-1\",\"state\":\"CONNECTED\",\"lastMotion\":$((now_ms - 1000))}"

  run tracking_probe cam-1 60 0 0 "$state"

  assert_detected_without_failsafe
  assert_contains "$output" "__status=0 smart=0 tracking=0"
}

@test "stale lastMotion allows patrol to advance" {
  local state='{"id":"cam-1","state":"CONNECTED","lastMotion":0}'

  run tracking_probe cam-1 60 0 0 "$state"

  [ "$status" -eq 1 ]
  assert_contains "$output" "__status=1 smart=0 tracking=0"
  assert_not_contains "$output" "Failed to fetch camera state — assuming active (fail-safe)"
  assert_not_contains "$output" "Invalid camera state response — assuming active (fail-safe)"
}

@test "disconnected camera holds patrol with state reason" {
  local state='{"id":"cam-1","state":"DISCONNECTED"}'

  run tracking_probe cam-1 60 0 0 "$state"

  assert_detected_without_failsafe
  assert_contains "$output" "__status=0 smart=0 tracking=1"
  assert_contains "$output" "Camera state=DISCONNECTED — treating as active"
}

@test "all-clear connected camera is the only advancing state" {
  local state='{"id":"cam-1","state":"CONNECTED","lastMotion":0}'

  run tracking_probe cam-1 60 0 0 "$state"

  [ "$status" -eq 1 ]
  assert_contains "$output" "__status=1 smart=0 tracking=0"
  assert_not_contains "$output" "assuming active (fail-safe)"
}

@test "lastMotion from our goto inside settle window is ignored" {
  local now_s now_ms state
  now_s=$(date +%s)
  now_ms=$(( now_s * 1000 - 100 ))
  state="{\"id\":\"cam-1\",\"state\":\"CONNECTED\",\"lastMotion\":$now_ms}"

  run tracking_probe cam-1 60 "$((now_s - 1))" 20 "$state"

  [ "$status" -eq 1 ]
  assert_contains "$output" "__status=1 smart=0 tracking=0"
  assert_not_contains "$output" "assuming active (fail-safe)"
}

@test "same recent lastMotion outside settle window holds patrol" {
  local now_s now_ms state
  now_s=$(date +%s)
  now_ms=$(( now_s * 1000 - 100 ))
  state="{\"id\":\"cam-1\",\"state\":\"CONNECTED\",\"lastMotion\":$now_ms}"

  run tracking_probe cam-1 60 "$((now_s - 30))" 10 "$state"

  assert_detected_without_failsafe
  assert_contains "$output" "__status=0 smart=0 tracking=0"
}

@test "malformed camera state uses invalid-response fail-safe" {
  run tracking_probe cam-1 60 0 0 'not-json'

  assert_contains "$output" "__status=0 smart=0"
  assert_contains "$output" "tracking=1"
  assert_contains "$output" "Invalid camera state response — assuming active (fail-safe)"
  assert_not_contains "$output" "Failed to fetch camera state — assuming active (fail-safe)"
}

@test "empty camera state uses fetch-failure fail-safe" {
  run tracking_probe cam-1 60 0 0 ""

  assert_contains "$output" "__status=0 smart=0"
  assert_contains "$output" "tracking=1"
  assert_contains "$output" "Failed to fetch camera state — assuming active (fail-safe)"
  assert_not_contains "$output" "Invalid camera state response — assuming active (fail-safe)"
}

@test "state without an id uses the invalid-response fail-safe" {
  run tracking_probe cam-1 60 0 0 '{}'

  assert_contains "$output" "__status=0 smart=0 tracking=1"
  assert_contains "$output" "Invalid camera state response — assuming active (fail-safe)"
  assert_not_contains "$output" "Camera state=false — treating as active"
}

@test "real camera state fixture is all-clear and permits drift checks" {
  local fixture state
  fixture="$BATS_TEST_DIRNAME/fixtures/camera-0.json"
  state=$(jq -c . "$fixture")

  run tracking_probe fixture-camera-0 60 0 0 "$state"

  [ "$status" -eq 1 ]
  assert_contains "$output" "__status=1 smart=0 tracking=0"
  assert_not_contains "$output" "assuming active (fail-safe)"
}
