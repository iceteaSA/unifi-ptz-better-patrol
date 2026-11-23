#!/usr/bin/env bats

load cue_zones_helper

setup() {
  ZONE_SOURCE_BODY=$(< "$BATS_TEST_DIRNAME/fixtures/cue-source-zones.json")
}

@test "unfiltered cue still fires without event zones" {
  run zone_probe '[{"camera_id":"fixed1","slot":4}]' no-zones
  [ "$status" -eq 0 ]
  assert_contains "$output" '__first=0 seen=1 warnings=0'
  assert_contains "$output" "__zones[0]=''"
}

@test "zone name resolves integer camera id against string event key" {
  run zone_probe '[{"camera_id":"fixed1","slot":4,"zones":["Trail mouth"]}]'
  [ "$status" -eq 0 ]
  assert_contains "$output" '__first=0 seen=1 warnings=0'
  assert_contains "$output" "__zones[0]=\$'\\t2\\t'"
}

@test "integer and digit-string zone ids match string event keys" {
  local value
  for value in 2 '"2"'; do
    run zone_probe "[{\"camera_id\":\"fixed1\",\"slot\":4,\"zones\":[$value]}]"
    [ "$status" -eq 0 ]
    assert_contains "$output" '__first=0 seen=1 warnings=0'
    assert_contains "$output" "__zones[0]=\$'\\t2\\t'"
  done
}

@test "another zone gives no cue and leaves the event unseen" {
  run zone_probe '[{"camera_id":"fixed1","slot":4,"zones":[2]}]' other
  [ "$status" -eq 0 ]
  assert_contains "$output" '__first=-1 seen=0 warnings=0'
  assert_not_contains "$output" 'Cue: Fixed One'
}

@test "zone status none gives no cue and leaves the event unseen" {
  run zone_probe '[{"camera_id":"fixed1","slot":4,"zones":[2]}]' none
  [ "$status" -eq 0 ]
  assert_contains "$output" '__first=-1 seen=0 warnings=0'
  assert_not_contains "$output" 'Cue: Fixed One'
}

@test "same event entering a cue zone later fires exactly once" {
  run zone_probe '[{"camera_id":"fixed1","slot":4,"zones":[2],"cooldown_seconds":0}]' later
  [ "$status" -eq 0 ]
  assert_contains "$output" '__first=-1 seen=0 warnings=0'
  assert_contains "$output" '__second=0 seen=1'
  assert_contains "$output" '__third=-1 seen=1'
}

@test "unknown zone drops only its cue and keeps the shared source usable" {
  run zone_probe '[{"camera_id":"fixed1","slot":2,"zones":["Missing"]},{"camera_id":"fixed1","slot":4,"zones":[2]}]'
  [ "$status" -eq 0 ]
  assert_contains "$output" 'Cue zone "Missing" not found on Fixed One — ignoring this cue entry'
  assert_contains "$output" '__entries=1'
  assert_contains "$output" 'Cue: Fixed One person → slot 4'
  assert_contains "$output" '__first=0 seen=1 warnings=1'
  assert_contains "$output" '__requests=/cameras/fixed1 /events?'
}

@test "missing or non-object event zones cannot match a filtered cue" {
  local mode
  for mode in no-zones bad-zones; do
    run zone_probe '[{"camera_id":"fixed1","slot":4,"zones":[2]}]' "$mode"
    [ "$status" -eq 0 ]
    assert_contains "$output" '__first=-1 seen=0 warnings=0'
  done
}

@test "two event types and two zones keep both row fields intact" {
  run zone_probe '[{"camera_id":"fixed1","slot":4,"zones":[2],"types":["person"]}]' two-zones
  [ "$status" -eq 0 ]
  assert_contains "$output" '__first=0 seen=1 warnings=0'
  assert_contains "$output" 'Cue: Fixed One person → slot 4'
}

@test "failed source read drops named zones but leaves numeric zones usable" {
  ZONE_SOURCE_CODE=503
  run zone_probe '[{"camera_id":"fixed1","slot":2,"zones":["Trail mouth"]},{"camera_id":"fixed1","slot":4,"zones":[2]}]'
  [ "$status" -eq 0 ]
  assert_contains "$output" 'Cannot resolve cue camera fixed1 — using id'
  assert_contains "$output" 'Cue zone "Trail mouth" not found on fixed1 — ignoring this cue entry'
  assert_contains "$output" '__entries=1'
  assert_contains "$output" '__first=0 seen=1 warnings=2'
}

@test "successful source read rejects a zone id absent from the camera" {
  run zone_probe '[{"camera_id":"fixed1","slot":4,"zones":[99]}]'
  [ "$status" -eq 0 ]
  assert_contains "$output" 'Cue zone "99" not found on Fixed One — ignoring this cue entry'
  assert_contains "$output" '__entries=0'
  assert_contains "$output" '__first=-1 seen=0 warnings=1'
}

@test "exact zone name takes precedence over id text" {
  ZONE_SOURCE_BODY=$(command jq -c '.smartDetectZones += [{"id":5,"name":"2"}]' <<< "$ZONE_SOURCE_BODY")
  run zone_probe '[{"camera_id":"fixed1","slot":4,"zones":["2"]}]' five
  [ "$status" -eq 0 ]
  assert_contains "$output" '__first=0 seen=1 warnings=0'
  assert_contains "$output" "__zones[0]=\$'\\t5\\t'"
}

@test "empty null or invalid zone elements use the invalid-entry warning" {
  local zones
  for zones in '[]' null '{}' '[false]' '[-1]' '[1.5]' '[{}]'; do
    run zone_probe "[{\"camera_id\":\"fixed1\",\"slot\":4,\"zones\":$zones}]"
    [ "$status" -eq 0 ]
    assert_contains "$output" 'Invalid cues entry 0 — ignoring'
    assert_contains "$output" '__entries=0'
  done
}

@test "discovery shows resolved zone names and marks unknown zones" {
  run discover_cue_lines '{"cues":[{"camera_id":"fixed1","slot":4,"zones":[2,"Default","Missing",99]}]}' "[$ZONE_SOURCE_BODY]"
  [ "$status" -eq 0 ]
  assert_contains "$output" 'zones=Trail mouth, Default, Missing [unknown zone], 99 [unknown zone]'
}

@test "zone filters add no startup poll or goto processes" {
  run cue_spawn_probe "$BATS_TEST_DIRNAME/.." '{"dwell_seconds":6,"ptz_settle_seconds":0,"cues":[{"camera_id":"fixed1","slot":4,"zones":["Trail mouth"]}]}'
  [ "$status" -eq 0 ]
  assert_contains "$output" '__spawn startup:curl=1,jq=19 poll:curl=24,jq=24 cycle:curl=10,jq=15'
}
