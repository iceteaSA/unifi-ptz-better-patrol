#!/usr/bin/env bash

# shellcheck source=/dev/null
source "$BATS_TEST_DIRNAME/cue_test_helper.bash"

REACQUIRE_REQUESTS=""
REACQUIRE_COUNTS=""
REACQUIRE_SEQUENCE=()
REACQUIRE_LIMIT=1
REACQUIRE_SOURCE_CODE=200
REACQUIRE_SOURCE_BODY='{"name":"Horsetrail Up","smartDetectZones":[{"id":2,"name":"Past pole"},{"id":3,"name":"Near side"}]}'

api_get() {
  _LAST_HTTP_CODE=200
  if [[ "$1" == /events* ]]; then
    printf 'event\n' >> "$REACQUIRE_REQUESTS"
    printf '__events now=%s known=%s smart=%s tracking=%s url=%s\n' "$CUE_NOW" "$_LAST_ACTIVITY_KNOWN" "$_LAST_SMART_ACTIVE" "$_LAST_TRACKING_ACTIVE" "$1"
    _LAST_BODY=$CUE_BODY
  else
    _LAST_HTTP_CODE=$REACQUIRE_SOURCE_CODE
    _LAST_BODY=$REACQUIRE_SOURCE_BODY
  fi
}

reacquire_fixture() {
  cue_fixture "${1:-970000}" | command jq -c '
    .[0:1] | .[0].metadata.zonesStatus={
      "2":{"level":84,"status":"enter"},
      "3":{"level":0,"status":"none"},
      "4294967295":{"level":0,"status":"none"}}
  '
}

reacquire_poll_probe() {
  local mode=$1
  local -x cam_id=cam1 cam_name=Overwatch last_commanded_slot=0
  local cam_config='{"cues":[{"camera_id":"fixed1","slot":4,"zones":["Past pole"],"cooldown_seconds":10},{"camera_id":"fixed1","slot":2,"zones":["Near side"],"cooldown_seconds":10}]}'
  local -x cam_discovery_json='{"presets":[{"slot":0},{"slot":4},{"slot":2}]}'
  local -ax cue_camera_ids=() cue_slots=() cue_types=() cue_holds=() cue_cooldowns=() cue_names=() cue_zones=() cue_until=()
  local -Ax cue_seen=() cue_zone_labels=()
  local -x cue_query="" cue_pending=-1 cue_match="" cue_matched_at=0 cue_poll_failed=0
  local _LAST_ACTIVITY_KNOWN=1 _LAST_SMART_ACTIVE=0 _LAST_TRACKING_ACTIVE=0
  local reacquire=1 rc=0
  REACQUIRE_REQUESTS="$BATS_TEST_TMPDIR/events"
  : > "$REACQUIRE_REQUESTS"
  CUE_BODY=$(reacquire_fixture)
  case "$mode" in
    entries) reacquire=0; CUE_BODY=$(reacquire_fixture 999000); cam_config=${cam_config//10/0} ;;
    normal-old) reacquire=0; CUE_BODY=$(reacquire_fixture 982000); CUE_BODY=$(command jq -c '.[0].metadata.zonesStatus["2"].status="leave" | .[0].metadata.zonesStatus["3"].status="enter"' <<< "$CUE_BODY") ;;
    normal-leave) reacquire=0; CUE_BODY=$(command jq -c '.[0].metadata.zonesStatus["2"].status="leave"' <<< "$CUE_BODY") ;;
    leave) CUE_BODY=$(command jq -c '.[0].metadata.zonesStatus["2"].status="leave"' <<< "$CUE_BODY") ;;
    moving) CUE_BODY=$(command jq -c '.[0].metadata.zonesStatus["2"].status="moving"' <<< "$CUE_BODY") ;;
    recent-leave) CUE_BODY=$(reacquire_fixture 999000); CUE_BODY=$(command jq -c '.[0].metadata.zonesStatus["2"].status="leave"' <<< "$CUE_BODY") ;;
    priority) CUE_BODY=$(reacquire_fixture 999000); CUE_BODY=$(command jq -c '.[0].metadata.zonesStatus["2"].status="leave" | .[0].metadata.zonesStatus["3"]={"level":90,"status":"enter"}' <<< "$CUE_BODY") ;;
    order) CUE_BODY=$(command jq -c '.[0].metadata.zonesStatus["3"]={"level":90,"status":"enter"}' <<< "$CUE_BODY") ;;
    unfiltered|unfiltered-leave) cam_config='{"cues":[{"camera_id":"fixed1","slot":4}]}'
      if [[ "$mode" == unfiltered-leave ]]; then CUE_BODY=$(command jq -c '.[0].metadata.zonesStatus["2"].status="leave"' <<< "$CUE_BODY"); fi ;;
    id) REACQUIRE_SOURCE_CODE=503; cam_config='{"cues":[{"camera_id":"fixed1","slot":4,"zones":[2]}]}' ;;
    id-unnamed) REACQUIRE_SOURCE_BODY=$(command jq -c 'del(.smartDetectZones[0].name)' <<< "$REACQUIRE_SOURCE_BODY"); cam_config='{"cues":[{"camera_id":"fixed1","slot":4,"zones":[2]}]}' ;;
    stale) CUE_BODY=$(reacquire_fixture 879000) ;;
    future) CUE_BODY=$(reacquire_fixture 1001000) ;;
    types) CUE_BODY=$(command jq -c '.[0].smartDetectTypes=["animal"]' <<< "$CUE_BODY") ;;
    documents) CUE_BODY+=$'\n[]' ;;
  esac
  _patrol_parse_cues
  [[ "$mode" != cooldown ]] || cue_until[0]=1001
  [[ "$mode" != current ]] || last_commanded_slot=4
  # Count only poll processes, not fixture preparation or startup validation.
  REACQUIRE_COUNTS="$BATS_TEST_TMPDIR/poll-jq"
  : > "$REACQUIRE_COUNTS"
  # shellcheck disable=SC2329 # The poll runs this counter in a command substitution.
  jq() { printf 'jq\n' >> "$REACQUIRE_COUNTS"; command jq "$@"; }
  _patrol_poll_cues "$reacquire" || rc=$?
  local -a jq_calls=()
  mapfile -t jq_calls < "$REACQUIRE_COUNTS"
  printf '__match=%s rc=%s type=%s at=%s until=%s seen=%s jq=%s\n' "$cue_pending" "$rc" "$cue_match" "$cue_matched_at" "${cue_until[0]}" "${#cue_seen[@]}" "${#jq_calls[@]}"
  printf '__no_goto=%s\n' "$cue_no_goto"
  if [[ "$mode" == entries ]]; then
    CUE_NOW=1001
    _patrol_poll_cues || true
    printf '__repeat=%s seen=%s\n' "$cue_pending" "${#cue_seen[@]}"
    CUE_BODY=$(command jq -c '.[0].metadata.zonesStatus["2"].status="leave" | .[0].metadata.zonesStatus["3"]={"level":88,"status":"enter"}' <<< "$CUE_BODY")
    _patrol_poll_cues || true
    printf '__next_entry=%s seen=%s\n' "$cue_pending" "${#cue_seen[@]}"
    CUE_NOW=1016; CUE_BODY='[]'
    _patrol_poll_cues || true
    printf '__retained=%s\n' "${#cue_seen[@]}"
    CUE_NOW=1120
    _patrol_poll_cues || true
    printf '__pruned=%s\n' "${#cue_seen[@]}"
  fi
}

api_get_camera_state() {
  local index=$(( (FIELD_NOW - 1000) / 5 )) reason
  (( index < ${#REACQUIRE_SEQUENCE[@]} )) || index=$(( ${#REACQUIRE_SEQUENCE[@]} - 1 ))
  reason=${REACQUIRE_SEQUENCE[$index]}
  case "$reason" in
    tracking) _CACHED_CAM_STATE='{"id":"cam1","state":"CONNECTED","isAutoTracking":true}' ;;
    smart) _CACHED_CAM_STATE='{"id":"cam1","state":"CONNECTED","isSmartDetected":true}' ;;
    motion) _CACHED_CAM_STATE='{"id":"cam1","state":"CONNECTED","isMotionDetected":true}' ;;
    unknown) _CACHED_CAM_STATE='{"id":"cam1","state":"DISCONNECTED"}' ;;
    clear) _CACHED_CAM_STATE='{"id":"cam1","state":"CONNECTED"}' ;;
  esac
}

sleep() {
  FIELD_NOW=$(( FIELD_NOW + $1 )); CUE_NOW=$FIELD_NOW
  (( FIELD_NOW < 1500 )) || exit 99
}

api_post_with_retry() {
  local -a requests=()
  mapfile -t requests < "$REACQUIRE_REQUESTS"
  FIELD_GOTOS=$(( FIELD_GOTOS + 1 ))
  printf '__goto=%s now=%s cue=%s source=%s events=%s seen=%s\n' "${1##*/}" "$FIELD_NOW" "${cue_in_progress:-0}" "${status_cue_camera:-}" "${#requests[@]}" "${#cue_seen[@]}" >&2
  if (( FIELD_GOTOS >= REACQUIRE_LIMIT )); then exit 0; fi
  _LAST_HTTP_CODE=200
}

reacquire_hold_probe() {
  local mode=$1
  shift
  REACQUIRE_SEQUENCE=("$@")
  REACQUIRE_REQUESTS="$BATS_TEST_TMPDIR/hold-events"
  : > "$REACQUIRE_REQUESTS"
  CUE_BODY=$(reacquire_fixture)
  local -x FIELD_CONFIG='{"dwell_seconds":6,"ptz_settle_seconds":0,"max_tracking_wait":60,"cues":[{"camera_id":"fixed1","slot":4,"zones":["Past pole"],"hold_seconds":5}]}'
  if [[ "$mode" == no-cues ]]; then FIELD_CONFIG='{"dwell_seconds":6,"ptz_settle_seconds":0}'; fi
  if [[ "$mode" == leave ]]; then CUE_BODY=$(command jq -c '.[0].metadata.zonesStatus["2"].status="leave"' <<< "$CUE_BODY"); fi
  [[ "$mode" != resume ]] || REACQUIRE_LIMIT=3
  FIELD_GOTOS=0 FIELD_NOW=1000 CUE_NOW=1000
  _STATUS_WEBHOOK_URL='https://example.invalid/webhook'
  patrol_camera cam1 Overwatch "$FIELD_DISCOVERY"
}
