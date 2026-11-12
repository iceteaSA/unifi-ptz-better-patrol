#!/usr/bin/env bats

load status_webhook_helper

setup() {
  _LOG_LEVEL=3
}

@test "missing or empty webhook URL sends no posts" {
  local config
  for config in '{}' '{"status_webhook_url":""}'; do
    run status_sequence_probe "$config" patrolling:1000:4
    [ "$status" -eq 0 ]
    assert_not_contains "$output" 'Status webhook enabled'
    [ -z "$output" ]
    run status_payloads
    [ "$status" -eq 0 ]
    [ "$output" = '[]' ]
  done
}

@test "bad webhook URL warns once without its value and sends no posts" {
  run status_sequence_probe '{"status_webhook_url":"ftp://example.invalid/private-id"}' patrolling:1000:4
  [ "$status" -eq 0 ]
  [ "$output" = '[api] warn: Invalid status_webhook_url — status webhook disabled' ]
  assert_not_contains "$output" 'private-id'
  run status_payloads
  [ "$status" -eq 0 ]
  [ "$output" = '[]' ]
}

@test "quotes backslashes and control characters cannot inject curl configuration" {
  local url config
  for url in 'https://example.invalid/"secret' 'https://example.invalid/\secret' $'https://example.invalid/secret\nretry = 5' $'https://example.invalid/secret\r' $'https://example.invalid/secret\n'; do
    config=$(jq -nc --arg url "$url" '{status_webhook_url:$url}')
    run status_sequence_probe "$config" patrolling:1000:4
    [ "$status" -eq 0 ]
    [ "$output" = '[api] warn: Invalid status_webhook_url — status webhook disabled' ]
    assert_not_contains "$output" "$url"
    run status_payloads
    [ "$status" -eq 0 ]
    [ "$output" = '[]' ]
  done
}

@test "state changes post the camera state slot and transition time" {
  run status_sequence_probe '{"status_webhook_url":"https://example.invalid/api/webhook/test-secret"}' patrolling:1000:4 holding_manual:1005:4
  [ "$status" -eq 0 ]
  [ "$output" = '[api] info: Status webhook enabled' ]
  run status_payloads
  [ "$status" -eq 0 ]
  [ "$output" = '[{"camera_id":"cam-1","camera":"Overwatch","state":"patrolling","slot":4,"since":1000,"ts":1000,"version":"1.2.0 (main@test)"},{"camera_id":"cam-1","camera":"Overwatch","state":"holding_manual","slot":4,"since":1005,"ts":1005,"version":"1.2.0 (main@test)"}]' ]
}

@test "same state on the next poll sends no post even if the slot changes" {
  run status_sequence_probe '{"status_webhook_url":"https://example.invalid/api/webhook/test-secret"}' patrolling:1000:4 patrolling:1005:2
  [ "$status" -eq 0 ]
  run status_payloads
  [ "$status" -eq 0 ]
  [ "$output" = '[{"camera_id":"cam-1","camera":"Overwatch","state":"patrolling","slot":4,"since":1000,"ts":1000,"version":"1.2.0 (main@test)"}]' ]
}

@test "heartbeat repeats the current state with its original since and latest slot" {
  run status_sequence_probe '{"status_webhook_url":"https://example.invalid/api/webhook/test-secret"}' patrolling:1000:4 patrolling:1299:2 patrolling:1300:2
  [ "$status" -eq 0 ]
  run status_payloads
  [ "$status" -eq 0 ]
  assert_contains "$output" '"slot":2,"since":1000,"ts":1300'
  assert_not_contains "$output" '"ts":1299'
}

@test "heartbeat zero still posts state changes but not repeated states" {
  export STATUS_HEARTBEAT=0
  run status_sequence_probe '{"status_webhook_url":"https://example.invalid/api/webhook/test-secret"}' patrolling:1000:4 patrolling:1300:4 holding_activity:1305:4
  [ "$status" -eq 0 ]
  run status_payloads
  [ "$status" -eq 0 ]
  assert_not_contains "$output" '"ts":1300'
  assert_contains "$output" '"state":"holding_activity","slot":4,"since":1305,"ts":1305'
}

@test "webhook URL is absent from logs and curl arguments and present only in stdin" {
  run status_sequence_probe '{"status_webhook_url":"https://example.invalid/api/webhook/test-secret"}' patrolling:1000:4
  [ "$status" -eq 0 ]
  assert_not_contains "$output" 'test-secret'
  run status_curl_trace args
  [ "$status" -eq 0 ]
  assert_not_contains "$output" 'test-secret'
  assert_contains "$output" $'--max-time\n5'
  assert_contains "$output" $'-K\n-'
  assert_not_contains "$output" '--retry'
  run status_curl_trace stdin
  [ "$status" -eq 0 ]
  [ "$output" = 'url = "https://example.invalid/api/webhook/test-secret"' ]
}

@test "payload escapes a quoted camera name and uses null for an unknown slot" {
  export STATUS_CAMERA_NAME='Gate "East"'
  run status_sequence_probe '{"status_webhook_url":"https://example.invalid/api/webhook/test-secret"}' patrolling:1000:
  [ "$status" -eq 0 ]
  run status_payloads
  [ "$status" -eq 0 ]
  assert_contains "$output" '"camera":"Gate \"East\""'
  assert_contains "$output" '"slot":null'
}

@test "status transport returns before a slow curl finishes" {
  run status_nonblocking_probe
  [ "$status" -eq 0 ]
  assert_contains "$output" '__returned_before_curl=1'
}

@test "patrol dwell and home dwell send heartbeats without slot-change events" {
  run status_patrol_probe '{"dwell_seconds":36,"preset_slots":[0,4],"home_between_cycles":true,"status_heartbeat_seconds":30}'
  [ "$status" -eq 0 ]
  run status_payloads
  [ "$status" -eq 0 ]
  assert_contains "$output" '"state":"patrolling","slot":null,"since":1000,"ts":1000'
  assert_contains "$output" '"slot":0,"since":1000,"ts":1030'
  assert_contains "$output" '"slot":-1,"since":1000,"ts":1092'
  assert_not_contains "$output" '"ts":1036'
}

@test "schedule pause reports paused_schedule and repeats its heartbeat" {
  run status_schedule_probe
  [ "$status" -eq 0 ]
  run status_payloads
  [ "$status" -eq 0 ]
  assert_contains "$output" '"state":"paused_schedule","slot":null,"since":1000,"ts":1000'
  assert_contains "$output" '"state":"paused_schedule","slot":null,"since":1000,"ts":1060'
}

@test "manual hold reports holding_manual" {
  run status_manual_probe
  [ "$status" -eq 0 ]
  assert_contains "$output" 'External control detected'
  run status_payloads
  [ "$status" -eq 0 ]
  assert_contains "$output" '"state":"holding_manual","slot":null,"since":1005,"ts":1005'
}

@test "five minutes of unreadable camera state reports unreadable and keeps it on later failed polls" {
  run status_unreadable_probe
  [ "$status" -eq 0 ]
  assert_contains "$output" 'Camera unreadable for 5m'
  run status_payloads
  [ "$status" -eq 0 ]
  assert_contains "$output" '"state":"holding_activity"'
  assert_contains "$output" '"state":"unreadable","slot":null,"since":1295,"ts":1295'
  assert_not_contains "$output" '"since":1300'
}

@test "shutdown posts stopped in parallel and waits before cleanup with a reentrant EXIT trap" {
  run status_shutdown_probe
  [ "$status" -eq 0 ]
  assert_contains "$output" '__shutdown_completed=3'
  [[ "$output" =~ elapsed=([0-9]+) ]]
  [ "${BASH_REMATCH[1]}" -lt 5 ]
  run status_payloads
  [ "$status" -eq 0 ]
  assert_contains "$output" '"camera_id":"cam-1","camera":"One","state":"stopped","slot":null,"since":1000,"ts":1000'
  assert_contains "$output" '"camera_id":"cam-2","camera":"Two","state":"stopped"'
  assert_contains "$output" '"camera_id":"cam-3","camera":"Three","state":"stopped"'
}

@test "configured zero heartbeat suppresses repeats in the real patrol loop" {
  run status_patrol_probe '{"dwell_seconds":80,"status_heartbeat_seconds":0}'
  [ "$status" -eq 0 ]
  run jq -s 'length' "$BATS_TEST_TMPDIR"/post-*.json
  [ "$status" -eq 0 ]
  [ "$output" = 1 ]
}

@test "invalid heartbeat values warn and use the default" {
  local value
  for value in 29 30.5 '"30"' false; do
    run status_patrol_probe "{\"status_heartbeat_seconds\":$value}"
    [ "$status" -eq 0 ]
    assert_contains "$output" '[Overwatch] warn: Invalid status_heartbeat_seconds — using 300'
  done
}

@test "invalid heartbeat fallback posts after 300 seconds rather than the rejected interval" {
  run status_patrol_probe '{"dwell_seconds":80,"status_heartbeat_seconds":29}'
  [ "$status" -eq 0 ]
  assert_contains "$output" 'Invalid status_heartbeat_seconds — using 300'
  run status_payloads
  [ "$status" -eq 0 ]
  assert_contains "$output" '"since":1000,"ts":1300'
  assert_not_contains "$output" '"ts":1030'
}
