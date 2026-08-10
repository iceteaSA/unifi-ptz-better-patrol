#!/usr/bin/env bats

load patrol_test_helper

setup() {
  _LOG_LEVEL=3
  PTZ_READS=()
  HOME_CAMERA_STATES=()
  PATROL_MODE=""
  PATROL_SETTLE_CALLS=0
}

@test "production pan drift converging toward target never holds" {
  PTZ_READS=(
    $'11600\t10400\t100'
    $'11600\t10400\t100'
    $'8700\t10400\t100'
    $'10200\t10400\t100'
  )

  run home_probe 4

  [ "$status" -eq 0 ]
  assert_contains "$output" "__home_status=0 ptz_reads=4 expected=11600/10400/100"
  assert_not_contains "$output" "External control detected"
}

@test "non-converging pan drift holds after two polls" {
  PTZ_READS=(
    $'11600\t10400\t100'
    $'11600\t10400\t100'
    $'8700\t10400\t100'
    $'8700\t10400\t100'
  )

  run home_probe 4

  [ "$status" -eq 1 ]
  assert_contains "$output" "External control detected during home dwell"
}

@test "72 percent pan convergence does not hold" {
  PTZ_READS=(
    $'11600\t10400\t100'
    $'11600\t10400\t100'
    $'8700\t10400\t100'
    $'9512\t10400\t100'
  )

  run home_probe 4

  [ "$status" -eq 0 ]
  assert_not_contains "$output" "External control detected"
}

@test "76 percent pan convergence holds" {
  PTZ_READS=(
    $'11600\t10400\t100'
    $'11600\t10400\t100'
    $'8700\t10400\t100'
    $'9396\t10400\t100'
  )

  run home_probe 4

  [ "$status" -eq 1 ]
  assert_contains "$output" "External control detected during home dwell"
}

@test "positive-direction pan convergence does not hold" {
  PTZ_READS=(
    $'11600\t10400\t100'
    $'11600\t10400\t100'
    $'14500\t10400\t100'
    $'13000\t10400\t100'
  )

  run home_probe 4

  [ "$status" -eq 0 ]
  assert_not_contains "$output" "External control detected"
}

@test "positive-direction pan drift holds" {
  PTZ_READS=(
    $'11600\t10400\t100'
    $'11600\t10400\t100'
    $'14500\t10400\t100'
    $'14500\t10400\t100'
  )

  run home_probe 4

  [ "$status" -eq 1 ]
  assert_contains "$output" "External control detected during home dwell"
}

@test "zoom drift below threshold never reports external control" {
  run external_probe $'11600\t10400\t88' 11600 10400 100

  [ "$status" -eq 1 ]
  assert_contains "$output" "__external_status=1 magnitude=12"
}

@test "non-converging zoom drift holds" {
  PTZ_READS=(
    $'11600\t10400\t100'
    $'11600\t10400\t100'
    $'11600\t10400\t60'
    $'11600\t10400\t62'
  )

  run home_probe 4

  [ "$status" -eq 1 ]
  assert_contains "$output" "External control detected during home dwell"
}

@test "one large drift observation never holds" {
  PTZ_READS=(
    $'11600\t10400\t100'
    $'11600\t10400\t100'
    $'8700\t10400\t100'
    $'11600\t10400\t100'
  )

  run home_probe 4

  [ "$status" -eq 0 ]
  assert_not_contains "$output" "External control detected"
}

@test "clean poll resets drift persistence streak" {
  PTZ_READS=(
    $'11600\t10400\t100'
    $'11600\t10400\t100'
    $'8700\t10400\t100'
    $'11600\t10400\t100'
    $'8700\t10400\t100'
    $'8700\t10400\t100'
  )

  run home_probe 6

  [ "$status" -eq 1 ]
  assert_contains "$output" "__home_status=1 ptz_reads=6"
  assert_contains "$output" "External control detected during home dwell"
}

@test "failed position read never reports external control" {
  run external_probe "" 11600 10400 100

  [ "$status" -eq 1 ]
  assert_contains "$output" "__external_status=1 magnitude=0"
}

@test "malformed position response never reports external control" {
  run external_probe malformed 11600 10400 100

  [ "$status" -eq 1 ]
  assert_contains "$output" "__external_status=1 magnitude=0"
}

@test "unknown camera state suppresses drift check without external hold" {
  HOME_CAMERA_STATES=(
    '{"id":"cam-1","state":"CONNECTED","lastMotion":0}'
    '{"id":"cam-1","state":"CONNECTED","lastMotion":0}'
    malformed
  )
  PTZ_READS=(
    $'11600\t10400\t100'
    $'11600\t10400\t100'
    $'8700\t10400\t100'
  )

  run home_probe 3

  [ "$status" -eq 1 ]
  assert_contains "$output" "__home_status=1 ptz_reads=2 expected=-1/-1/-1"
  assert_contains "$output" "Invalid camera state response — assuming active (fail-safe)"
  assert_not_contains "$output" "External control detected"
}

@test "unstable home reads never accept a baseline or run drift check" {
  PTZ_READS=(
    $'11600\t10400\t100'
    $'11900\t10400\t100'
    $'12200\t10400\t100'
  )

  run home_probe 3

  [ "$status" -eq 0 ]
  assert_contains "$output" "__home_status=0 ptz_reads=3 expected=-1/-1/-1"
  assert_not_contains "$output" "Home baseline accepted"
}

@test "stable home reads accept baseline and resume drift checks" {
  PTZ_READS=(
    $'11600\t10400\t100'
    $'11650\t10450\t110'
    $'11600\t10400\t100'
  )

  run home_probe 3

  [ "$status" -eq 0 ]
  assert_contains "$output" "__home_status=0 ptz_reads=3 expected=11650/10450/110 acquisition=acquired/2"
  assert_contains "$output" "Home baseline accepted after stable position reads"
}

@test "oscillating unconfirmed home drift eventually lets patrol proceed" {
  PTZ_READS=(
    $'11600\t10400\t100'
    $'11600\t10400\t100'
    $'8700\t10400\t100'
    $'10600\t10400\t100'
    $'8700\t10400\t100'
  )

  run home_probe 5

  [ "$status" -eq 0 ]
  assert_contains "$output" "__home_status=0 ptz_reads=5 expected=11600/10400/100"
  assert_contains "$output" "PTZ drift did not persist during home dwell — continuing"
  assert_not_contains "$output" "External control detected"
}

@test "top-of-loop converging drift advances to the next preset" {
  PTZ_READS=(
    $'11600\t10400\t100'
    $'11600\t10400\t100'
    $'11600\t10400\t100'
    $'11600\t10400\t100'
    $'8700\t10400\t100'
    $'10200\t10400\t100'
  )

  run patrol_probe 4 top

  [ "$status" -eq 0 ]
  assert_contains "$output" "__goto_advanced=1"
  assert_not_contains "$output" "__external_hold=1"
}

@test "top-of-loop non-converging drift holds" {
  PTZ_READS=(
    $'11600\t10400\t100'
    $'11600\t10400\t100'
    $'11600\t10400\t100'
    $'11600\t10400\t100'
    $'8700\t10400\t100'
    $'8700\t10400\t100'
  )

  run patrol_probe 4 top

  [ "$status" -eq 0 ]
  assert_contains "$output" "__external_hold=1"
  assert_not_contains "$output" "__goto_advanced=1"
}

@test "normal dwell converging drift advances to the next preset" {
  PTZ_READS=(
    $'11600\t10400\t100'
    $'11600\t10400\t100'
    $'11600\t10400\t100'
    $'11600\t10400\t100'
    $'8700\t10400\t100'
    $'10200\t10400\t100'
  )

  run patrol_probe 8 dwell

  [ "$status" -eq 0 ]
  assert_contains "$output" "__goto_advanced=1"
  assert_not_contains "$output" "__external_hold=1"
}

@test "normal dwell non-converging drift holds" {
  PTZ_READS=(
    $'11600\t10400\t100'
    $'11600\t10400\t100'
    $'11600\t10400\t100'
    $'11600\t10400\t100'
    $'8700\t10400\t100'
    $'8700\t10400\t100'
  )

  run patrol_probe 8 dwell

  [ "$status" -eq 0 ]
  assert_contains "$output" "__external_hold=1"
  assert_not_contains "$output" "__goto_advanced=1"
}
