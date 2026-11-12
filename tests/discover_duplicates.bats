#!/usr/bin/env bats

load discover_duplicates_helper

@test "duplicate name discovery emits no ids when names are unique" {
  run discover_duplicate_names '[{"id":"a","name":"One","is_ptz":true},{"id":"b","name":"Two","is_ptz":true}]'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "duplicate name discovery emits only cameras sharing a PTZ name" {
  run discover_duplicate_names "$cameras"
  [ "$status" -eq 0 ]
  [ "$output" = $'a1\nb2' ]
}

@test "non-PTZ camera with the same name does not make it a duplicate" {
  run discover_duplicate_names '[{"id":"a","name":"Shared","type":"UVC G6 PTZ","is_ptz":true},{"id":"b","name":"Shared","type":"UVC G6 Bullet","is_ptz":false}]'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "duplicate name parsing tolerates a null camera type" {
  local cameras='[{"id":"a","name":"One","is_ptz":false,"type":null}]'
  run discover_duplicate_names "$cameras"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run discover_duplicate_name_groups "$cameras"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "id suffix is empty for every camera when names are unique" {
  local unique='[{"id":"aaaaaa111111","name":"North","is_ptz":true,"type":"UVC G6 PTZ"},{"id":"bbbbbb222222","name":"South","is_ptz":true,"type":"UVC G6 PTZ"}]'
  run discover_id_suffix "$unique" aaaaaa111111
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run discover_id_suffix "$unique" bbbbbb222222
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "id suffix is emitted for every member of a shared-name group only" {
  local shared='[{"id":"aaaaaa111111","name":"North","is_ptz":true,"type":"UVC G6 PTZ"},{"id":"bbbbbb222222","name":"North","is_ptz":true,"type":"UVC G6 PTZ"},{"id":"cccccc333333","name":"South","is_ptz":true,"type":"UVC G6 PTZ"}]'
  run discover_id_suffix "$shared" aaaaaa111111
  [ "$status" -eq 0 ]
  [ "$output" = "111111" ]
  run discover_id_suffix "$shared" bbbbbb222222
  [ "$status" -eq 0 ]
  [ "$output" = "222222" ]
  run discover_id_suffix "$shared" cccccc333333
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
