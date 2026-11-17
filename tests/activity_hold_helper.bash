#!/usr/bin/env bash

# shellcheck source=/dev/null
source "$BATS_TEST_DIRNAME/field_test_helper.bash"

ACTIVITY_SEQUENCE=()
ACTIVITY_READS_FILE=""

activity_state() {
  local index=$(( (FIELD_NOW - 1000) / 5 )) reason
  (( index < ${#ACTIVITY_SEQUENCE[@]} )) || index=$(( ${#ACTIVITY_SEQUENCE[@]} - 1 ))
  reason=${ACTIVITY_SEQUENCE[$index]}
  printf 'state %s %s\n' "$FIELD_NOW" "$reason" >> "$ACTIVITY_READS_FILE"
  case "$reason" in
    tracking) _CACHED_CAM_STATE='{"id":"cam-1","state":"CONNECTED","isAutoTracking":true}' ;;
    smart-tracking) _CACHED_CAM_STATE='{"id":"cam-1","state":"CONNECTED","isSmartDetected":true,"smartDetectSettings":{"autoTrackingObjectTypes":["person"]}}' ;;
    smart) _CACHED_CAM_STATE='{"id":"cam-1","state":"CONNECTED","isSmartDetected":true}' ;;
    motion) _CACHED_CAM_STATE='{"id":"cam-1","state":"CONNECTED","isMotionDetected":true}' ;;
    tail) _CACHED_CAM_STATE="{\"id\":\"cam-1\",\"state\":\"CONNECTED\",\"lastMotion\":$(( FIELD_NOW * 1000 ))}" ;;
    unknown) _CACHED_CAM_STATE='{"id":"cam-1","state":"DISCONNECTED"}' ;;
    failed) return 1 ;;
    clear) _CACHED_CAM_STATE='{"id":"cam-1","state":"CONNECTED"}' ;;
    *) return 99 ;;
  esac
}

api_get_camera_state() { activity_state; }
api_get_with_retry() {
  activity_state || return
  _LAST_BODY=$_CACHED_CAM_STATE
}
api_post_with_retry() {
  printf '__goto=%s now=%s max_smart_wait=%s\n' "${1##*/}" "$FIELD_NOW" "${max_smart_wait:-unset}" >&2
  exit 0
}
sleep() {
  FIELD_NOW=$(( FIELD_NOW + $1 ))
  (( FIELD_NOW < 1500 )) || exit 99
}

activity_hold_probe() {
  local config=$1
  shift
  ACTIVITY_SEQUENCE=("$@")
  ACTIVITY_READS_FILE="$BATS_TEST_TMPDIR/activity-reads"
  : > "$ACTIVITY_READS_FILE"
  field_probe "$config" 1
}
