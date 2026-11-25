#!/usr/bin/env bash

# shellcheck source=/dev/null
source "$BATS_TEST_DIRNAME/cue_reacquire_helper.bash"

ARB_MODE=preempt
ARB_FIRST='[]'
ARB_SECOND='[]'

api_get() {
  _LAST_HTTP_CODE=200
  if [[ "$1" == /events* ]]; then
    printf '__events now=%s cue=%s known=%s tracking=%s\n' "$FIELD_NOW" "$cue_in_progress" "$_LAST_ACTIVITY_KNOWN" "$_LAST_TRACKING_ACTIVE"
    if (( FIELD_NOW < 1007 )); then _LAST_BODY=$ARB_FIRST; else _LAST_BODY=$ARB_SECOND; fi
  elif [[ "$1" == /cameras/fixed2 ]]; then
    _LAST_BODY='{"name":"Water Tower","smartDetectZones":[]}'
  else
    _LAST_BODY=$REACQUIRE_SOURCE_BODY
  fi
}

api_get_camera_state() {
  _CACHED_CAM_STATE='{"id":"cam1","state":"CONNECTED"}'
  if (( FIELD_NOW >= 1007 )); then
    case "$ARB_MODE" in
      tracking) _CACHED_CAM_STATE='{"id":"cam1","state":"CONNECTED","isAutoTracking":true}' ;;
      unreadable) _CACHED_CAM_STATE='{"id":"cam1","state":"DISCONNECTED"}' ;;
    esac
  fi
}

sleep() {
  FIELD_NOW=$(( FIELD_NOW + $1 )); CUE_NOW=$FIELD_NOW
  if [[ "$ARB_MODE" == tracking || "$ARB_MODE" == unreadable ]] && (( FIELD_NOW >= 1012 )); then
    printf '__gate_end known=%s tracking=%s\n' "$_LAST_ACTIVITY_KNOWN" "$_LAST_TRACKING_ACTIVE"
    exit 0
  fi
  (( FIELD_NOW < 1100 )) || exit 99
}

api_post_with_retry() {
  FIELD_GOTOS=$(( FIELD_GOTOS + 1 ))
  printf '__goto=%s now=%s cue=%s source=%s idx=%s\n' "${1##*/}" "$FIELD_NOW" "$cue_in_progress" "$status_cue_camera" "$idx" >&2
  (( FIELD_GOTOS < 4 )) || exit 0
  _LAST_HTTP_CODE=200
}

arbitration_probe() {
  ARB_MODE=$1
  ARB_FIRST=$(reacquire_fixture 1000000)
  ARB_SECOND=$(cue_fixture 1006000 | command jq -c '.[0:1] | .[0].camera="fixed2"')
  local -x FIELD_CONFIG='{"dwell_seconds":6,"ptz_settle_seconds":0,"cues":[{"camera_id":"fixed1","slot":4,"zones":["Past pole"],"hold_seconds":20},{"camera_id":"fixed2","slot":2,"hold_seconds":5}]}'
  [[ "$ARB_MODE" != same ]] || FIELD_CONFIG=${FIELD_CONFIG/\"slot\":2/\"slot\":4}
  FIELD_GOTOS=0 FIELD_NOW=1000 CUE_NOW=1000
  _STATUS_WEBHOOK_URL='https://example.invalid/webhook'
  patrol_camera cam1 Overwatch "$FIELD_DISCOVERY"
}
