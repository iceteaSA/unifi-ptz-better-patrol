#!/usr/bin/env bats

load schedule_test_helper

setup() {
  FAKE_HHMM=12:20
  LOG_LINES=()
}

@test "same-hour constraint includes its start and excludes its end" {
  FAKE_HHMM=12:15
  run schedule_probe 08:00 18:00 null 15 25
  [ "$status" -eq 0 ]
  assert_contains "$output" "__schedule_status=0"

  FAKE_HHMM=12:25
  run schedule_probe 08:00 18:00 null 15 25
  [ "$status" -eq 0 ]
  assert_contains "$output" "__schedule_status=1"

  FAKE_HHMM=12:14
  run schedule_probe 08:00 18:00 null 15 25
  [ "$status" -eq 0 ]
  assert_contains "$output" "__schedule_status=1"
}

@test "cross-hour constraint covers both ends but excludes the middle" {
  FAKE_HHMM=12:45
  run schedule_probe 08:00 18:00 null 45 15
  [ "$status" -eq 0 ]
  assert_contains "$output" "__schedule_status=0"

  FAKE_HHMM=13:14
  run schedule_probe 08:00 18:00 null 45 15
  [ "$status" -eq 0 ]
  assert_contains "$output" "__schedule_status=0"

  FAKE_HHMM=13:15
  run schedule_probe 08:00 18:00 null 45 15
  [ "$status" -eq 0 ]
  assert_contains "$output" "__schedule_status=1"

  FAKE_HHMM=12:30
  run schedule_probe 08:00 18:00 null 45 15
  [ "$status" -eq 0 ]
  assert_contains "$output" "__schedule_status=1"
}

@test "minute constraint intersects with overnight schedule boundaries" {
  FAKE_HHMM=22:05
  run schedule_probe 22:00 06:00 null 45 15
  [ "$status" -eq 0 ]
  assert_contains "$output" "__schedule_status=0"

  FAKE_HHMM=22:30
  run schedule_probe 22:00 06:00 null 45 15
  [ "$status" -eq 0 ]
  assert_contains "$output" "__schedule_status=1"

  FAKE_HHMM=21:50
  run schedule_probe 22:00 06:00 null 45 15
  [ "$status" -eq 0 ]
  assert_contains "$output" "__schedule_status=1"

  FAKE_HHMM=06:05
  run schedule_probe 22:00 06:00 null 45 15
  [ "$status" -eq 0 ]
  assert_contains "$output" "__schedule_status=1"
}

@test "empty constraint arguments leave the schedule unrestricted" {
  FAKE_HHMM=12:30
  run schedule_probe 08:00 18:00 null "" ""
  [ "$status" -eq 0 ]
  assert_contains "$output" "__schedule_status=0"

  FAKE_HHMM=19:00
  run schedule_probe 08:00 18:00 null "" ""
  [ "$status" -eq 0 ]
  assert_contains "$output" "__schedule_status=1"
}

@test "absent constraint pair is silent and disabled" {
  run parser_probe '{"schedule":{}}' Camera
  [ "$status" -eq 0 ]
  assert_contains "$output" "__parser_status=0 active=0 start= end="
  assert_not_contains "$output" "warn:"
  assert_not_contains "$output" "info:"
}

@test "out-of-range value warns and disables the constraint" {
  run parser_probe '{"schedule":{"constrain_start_minute":60,"constrain_end_minute":15}}' Camera
  [ "$status" -eq 0 ]
  assert_contains "$output" "__parser_status=0 active=0 start= end="
  assert_contains "$output" "warn: Invalid constrained patrol start value (60) — expected an integer from 0 to 59 — constraint disabled"
}

@test "single supplied constraint value warns and disables the constraint" {
  run parser_probe '{"schedule":{"constrain_start_minute":15}}' Camera
  [ "$status" -eq 0 ]
  assert_contains "$output" "__parser_status=0 active=0 start= end="
  assert_contains "$output" "warn: Invalid constrained patrol end value (absent) — expected an integer from 0 to 59 — constraint disabled"
}

@test "equal constraint values warn and disable the constraint" {
  run parser_probe '{"schedule":{"constrain_start_minute":15,"constrain_end_minute":"15"}}' Camera
  [ "$status" -eq 0 ]
  assert_contains "$output" "__parser_status=0 active=0 start= end="
  assert_contains "$output" 'warn: Invalid constrained patrol window: start and end values are equal (15, "15") — constraint disabled'
}

@test "valid numeric and numeric-string pair is accepted and logged" {
  run parser_probe '{"schedule":{"constrain_start_minute":15,"constrain_end_minute":"25"}}' Camera
  [ "$status" -eq 0 ]
  assert_contains "$output" "__parser_status=0 active=1 start=15 end=25"
  assert_contains "$output" "info: Active constrained patrol period window: 15 through 25 minutes past the hour."
}

@test "non-object schedule values warn once without jq errors" {
  local config
  for config in '{"schedule":"x"}' '{"schedule":5}' '{"schedule":[]}'; do
    run parser_probe "$config" Camera 1
    [ "$status" -eq 0 ]
    assert_contains "$output" "__parser_status=0 active=0 start= end="
    assert_contains "$output" "warn: Could not read the constrained patrol window from the camera config — constraint disabled"
    assert_not_contains "$output" "(, )"
    assert_not_contains "$output" "jq: error"
  done
}

@test "constraint without schedule start and end warns and stays off" {
  run parser_probe '{"schedule":{"constrain_start_minute":15,"constrain_end_minute":25}}' Camera 0
  [ "$status" -eq 0 ]
  assert_contains "$output" "__parser_status=0 active=0 start= end="
  assert_contains "$output" "warn: Constrained patrol minutes require schedule.start and schedule.end — constraint disabled"
}

@test "absent schedule and absent constraint fields stay silent" {
  run parser_probe '{"schedule":null}' Camera 0
  [ "$status" -eq 0 ]
  assert_contains "$output" "__parser_status=0 active=0 start= end="
  assert_not_contains "$output" "warn:"
  assert_not_contains "$output" "info:"
}
