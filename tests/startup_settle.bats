#!/usr/bin/env bats

load patrol_test_helper

setup() {
  _LOG_LEVEL=3
  PTZ_READS=()
  HOME_CAMERA_STATES=()
  PATROL_MODE=""
  PATROL_SETTLE_CALLS=0
}

@test "moving camera settles after two agreeing reads and starts patrol" {
  PATROL_MODE=settle-stable
  PTZ_READS=(
    $'1000\t10400\t97'
    $'2000\t10400\t97'
    $'3000\t10400\t97'
    $'4000\t10400\t97'
    $'4000\t10400\t97'
  )

  run patrol_probe 1 settle-stable

  [ "$status" -eq 0 ]
  assert_contains "$output" "__patrol_started=1 settle_calls=1 now=1003"
}

@test "never-stable camera reaches the startup cap and starts patrol" {
  PATROL_MODE=settle-cap
  for (( i = 0; i < 40; i++ )); do
    PTZ_READS+=("$(( 1000 + i * 500 ))"$'\t10400\t97')
  done

  run patrol_probe 1 settle-cap

  [ "$status" -eq 0 ]
  assert_contains "$output" "__patrol_started=1 settle_calls=1 now=1030"
}

@test "malformed startup position does not block patrol" {
  PATROL_MODE=settle-fail
  PTZ_READS=(
    malformed
    $'4000\t10400\t97'
    $'4000\t10400\t97'
  )

  run patrol_probe 1 settle-fail

  [ "$status" -eq 0 ]
  assert_contains "$output" "__patrol_started=1 settle_calls=1 now=1001"
}

@test "startup settle wait runs once per patrol loop" {
  PTZ_READS=(
    $'11600\t10400\t100'
    $'11600\t10400\t100'
    $'11600\t10400\t100'
    $'8700\t10400\t100'
    $'10200\t10400\t100'
  )

  run patrol_probe 1 settle-once

  [ "$status" -eq 0 ]
  assert_contains "$output" "__goto_advanced=1 settle_calls=1"
}
