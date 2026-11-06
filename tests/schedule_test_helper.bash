#!/usr/bin/env bash

load test_helper
# shellcheck disable=SC1091
source "$BATS_TEST_DIRNAME/../patrol.sh"

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

schedule_probe() {
  local status
  if is_within_schedule "$@"; then
    status=0
  else
    status=$?
  fi
  printf '__schedule_status=%s\n' "$status"
}

parser_probe() {
  local parser_status=0
  _patrol_parse_constrain "$1" "$2" "$3" || parser_status=$?
  printf '__parser_status=%s active=%s start=%s end=%s\n__logs=%s\n' \
    "$parser_status" \
    "$_PATROL_CONSTRAIN_ACTIVE" "$_PATROL_CONSTRAIN_START" \
    "$_PATROL_CONSTRAIN_END" "${LOG_LINES[*]}"
}
