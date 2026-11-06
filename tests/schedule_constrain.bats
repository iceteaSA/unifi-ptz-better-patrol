#!/usr/bin/env bats

load test_helper
source "$BATS_TEST_DIRNAME/../patrol.sh"

FAKE_HHMM=12:20
LOG_LINES=()

date() {
  case "$*" in
    +%H:%M) printf '%s\n' "$FAKE_HHMM" ;;
    +%a) printf 'Tue\n' ;;
    *"-d yesterday"*) printf 'Mon\n' ;;
    *) command date "$@" ;;
  esac
}

log() {
  LOG_LINES+=("$2: $3")
}

set_time() {
  FAKE_HHMM=$1
}

schedule_status() {
  if is_within_schedule "$@"; then
    SCHEDULE_STATUS=0
  else
    SCHEDULE_STATUS=$?
  fi
}

@test "same-hour constraint includes its start and excludes its end" {
  set_time 12:15
  schedule_status 08:00 18:00 null 15 25
  [ "$SCHEDULE_STATUS" -eq 0 ]

  set_time 12:25
  schedule_status 08:00 18:00 null 15 25
  [ "$SCHEDULE_STATUS" -eq 1 ]

  set_time 12:14
  schedule_status 08:00 18:00 null 15 25
  [ "$SCHEDULE_STATUS" -eq 1 ]
}

@test "cross-hour constraint covers both ends but excludes the middle" {
  set_time 12:45
  schedule_status 08:00 18:00 null 45 15
  [ "$SCHEDULE_STATUS" -eq 0 ]

  set_time 13:14
  schedule_status 08:00 18:00 null 45 15
  [ "$SCHEDULE_STATUS" -eq 0 ]

  set_time 13:15
  schedule_status 08:00 18:00 null 45 15
  [ "$SCHEDULE_STATUS" -eq 1 ]

  set_time 12:30
  schedule_status 08:00 18:00 null 45 15
  [ "$SCHEDULE_STATUS" -eq 1 ]
}

@test "minute constraint intersects with overnight schedule boundaries" {
  set_time 22:05
  schedule_status 22:00 06:00 null 45 15
  [ "$SCHEDULE_STATUS" -eq 0 ]

  set_time 22:30
  schedule_status 22:00 06:00 null 45 15
  [ "$SCHEDULE_STATUS" -eq 1 ]

  set_time 21:50
  schedule_status 22:00 06:00 null 45 15
  [ "$SCHEDULE_STATUS" -eq 1 ]

  set_time 06:05
  schedule_status 22:00 06:00 null 45 15
  [ "$SCHEDULE_STATUS" -eq 1 ]
}

@test "empty constraint arguments leave the schedule unrestricted" {
  set_time 12:30
  schedule_status 08:00 18:00 null "" ""
  [ "$SCHEDULE_STATUS" -eq 0 ]

  set_time 19:00
  schedule_status 08:00 18:00 null "" ""
  [ "$SCHEDULE_STATUS" -eq 1 ]
}

@test "absent constraint pair is silent and disabled" {
  LOG_LINES=()
  _patrol_parse_constrain '{"schedule":{}}' Camera
  [ "$_PATROL_CONSTRAIN_ACTIVE" -eq 0 ]
  [ -z "$_PATROL_CONSTRAIN_START" ]
  [ -z "$_PATROL_CONSTRAIN_END" ]
  [ "${#LOG_LINES[@]}" -eq 0 ]
}

@test "out-of-range value warns and disables the constraint" {
  LOG_LINES=()
  _patrol_parse_constrain '{"schedule":{"constrain_start_minute":60,"constrain_end_minute":15}}' Camera
  [ "$_PATROL_CONSTRAIN_ACTIVE" -eq 0 ]
  [ -z "$_PATROL_CONSTRAIN_START" ]
  [ "${LOG_LINES[0]}" = "warn: Invalid constrained patrol start value (60); expected an integer from 0 to 59 with a valid end value (15) — constraint disabled" ]
}

@test "single supplied constraint value warns and disables the constraint" {
  LOG_LINES=()
  _patrol_parse_constrain '{"schedule":{"constrain_start_minute":15}}' Camera
  [ "$_PATROL_CONSTRAIN_ACTIVE" -eq 0 ]
  [ -z "$_PATROL_CONSTRAIN_START" ]
  [ -z "$_PATROL_CONSTRAIN_END" ]
  [ "${LOG_LINES[0]}" = "warn: Invalid constrained patrol end value (absent); expected an integer from 0 to 59 with a valid start value (15) — constraint disabled" ]
}

@test "equal constraint values warn and disable the constraint" {
  LOG_LINES=()
  _patrol_parse_constrain '{"schedule":{"constrain_start_minute":15,"constrain_end_minute":"15"}}' Camera
  [ "$_PATROL_CONSTRAIN_ACTIVE" -eq 0 ]
  [ -z "$_PATROL_CONSTRAIN_START" ]
  [ -z "$_PATROL_CONSTRAIN_END" ]
  [ "${LOG_LINES[0]}" = 'warn: Invalid constrained patrol window: start and end values are equal (15, "15") — constraint disabled' ]
}

@test "valid numeric and numeric-string pair is accepted and logged" {
  LOG_LINES=()
  _patrol_parse_constrain '{"schedule":{"constrain_start_minute":15,"constrain_end_minute":"25"}}' Camera
  [ "$_PATROL_CONSTRAIN_ACTIVE" -eq 1 ]
  [ "$_PATROL_CONSTRAIN_START" = 15 ]
  [ "$_PATROL_CONSTRAIN_END" = 25 ]
  [ "${LOG_LINES[0]}" = "info: Active constrained patrol period window: 15 through 25 minutes past the hour." ]
}
