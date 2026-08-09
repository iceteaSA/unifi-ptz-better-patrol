#!/usr/bin/env bats

load patrol_test_helper

setup() {
  _LOG_LEVEL=3
  PTZ_READS=()
  HOME_CAMERA_STATES=()
  PATROL_MODE=""
}

@test "position at previous preset is a failed goto, not external control" {
  run external_probe $'7200\t10400\t97' 11600 10400 97 7100 10400 97

  [ "$status" -eq 1 ]
  assert_contains "$output" "__external_status=1"
  assert_contains "$output" "goto_failed=1"
  assert_not_contains "$output" "PTZ drift detected"
}

@test "position near neither preset remains external control" {
  run external_probe $'19000\t10400\t97' 11600 10400 97 7100 10400 97

  [ "$status" -eq 0 ]
  assert_contains "$output" "__external_status=0"
  assert_contains "$output" "goto_failed=0"
  assert_contains "$output" "PTZ drift detected"
}

@test "previous match requires the zoom axis too" {
  run external_probe $'7200\t10400\t200' 11600 10400 97 7100 10400 97

  [ "$status" -eq 0 ]
  assert_contains "$output" "__external_status=0"
  assert_contains "$output" "goto_failed=0"
}

@test "previous match requires the tilt axis too" {
  run external_probe $'7200\t11000\t97' 11600 10400 97 7100 10400 97

  [ "$status" -eq 0 ]
  assert_contains "$output" "__external_status=0"
  assert_contains "$output" "goto_failed=0"
}

@test "previous match requires the pan axis too" {
  run external_probe $'7500\t10400\t97' 11600 10400 97 7100 10400 97

  [ "$status" -eq 0 ]
  assert_contains "$output" "__external_status=0"
  assert_contains "$output" "goto_failed=0"
}

@test "unknown previous coordinates cannot classify a failed goto" {
  run external_probe $'7200\t10400\t97' 11600 10400 97

  [ "$status" -eq 0 ]
  assert_contains "$output" "__external_status=0"
  assert_contains "$output" "goto_failed=0"
}

@test "failed position read produces neither hold nor failed-goto flag" {
  run external_probe "" 11600 10400 97 7100 10400 97

  [ "$status" -eq 1 ]
  assert_contains "$output" "__external_status=1"
  assert_contains "$output" "goto_failed=0"
}

@test "malformed position response produces neither hold nor failed-goto flag" {
  run external_probe malformed 11600 10400 97 7100 10400 97

  [ "$status" -eq 1 ]
  assert_contains "$output" "__external_status=1"
  assert_contains "$output" "goto_failed=0"
}

@test "failed-goto side channel resets before the next position check" {
  run goto_failure_reset_probe

  [ "$status" -eq 0 ]
  assert_contains "$output" "__reset_first=1/1 second=0/0 reads=2"
}

@test "bounded failed-goto retries advance the patrol" {
  PTZ_READS=(
    $'7100\t10400\t97'
    $'7100\t10400\t97'
    $'7100\t10400\t97'
    $'7100\t10400\t97'
    $'7200\t10400\t97'
    $'7200\t10400\t97'
    $'7200\t10400\t97'
    $'7200\t10400\t97'
    $'7200\t10400\t97'
    $'7200\t10400\t97'
    $'7200\t10400\t97'
    $'7200\t10400\t97'
    $'7200\t10400\t97'
    $'7200\t10400\t97'
    $'7200\t10400\t97'
    $'7200\t10400\t97'
    $'7200\t10400\t97'
    $'7200\t10400\t97'
    $'7200\t10400\t97'
    $'7200\t10400\t97'
    $'7200\t10400\t97'
    $'7200\t10400\t97'
    $'7200\t10400\t97'
    $'7200\t10400\t97'
    $'7200\t10400\t97'
    $'7200\t10400\t97'
  )

  run patrol_probe 60 failed-goto

  [ "$status" -eq 0 ]
  assert_contains "$output" "__goto_advanced=1 gotos=5"
  assert_not_contains "$output" "__external_hold=1"
}
