#!/usr/bin/env bats

load large_json_helper

@test "direct discovery CLI prints cues from a raw camera list above 200 KB" {
  run large_probe cli
  [ "$status" -eq 0 ]
  assert_contains "$output" 'Found 1 PTZ camera(s):'
  assert_contains "$output" 'Camera 1→4'
  assert_contains "$output" 'zones=Trail'
  assert_not_contains "$output" 'Argument list too long'
}

@test "cue discovery accepts a camera list above 200 KB without E2BIG" {
  run large_probe cues
  [ "$status" -eq 0 ]
  assert_contains "$output" 'Camera 0→4'
  assert_contains "$output" 'zones=Trail'
  assert_not_contains "$output" 'Argument list too long'
}

@test "PTZ discovery merges a preset reply above 200 KB without E2BIG" {
  run large_probe discovery
  [ "$status" -eq 0 ]
  assert_contains "$output" '__discovered=80'
  assert_not_contains "$output" 'Argument list too long'
}

@test "PTZ discovery merges an API camera object above 200 KB without E2BIG" {
  run large_probe camera
  [ "$status" -eq 0 ]
  assert_contains "$output" '__camera=220000'
  assert_not_contains "$output" 'Argument list too long'
}

@test "duplicate discovery accepts groups above 200 KB without E2BIG" {
  run large_probe groups
  [ "$status" -eq 0 ]
  assert_contains "$output" '__duplicates=3000'
  assert_not_contains "$output" 'Argument list too long'
}

@test "camera config merges an override above 200 KB without E2BIG" {
  run large_probe overrides
  [ "$status" -eq 0 ]
  assert_contains "$output" '__merged=42'
  assert_not_contains "$output" 'Argument list too long'
}

@test "cue parsing accepts preset JSON above 200 KB without E2BIG" {
  run large_probe positions
  [ "$status" -eq 0 ]
  assert_contains "$output" '__entries=1 slot=79'
  assert_not_contains "$output" 'Argument list too long'
}

@test "cue parsing accepts discovery JSON above 200 KB without E2BIG" {
  run large_probe patrol-discovery
  [ "$status" -eq 0 ]
  assert_contains "$output" '__entries=1 slot=79'
  assert_not_contains "$output" 'Argument list too long'
}
