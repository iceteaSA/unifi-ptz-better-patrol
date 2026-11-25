#!/usr/bin/env bash

# shellcheck source=/dev/null
source "$BATS_TEST_DIRNAME/cue_test_helper.bash"

OWN_MODE=open
OWN_BODY='[]'
OWN_REQUESTS=0
OWN_COUNTS=""
OWN_CAMERA_READS=0

api_get() {
  OWN_REQUESTS=$(( OWN_REQUESTS + 1 ))
  printf '__own_request now=%s url=%s\n' "$CUE_NOW" "$1"
  _LAST_HTTP_CODE=200
  _LAST_BODY=$OWN_BODY
  case "$OWN_MODE" in
    error) _LAST_HTTP_CODE=503 ;;
    malformed) _LAST_BODY='' ;;
    documents) _LAST_BODY+=$'\n[]' ;;
    open|face|dwell|top|long) if (( CUE_NOW >= 1012 )); then _LAST_BODY='[]'; fi ;;
    unlimited) if (( CUE_NOW >= 1072 )); then _LAST_BODY='[]'; fi ;;
  esac
  # Protect filters on event start, so an event older than the window drops out.
  if [[ "$1" =~ start=([0-9]+) && "$_LAST_BODY" == '['* && "$_LAST_BODY" != '[]' && "$OWN_MODE" != documents ]]; then
    _LAST_BODY=$(command jq -c --argjson s "${BASH_REMATCH[1]}" 'map(select(.start >= $s))' <<< "$_LAST_BODY")
  fi
}

jq() {
  printf 'jq\n' >> "$OWN_COUNTS"
  command jq "$@"
}

own_fixture() {
  cue_fixture 999000 | command jq -c --arg type "${1:-person}" '
    .[0:1] | .[0].camera="cam1" | .[0].smartDetectTypes=[$type]
    | .[0].metadata.zonesStatus={"1":{"status":"none","level":0}}
  '
}

own_prepare() {
  OWN_MODE=$1
  OWN_BODY=$(own_fixture)
  case "$OWN_MODE" in
    face) OWN_BODY=$(own_fixture face) ;;
    none) OWN_BODY='[]' ;;
    recent) OWN_BODY=$(command jq -c '.[0].end=995000' <<< "$OWN_BODY") ;;
    stale) OWN_BODY=$(command jq -c '.[0].end=989000' <<< "$OWN_BODY") ;;
    other) OWN_BODY=$(command jq -c '.[0].camera="other"' <<< "$OWN_BODY") ;;
    long) OWN_BODY=$(command jq -c '.[0].start=940000' <<< "$OWN_BODY") ;;
  esac
  OWN_COUNTS="$BATS_TEST_TMPDIR/own-jq"
  : > "$OWN_COUNTS"
  OWN_REQUESTS=0 FIELD_NOW=1000 CUE_NOW=1000 FIELD_GOTOS=0 OWN_CAMERA_READS=0
}

own_check_probe() {
  local cam_id=cam1 cam_name=Overwatch max_smart_wait=30
  local own_event_since=0 own_event_poll_failed=0 own_event_capped=0
  own_prepare "$1"
  [[ "$1" != capped ]] || max_smart_wait=4
  _patrol_hold_own_smart_event 2
  if [[ "$1" == error || "$1" == capped ]]; then _patrol_hold_own_smart_event 2; fi
  local -a calls=()
  mapfile -t calls < "$OWN_COUNTS"
  printf '__own_done now=%s requests=%s jq=%s since=%s capped=%s failed=%s\n' "$CUE_NOW" "$OWN_REQUESTS" "${#calls[@]}" "$own_event_since" "$own_event_capped" "$own_event_poll_failed"
}

api_get_camera_state() {
  OWN_CAMERA_READS=$(( OWN_CAMERA_READS + 1 ))
  if [[ "$OWN_MODE" == top ]] && (( FIELD_GOTOS == 1 && OWN_CAMERA_READS <= 4 )); then return 1; fi
  _CACHED_CAM_STATE='{"id":"cam1","state":"CONNECTED"}'
}

api_get_preset_positions() {
  printf '[{"slot":0,"pan":7100,"tilt":10400,"zoom":97},{"slot":4,"pan":11600,"tilt":10400,"zoom":97}]'
}

api_get_ptz_position() { printf '8800\t10400\t97\n'; }

api_post_with_retry() {
  FIELD_GOTOS=$(( FIELD_GOTOS + 1 ))
  printf '__goto=%s now=%s own_requests=%s retries=%s\n' "${1##*/}" "$FIELD_NOW" "$OWN_REQUESTS" "$goto_retry_count" >&2
  (( FIELD_GOTOS < 2 )) || exit 0
  _LAST_HTTP_CODE=200
}

own_patrol_probe() {
  own_prepare "$1"
  local -x FIELD_CONFIG='{"dwell_seconds":6,"ptz_settle_seconds":0,"max_smart_wait":6}'
  [[ "$1" != top ]] || FIELD_CONFIG='{"dwell_seconds":6,"ptz_settle_seconds":0,"max_smart_wait":30}'
  [[ "$1" != unlimited ]] || FIELD_CONFIG='{"dwell_seconds":6,"ptz_settle_seconds":0,"max_smart_wait":0,"status_heartbeat_seconds":30}'
  _STATUS_WEBHOOK_URL='https://example.invalid/webhook'
  patrol_camera cam1 Overwatch "$FIELD_DISCOVERY"
}
