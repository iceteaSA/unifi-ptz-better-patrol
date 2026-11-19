#!/usr/bin/env bats

load auth_security_helper

setup() { auth_prepare; }

@test "login and GET POST PATCH keep credentials and tokens out of curl and jq argv" {
  run auth_probe argv
  [ "$status" -eq 0 ]
  [[ "$output" == *'__argv-clean'* ]]
  [[ "$output" != *'__secret-in-argv'* ]]
}

@test "login stdin JSON preserves special characters and required Protect fields" {
  run auth_probe payload
  [ "$status" -eq 0 ]
  [[ "$output" == *'__payload-roundtrip'* ]]
}

@test "session header file has exactly two lines and mode 0600 under permissive umask" {
  run auth_probe file
  [ "$status" -eq 0 ]
  [[ "$output" == *'__private-two-headers'* ]]
}

@test "GET POST and PATCH use the header file without inline tokens" {
  run auth_probe requests
  [ "$status" -eq 0 ]
  [[ "$output" == *'header_refs=3 request_files=3'* ]]
}

@test "reauth rewrites the same file with both new tokens" {
  run auth_probe reauth
  [ "$status" -eq 0 ]
  [[ "$output" == *'__rewritten'* ]]
}

@test "failed empty or incomplete reauth cannot reuse prior token headers" {
  local mode
  for mode in failure empty transfer no-csrf; do
    run auth_probe "$mode"
    [ "$status" -eq 0 ]
    [[ "$output" == *'__failure-cleared'* ]]
  done
}

@test "api cleanup removes the session header file" {
  run auth_probe cleanup
  [ "$status" -eq 0 ]
  [[ "$output" == *'__cleaned'* ]]
}
