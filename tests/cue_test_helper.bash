#!/usr/bin/env bash

# shellcheck source=/dev/null
source "$BATS_TEST_DIRNAME/field_test_helper.bash"

CUE_NOW=1000
CUE_BODY='[]'
CUE_CODE=200
CUE_WARNINGS=0
CUE_POLLS=0
CUE_MODE=""
CUE_ACTIVITY_READS=0
CUE_FIRE_SLOT=0
CUE_FIRE_GOTO=1
CUE_DELAY_SET=0
CUE_FETCH_ADVANCE=0
CUE_GOTO_CODE=500
CUE_FIRE_ELAPSED=0
CUE_EVENT_START=""

printf() {
  if [[ "${1:-}" == -v && "${3:-}" == '%(%s)T' ]]; then
    builtin printf -v "$2" '%s' "$CUE_NOW"
  else
    # shellcheck disable=SC2059 # Preserve the caller's format in this time stub.
    builtin printf "$@"
  fi
}

log() {
  [[ "$2" != warn ]] || CUE_WARNINGS=$(( CUE_WARNINGS + 1 ))
  printf '[%s] %s: %s\n' "$1" "$2" "$3"
}

api_get() {
  printf '__request=%s\n' "$1"
  _LAST_HTTP_CODE=$CUE_CODE
  if [[ "$1" == /events* ]]; then
    CUE_POLLS=$(( CUE_POLLS + 1 ))
    if (( ${cue_in_progress:-0} != 0 || ${activity_active:-0} != 0 || ${_LAST_TRACKING_ACTIVE:-0} != 0 || ${_LAST_ACTIVITY_KNOWN:-1} != 1 )); then
      printf '__forbidden_cue_poll\n'
    fi
    _LAST_BODY=$CUE_BODY
    if [[ "$CUE_MODE" == integration* ]] && [[ "$last_commanded_slot" != "$CUE_FIRE_SLOT" || "$FIELD_GOTOS" != "$CUE_FIRE_GOTO" ]]; then
      _LAST_BODY='[]'
    fi
    if [[ "$CUE_MODE" == integration* ]] && (( FIELD_NOW - ${last_goto_ts:-0} < CUE_FIRE_ELAPSED )); then
      _LAST_BODY='[]'
    fi
    if [[ "$CUE_MODE" == integration-pending-lag && "$_LAST_BODY" != '[]' ]]; then
      FIELD_NOW=$(( FIELD_NOW + 2 )); CUE_NOW=$FIELD_NOW
    fi
    if [[ "$CUE_MODE" == repeat-stream ]]; then
      local event_id
      printf -v event_id 'eeeeeeee-eeee-eeee-eeee-%012d' "$CUE_POLLS"
      _LAST_BODY=$(command jq -c --arg id "$event_id" --argjson start "$(( FIELD_NOW * 1000 ))" '
        .[0:1] | .[0].id=$id | .[0].start=$start
      ' <<< "$CUE_BODY")
    fi
    CUE_NOW=$(( CUE_NOW + CUE_FETCH_ADVANCE ))
  else
    _LAST_BODY='{"name":"Fixed One"}'
  fi
}

cue_fixture() {
  command jq -c --argjson start "${1:-999000}" '
    .[0].camera="fixed1" | .[1].camera="fixed2"
    | .[].start=$start | .[].end=null
  ' "$BATS_TEST_DIRNAME/fixtures/cue-events.json"
}

cue_poll_probe() {
  local mode=$1 cam_name=Overwatch last_commanded_slot=0
  local _LAST_TRACKING_ACTIVE=0 _LAST_ACTIVITY_KNOWN=1
  local -a cue_camera_ids=(fixed1 fixed2) cue_slots=(4 2) cue_types=($'\t"person"\t' $'\t"animal"\t')
  local -a cue_holds=(30 30) cue_cooldowns=(0 0) cue_names=(One Two) cue_until=(0 0)
  local cue_query='&cameras=fixed1&cameras=fixed2' cue_pending=-1 cue_match=""
  local -x cue_matched_at=0 cue_poll_failed=0
  local -A cue_seen=()
  CUE_BODY=$(cue_fixture)
  case "$mode" in
    current) last_commanded_slot=4; CUE_BODY=$(jq -c '.[0:1]' <<< "$CUE_BODY") ;;
    order) cue_camera_ids=(fixed2 fixed1); cue_types=($'\t"animal"\t' $'\t"person"\t') ;;
    cooldown) cue_cooldowns=(120 120); CUE_BODY=$(jq -c '.[0:1]' <<< "$CUE_BODY") ;;
    failure) CUE_CODE=503 ;;
    malformed) CUE_BODY='[{"id":' ;;
    stale) CUE_BODY=$(cue_fixture 984000) ;;
    closed) CUE_BODY=$(jq -c '.[].end=1' <<< "$CUE_BODY") ;;
    nested) CUE_BODY=$(jq -c '.[].camera="unknown" | .[].description.messageKeys[0].params.deviceId="fixed1"' <<< "$CUE_BODY") ;;
    multi-type) CUE_BODY=$(jq -c '.[0:1] | .[0].smartDetectTypes=["vehicle","person"]' <<< "$CUE_BODY") ;;
    future) CUE_BODY=$(cue_fixture 1001000) ;;
    fetch-stale) CUE_FETCH_ADVANCE=20 ;;
    fetch-valid) CUE_FETCH_ADVANCE=5 ;;
    scientific) CUE_BODY=$(cue_fixture 1e30) ;;
  esac
  local rc=0
  _patrol_poll_cues || rc=$?
  printf '__first=%s rc=%s until=%s seen=%s\n' "$cue_pending" "$rc" "${cue_until[0]}" "${#cue_seen[@]}"
  printf '__matched_at=%s\n' "$cue_matched_at"
  if [[ "$mode" == duplicate ]]; then
    CUE_NOW=1001
    _patrol_poll_cues || true
    printf '__second=%s seen=%s\n' "$cue_pending" "${#cue_seen[@]}"
    CUE_NOW=1002
    _patrol_poll_cues || true
    printf '__third=%s seen=%s\n' "$cue_pending" "${#cue_seen[@]}"
    CUE_NOW=1120; CUE_BODY='[]'
    _patrol_poll_cues || true
    printf '__pruned=%s\n' "${#cue_seen[@]}"
  elif [[ "$mode" == cooldown ]]; then
    CUE_BODY=$(jq -c '.[0].id="eeeeeeee-eeee-eeee-eeee-eeeeeeeeeee3"' <<< "$CUE_BODY")
    CUE_NOW=1001
    _patrol_poll_cues || true
    printf '__cooldown=%s\n' "$cue_pending"
    CUE_NOW=1120
    CUE_BODY=$(jq -c '.[0].id="eeeeeeee-eeee-eeee-eeee-eeeeeeeeeee4" | .[0].start=1120000' <<< "$CUE_BODY")
    _patrol_poll_cues || true
    printf '__expired=%s\n' "$cue_pending"
  fi
}

cue_transport_probe() {
  source "$BATS_TEST_DIRNAME/../api.sh"
  local -a cue_camera_ids=(fixed1) cue_slots=(4) cue_types=($'\t"person"\t')
  local -a cue_holds=(30) cue_cooldowns=(120) cue_names=(One) cue_until=(0)
  local cue_query='&cameras=fixed1' cue_pending=-1 cue_match="" last_commanded_slot=0
  local -A cue_seen=()
  _BODY_TEMP="$BATS_TEST_TMPDIR/transport-body"
  cue_fixture > "$_BODY_TEMP"
  # shellcheck disable=SC2329 # api_get calls this transfer stub.
  curl() { printf 200; return 28; }
  local rc=0
  _patrol_poll_cues || rc=$?
  printf '__transport=%s pending=%s http=%s curl=%s\n' "$rc" "$cue_pending" "$_LAST_HTTP_CODE" "$_LAST_CURL_RC"
}

sleep() {
  FIELD_NOW=$(( FIELD_NOW + $1 ))
  CUE_NOW=$FIELD_NOW
  if (( FIELD_NOW > 1500 )); then exit 99; fi
}

api_get_camera_state() {
  _CACHED_CAM_STATE='{"id":"cam1","state":"CONNECTED"}'
  if [[ "$CUE_MODE" == integration-expiry-unreadable ]] && (( ${cue_pending:--1} >= 0 && CUE_ACTIVITY_READS < 4 )); then
    CUE_ACTIVITY_READS=$(( CUE_ACTIVITY_READS + 1 ))
    return 1
  elif [[ "$CUE_MODE" == integration-expiry-activity || "$CUE_MODE" == integration-expiry-short ]] && (( ${cue_pending:--1} >= 0 )); then
    local activity_limit=4
    [[ "$CUE_MODE" != integration-expiry-short ]] || activity_limit=1
    if (( CUE_ACTIVITY_READS < activity_limit )); then
      CUE_ACTIVITY_READS=$(( CUE_ACTIVITY_READS + 1 ))
      _CACHED_CAM_STATE='{"id":"cam1","state":"CONNECTED","isAutoTracking":true}'
    fi
  elif [[ "$CUE_MODE" == integration-activity ]] && (( FIELD_GOTOS == 2 && CUE_ACTIVITY_READS < 2 )); then
    CUE_ACTIVITY_READS=$(( CUE_ACTIVITY_READS + 1 ))
    _CACHED_CAM_STATE='{"id":"cam1","state":"CONNECTED","isAutoTracking":true}'
  elif [[ "$CUE_MODE" == integration-block* ]] && (( FIELD_GOTOS == 1 && FIELD_NOW <= 1005 )); then
    if [[ "$CUE_MODE" == integration-block-motion ]]; then
      _CACHED_CAM_STATE='{"id":"cam1","state":"CONNECTED","isMotionDetected":true}'
    else
      _CACHED_CAM_STATE='{"id":"cam1","state":"CONNECTED","isAutoTracking":true}'
    fi
  fi
}

api_get_with_retry() {
  api_get_camera_state
  _LAST_BODY=$_CACHED_CAM_STATE
}

api_get_preset_positions() {
  if [[ "$CUE_MODE" == integration-acquisition || "$CUE_MODE" == integration-pending-lag || "$CUE_MODE" == integration-resume-unacquired || "$CUE_MODE" == integration-cue-manual ]]; then
    printf '[{"slot":0,"pan":7100,"tilt":10400,"zoom":97},{"slot":4,"pan":7100,"tilt":10400,"zoom":97},{"slot":2,"pan":11600,"tilt":10400,"zoom":97}]'
  else
    printf '[]'
  fi
}

api_get_ptz_position() {
  if [[ "$CUE_MODE" == integration-cue-manual ]]; then
    if (( ${cue_in_progress:-0} && FIELD_NOW - ${last_goto_ts:-0} >= 15 )); then
      printf '8800\t10400\t97\n'
    else
      printf '7100\t10400\t97\n'
    fi
  elif [[ "$CUE_MODE" == integration-pending-lag ]]; then
    if (( FIELD_GOTOS == 1 )); then printf '8800\t10400\t97\n'; else printf '11600\t10400\t97\n'; fi
  elif [[ "$CUE_MODE" == integration-resume-unacquired ]]; then
    if (( ${cue_in_progress:-0} )); then
      printf '%s\n' $'-1\t-1\t-1'
    elif (( FIELD_GOTOS == 2 )); then
      printf '8800\t10400\t97\n'
    else
      printf '7100\t10400\t97\n'
    fi
  elif [[ "$CUE_MODE" == integration-acquisition ]]; then
    if (( ${cue_in_progress:-0} )); then printf '8800\t10400\t97\n'; else printf '7100\t10400\t97\n'; fi
  else
    printf '%s\n' '-1 -1 -1'
  fi
}

set_auto_tracking() { return 0; }

api_ensure_auth() {
  if [[ "$CUE_MODE" == integration-expiry-manual ]] && (( ${cue_pending:--1} >= 0 && CUE_DELAY_SET == 0 )); then
    # shellcheck disable=SC2034 # patrol_camera reads this caller-scope hold deadline.
    external_control_until=$(( FIELD_NOW + 20 ))
    CUE_DELAY_SET=1
  fi
}

is_within_schedule() {
  if [[ "$CUE_MODE" == integration-expiry-schedule ]] && (( ${cue_pending:--1} >= 0 && CUE_DELAY_SET == 0 )); then
    CUE_DELAY_SET=1
    return 1
  fi
  return 0
}

api_post_with_retry() {
  FIELD_GOTOS=$(( FIELD_GOTOS + 1 ))
  printf '__goto=%s now=%s idx=%s acquisition=%s cue=%s polls=%s\n' "${1##*/}" "$FIELD_NOW" "${idx:--1}" "${acquisition_state:-none}" "$cue_in_progress" "$CUE_POLLS" >&2
  if (( FIELD_GOTOS >= FIELD_LIMIT )); then exit 0; fi
  _LAST_HTTP_CODE=200
  if [[ "$CUE_MODE" == integration-reject ]] && (( cue_in_progress )); then _LAST_HTTP_CODE=404; fi
  if [[ "$CUE_MODE" == integration-unexpected ]] && (( cue_in_progress )); then _LAST_HTTP_CODE=$CUE_GOTO_CODE; fi
}

api_post_status() {
  printf '__status=%s source=%s slot=%s\n' "$3" "${8:-null}" "$4"
}

cue_integration_probe() {
  local config=$1
  CUE_MODE=${2:-integration}
  local event_start=${CUE_EVENT_START:-$(( (1000 + 6 * (CUE_FIRE_GOTO - 1)) * 1000 ))}
  CUE_BODY=$(cue_fixture "$event_start")
  _STATUS_WEBHOOK_URL='https://example.invalid/webhook'
  FIELD_CONFIG="$config"
  export FIELD_CONFIG
  FIELD_LIMIT=${3:-5}
  FIELD_GOTOS=0 FIELD_NOW=1000 CUE_NOW=1000 CUE_POLLS=0 CUE_ACTIVITY_READS=0 CUE_DELAY_SET=0
  patrol_camera cam1 Overwatch "$FIELD_DISCOVERY"
}

cue_failure_sequence_probe() {
  local mode=$1 cam_name=Overwatch last_commanded_slot=0
  local _LAST_TRACKING_ACTIVE=0 _LAST_ACTIVITY_KNOWN=1
  local -a cue_camera_ids=(fixed1) cue_slots=(4) cue_types=($'\t"person"\t')
  local -a cue_holds=(30) cue_cooldowns=(120) cue_names=(One) cue_until=(0)
  local -x cue_query='&cameras=fixed1' cue_pending=-1 cue_match="" cue_matched_at=0 cue_poll_failed=0
  local -A cue_seen=()
  CUE_BODY='[]'
  case "$mode" in
    http) CUE_CODE=503 ;;
    curl) CUE_CODE=000; _LAST_CURL_RC=28 ;;
    parse) CUE_BODY='not-json' ;;
    parse-empty) CUE_BODY='' ;;
    parse-object) CUE_BODY='{}' ;;
  esac
  _patrol_poll_cues || true
  printf '__failure1 warnings=%s failed=%s\n' "$CUE_WARNINGS" "$cue_poll_failed"
  _patrol_poll_cues || true
  printf '__failure2 warnings=%s failed=%s\n' "$CUE_WARNINGS" "$cue_poll_failed"
  CUE_CODE=200; _LAST_CURL_RC=0
  if [[ "$mode" == http ]]; then CUE_BODY=$(cue_fixture); else CUE_BODY='[]'; fi
  _patrol_poll_cues || true
  printf '__success1 failed=%s\n' "$cue_poll_failed"
  CUE_BODY='[]'
  _patrol_poll_cues || true
  printf '__success2 failed=%s\n' "$cue_poll_failed"
}

cue_discovery_probe() {
  discover_cue_lines '{"cues":[{"camera_id":"fixed1","slot":4},{"camera_id":"missing","slot":2}]}' '[{"id":"fixed1","name":"Side Gate"}]'
}

cue_spawn_probe() {
  local root=$1 config=$2 phase kind startup_jq=0 startup_curl=0 poll_jq=0 poll_curl=0 cycle_jq=0 cycle_curl=0
  local bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  cp "$BATS_TEST_DIRNAME/fixtures/counting-curl" "$bin/curl"
  cp "$BATS_TEST_DIRNAME/fixtures/counting-jq" "$bin/jq"
  chmod +x "$bin/curl" "$bin/jq"
  local -x COUNT_FILE="$BATS_TEST_TMPDIR/counts" COUNT_JQ
  COUNT_JQ=$(command -v jq)
  : > "$COUNT_FILE"
  SPAWN_CONFIG="$config" PATH="$bin:$PATH" bash "$BATS_TEST_DIRNAME/fixtures/cue-spawn-runner" "$root" "$BATS_TEST_TMPDIR/count-body" || return
  while read -r phase kind; do
    case "$phase/$kind" in
      startup/jq) startup_jq=$(( startup_jq + 1 )) ;;
      startup/curl) startup_curl=$(( startup_curl + 1 )) ;;
      poll/jq) poll_jq=$(( poll_jq + 1 )) ;;
      poll/curl) poll_curl=$(( poll_curl + 1 )) ;;
      cycle/jq) cycle_jq=$(( cycle_jq + 1 )) ;;
      cycle/curl) cycle_curl=$(( cycle_curl + 1 )) ;;
    esac
  done < "$COUNT_FILE"
  printf '__spawn startup:curl=%s,jq=%s poll:curl=%s,jq=%s cycle:curl=%s,jq=%s\n' "$startup_curl" "$startup_jq" "$poll_curl" "$poll_jq" "$cycle_curl" "$cycle_jq"
}

cue_parse_probe() {
  local -x cam_id=cam1 cam_name=Overwatch cam_config="{\"cues\":$1}"
  local -x cam_discovery_json=${2:-}
  [[ -n "$cam_discovery_json" ]] || cam_discovery_json='{"presets":[{"slot":0},{"slot":4},{"slot":2}]}'
  local -ax presets=(0 4 2) cue_camera_ids=() cue_slots=() cue_types=() cue_holds=() cue_cooldowns=() cue_names=() cue_until=()
  local -A cue_zone_labels=()
  local -x cue_query="" cue_pending=-1 cue_match=""
  local -A cue_seen=()
  _patrol_parse_cues
  local i
  for (( i=0; i<${#cue_slots[@]}; i++ )); do
    printf '__cue=%s/%s/%s/%s/%s\n' "${cue_camera_ids[$i]}" "${cue_slots[$i]}" "${cue_holds[$i]}" "${cue_cooldowns[$i]}" "${cue_types[$i]}"
  done
  printf '__count=%s warnings=%s\n' "${#cue_slots[@]}" "$CUE_WARNINGS"
}

cue_empty_probe() {
  local -x cam_id=cam1 cam_name=Overwatch cam_config='{"cues":[{"camera_id":"fixed1","slot":4},{"camera_id":"fixed2","slot":2},{"camera_id":"fixed1","slot":2}]}'
  local -x cam_discovery_json='{"presets":[{"slot":0},{"slot":4},{"slot":2}]}'
  local -ax presets=(0 4 2) cue_camera_ids=() cue_slots=() cue_types=() cue_holds=() cue_cooldowns=() cue_names=() cue_until=()
  local -A cue_zone_labels=()
  local -x cue_query="" cue_pending=-1 cue_match="" last_commanded_slot=0
  local -A cue_seen=()
  _patrol_parse_cues
  local count_file="$BATS_TEST_TMPDIR/poll-jq"
  : > "$count_file"
  # shellcheck disable=SC2329 # The cue poll calls this process counter.
  jq() { printf 'jq\n' >> "$count_file"; command jq "$@"; }
  _patrol_poll_cues || true
  local -a calls=()
  mapfile -t calls < "$count_file"
  printf '__poll_jq=%s pending=%s\n' "${#calls[@]}" "$cue_pending"
}

cue_evolving_probe() {
  local mode=$1 cam_name=Overwatch last_commanded_slot=0
  local _LAST_TRACKING_ACTIVE=0 _LAST_ACTIVITY_KNOWN=1
  local -a cue_camera_ids=(fixed1) cue_slots=(4) cue_types=($'\t"person"\t')
  local -a cue_holds=(30) cue_cooldowns=(0) cue_names=(One) cue_until=(0)
  local -x cue_query='&cameras=fixed1' cue_pending=-1 cue_match="" cue_matched_at=0 cue_poll_failed=0
  local -A cue_seen=()
  CUE_BODY=$(cue_fixture)
  CUE_BODY=$(jq -c '.[0:1] | .[0].smartDetectTypes=["animal","person"]' <<< "$CUE_BODY")
  case "$mode" in
    types) CUE_BODY=$(jq -c '.[0].smartDetectTypes=["animal"]' <<< "$CUE_BODY") ;;
    cooldown) cue_until=(1005) ;;
    current) last_commanded_slot=4 ;;
  esac
  _patrol_poll_cues || true
  printf '__evolving_first=%s seen=%s\n' "$cue_pending" "${#cue_seen[@]}"
  CUE_NOW=1005
  last_commanded_slot=0
  CUE_BODY=$(jq -c '.[0].smartDetectTypes=["animal","person"]' <<< "$CUE_BODY")
  _patrol_poll_cues || true
  printf '__evolving_second=%s seen=%s\n' "$cue_pending" "${#cue_seen[@]}"
  CUE_NOW=1006
  _patrol_poll_cues || true
  printf '__evolving_third=%s seen=%s\n' "$cue_pending" "${#cue_seen[@]}"
  CUE_NOW=1120
  CUE_BODY='[]'
  _patrol_poll_cues || true
  printf '__evolving_pruned=%s\n' "${#cue_seen[@]}"
}
