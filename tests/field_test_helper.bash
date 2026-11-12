#!/usr/bin/env bash

# shellcheck source=/dev/null
source "$BATS_TEST_DIRNAME/patrol_test_helper.bash"

FIELD_CONFIG='{}'
FIELD_DISCOVERY='{"presets":[{"slot":0},{"slot":4},{"slot":2}]}'
FIELD_LIMIT=4
FIELD_GOTOS=0
FIELD_NOW=1000
settle_seconds=0
poll_interval_s=0

get_camera_config() { printf '%s' "$FIELD_CONFIG"; }
api_get_preset_positions() { printf '[]'; }
_patrol_wait_for_camera_settle() { return 0; }
log() { printf '[%s] %s: %s\n' "$1" "$2" "$3"; }
date() { printf '%s\n' "$FIELD_NOW"; }

sleep() {
  FIELD_NOW=$(( FIELD_NOW + $1 ))
  printf '__sleep=%s slot=%s settle=%s poll=%s\n' "$1" "${last_commanded_slot:--1}" "$settle_seconds" "$poll_interval_s"
  if (( FIELD_NOW > 1300 )); then exit 99; fi
}

api_post_with_retry() {
  FIELD_GOTOS=$(( FIELD_GOTOS + 1 ))
  printf '__goto=%s now=%s\n' "${1##*/}" "$FIELD_NOW" >&2
  if (( FIELD_GOTOS >= FIELD_LIMIT )); then exit 0; fi
  _LAST_HTTP_CODE=200
}

field_probe() {
  FIELD_CONFIG=$1
  FIELD_LIMIT=${2:-4}
  FIELD_GOTOS=0
  FIELD_NOW=1000
  patrol_camera cam-1 Overwatch "$FIELD_DISCOVERY" "${3:-}"
}

name_probe() {
  is_tracking cam-1 60 0 0 '{"id":"cam-1","name":"Gate","state":"CONNECTED"}' || true
  printf '__name=%s\n' "$_LAST_CAM_NAME"
  is_tracking cam-1 60 0 0 "$1" || true
  printf '__next_name=%s\n' "$_LAST_CAM_NAME"
}

rename_probe() {
  HOME_CAMERA_STATES=(
    '{"id":"cam-1","name":"Overwatch","state":"CONNECTED"}'
    "$1"
  )
  HOME_CAMERA_STATES+=("${HOME_CAMERA_STATES[1]}" "${HOME_CAMERA_STATES[1]}")
  field_probe '{"dwell_seconds":6,"ptz_settle_seconds":0}' 3 "${2:-}"
}
