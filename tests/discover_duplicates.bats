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
