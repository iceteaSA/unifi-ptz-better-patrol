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

@test "login transfer failure identifies the curl exit code without reply content" {
  run auth_probe transfer
  [ "$status" -eq 0 ]
  [[ "$output" == *'Auth failed — login request error (curl rc 28)'* ]]
  [[ "$output" != *'no device token'* && "$output" != *'no CSRF token'* ]]
}

@test "login without device token identifies HTTP status without exposing reply or cookie" {
  run auth_probe failure
  [ "$status" -eq 0 ]
  [[ "$output" == *'Auth failed — no device token in login reply (HTTP 401)'* ]]
  [[ "$output" != *'sample-reply-private'* && "$output" != *'sample-cookie-private'* ]]
  [[ "$output" != *'no CSRF token'* ]]
}

@test "empty login reports the missing device token even without a known HTTP code" {
  run auth_probe empty
  [ "$status" -eq 0 ]
  [[ "$output" == *'Auth failed — no device token in login reply'* ]]
  [[ "$output" != *'(HTTP '* ]]
}

@test "rate-limited login identifies HTTP 429 and clears the old session" {
  run auth_probe rate-limited
  [ "$status" -eq 0 ]
  [[ "$output" == *'Auth failed — login rate-limited (HTTP 429)'* ]]
  [[ "$output" == *'__failure-cleared'* ]]
  [[ "$output" != *'no device token'* && "$output" != *'sample-reply-private'* && "$output" != *'sample-cookie-private'* ]]
}

@test "malformed login reports missing token without leaking parser input" {
  run auth_probe malformed
  [ "$status" -eq 0 ]
  [[ "$output" == *'Auth failed — no device token in login reply (HTTP 200)'* ]]
  [[ "$output" != *'sample-reply-private'* && "$output" != *'sample-cookie-private'* && "$output" != *'parse error'* ]]
}

@test "login without CSRF identifies the missing header only" {
  run auth_probe no-csrf
  [ "$status" -eq 0 ]
  [[ "$output" == *'Auth failed — no CSRF token in login reply'* ]]
  [[ "$output" != *'no device token'* ]]
}

@test "missing CSRF logs its reason under executable strict shell options" {
  run auth_strict_probe
  [ "$status" -eq 1 ]
  [[ "$output" == *'Auth failed — no CSRF token in login reply'* ]]
}
