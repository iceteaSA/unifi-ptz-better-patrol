#!/usr/bin/env bash

source "$BATS_TEST_DIRNAME/test_helper.bash"
source "$BATS_TEST_DIRNAME/../patrol.sh"

PATROL_SETTLE_CALLS=0
_real_patrol_wait_for_camera_settle_definition=$(declare -f _patrol_wait_for_camera_settle)
_real_patrol_wait_for_camera_settle_definition=${_real_patrol_wait_for_camera_settle_definition//_patrol_wait_for_camera_settle/_real_patrol_wait_for_camera_settle}
eval "$_real_patrol_wait_for_camera_settle_definition"
_patrol_wait_for_camera_settle() {
  PATROL_SETTLE_CALLS=$(( PATROL_SETTLE_CALLS + 1 ))
  _real_patrol_wait_for_camera_settle "$@"
}

PTZ_READS=()
PTZ_QUEUE_FILE=""
HOME_CAMERA_STATES=()
HOME_CAMERA_INDEX=0
PATROL_MODE=""
PATROL_DWELL=0
PATROL_GOTO_COUNT=0
PATROL_SLEEP_COUNT=0
PATROL_FAKE_NOW=1000

ptz_queue_prepare() {
  PTZ_QUEUE_FILE=$(mktemp)
  printf '%s\n' "${PTZ_READS[@]}" > "$PTZ_QUEUE_FILE"
}

ptz_reads_consumed() {
  local remaining
  remaining=$(wc -l < "$PTZ_QUEUE_FILE")
  printf '%s\n' "$(( ${#PTZ_READS[@]} - remaining ))"
}

api_get_ptz_position() {
  local position=""
  if [[ -s "$PTZ_QUEUE_FILE" ]]; then
    IFS= read -r position < "$PTZ_QUEUE_FILE"
    tail -n +2 "$PTZ_QUEUE_FILE" > "${PTZ_QUEUE_FILE}.next"
    mv "${PTZ_QUEUE_FILE}.next" "$PTZ_QUEUE_FILE"
  fi
  printf '%s\n' "$position"
}

api_post_with_retry() {
  if [[ "$PATROL_MODE" == settle-* ]]; then
    if [[ "$PATROL_MODE" == "settle-once" ]]; then
      PATROL_GOTO_COUNT=$(( PATROL_GOTO_COUNT + 1 ))
      if (( PATROL_GOTO_COUNT >= 2 )); then
        printf '__goto_advanced=1 settle_calls=%s now=%s\n' "$PATROL_SETTLE_CALLS" "$PATROL_FAKE_NOW" >&2
        exit 0
      fi
    elif [[ "$1" == */goto/1 ]]; then
      printf '__patrol_started=1 settle_calls=%s now=%s\n' "$PATROL_SETTLE_CALLS" "$PATROL_FAKE_NOW" >&2
      exit 0
    fi
  elif [[ "$PATROL_MODE" == "failed-goto" ]]; then
    PATROL_GOTO_COUNT=$(( PATROL_GOTO_COUNT + 1 ))
    if [[ "$1" == */goto/1 ]] && (( PATROL_GOTO_COUNT >= 3 )); then
      printf '__goto_advanced=1 gotos=%s\n' "$PATROL_GOTO_COUNT" >&2
      exit 0
    fi
  elif [[ -n "$PATROL_MODE" ]]; then
    PATROL_GOTO_COUNT=$(( PATROL_GOTO_COUNT + 1 ))
    if (( PATROL_GOTO_COUNT >= 2 )); then
      printf '__goto_advanced=1\n' >&2
      exit 0
    fi
  fi
  _LAST_HTTP_CODE=200
  return 0
}

api_get_camera_state() {
  local state
  if (( ${#HOME_CAMERA_STATES[@]} == 0 )); then
    state='{"id":"cam-1","state":"CONNECTED","lastMotion":0}'
  elif (( HOME_CAMERA_INDEX < ${#HOME_CAMERA_STATES[@]} )); then
    state=${HOME_CAMERA_STATES[$HOME_CAMERA_INDEX]}
  else
    state=${HOME_CAMERA_STATES[${#HOME_CAMERA_STATES[@]} - 1]}
  fi
  HOME_CAMERA_INDEX=$(( HOME_CAMERA_INDEX + 1 ))

  if [[ "$state" == "__FAIL__" ]]; then
    return 1
  fi
  _CACHED_CAM_STATE=$state
  return 0
}

sleep() {
  if [[ -n "$PATROL_MODE" ]]; then
    PATROL_SLEEP_COUNT=$(( PATROL_SLEEP_COUNT + 1 ))
    if [[ "$PATROL_MODE" == settle-* ]]; then
      PATROL_FAKE_NOW=$(( PATROL_FAKE_NOW + ${1:-1} ))
    fi
    if (( external_control_until > 0 )); then
      printf '__external_hold=1\n'
      exit 0
    fi
    if [[ "$PATROL_MODE" != settle-* ]] && (( PATROL_SLEEP_COUNT > 20 )); then
      printf '__probe_timeout=1\n'
      exit 99
    fi
    if [[ "$PATROL_MODE" == settle-* ]] && (( PATROL_SLEEP_COUNT > 40 )); then
      printf '__probe_timeout=1\n'
      exit 99
    fi
  fi
  return 0
}

date() {
  if [[ "$PATROL_MODE" == settle-* ]]; then
    printf '%s\n' "$PATROL_FAKE_NOW"
  else
    command date "$@"
  fi
}

api_ensure_auth() {
  return 0
}

is_within_schedule() {
  return 0
}

get_camera_config() {
  printf '{"enabled":true,"dwell_seconds":%s,"motion_hold_seconds":60,"manual_control_hold_seconds":120,"ptz_settle_seconds":0}' "$PATROL_DWELL"
}

api_get_preset_positions() {
  if [[ "$PATROL_MODE" == "failed-goto" ]]; then
    printf '[{"slot":1,"name":"Preset 1","pan":7100,"tilt":10400,"zoom":97},{"slot":2,"name":"Preset 2","pan":11600,"tilt":10400,"zoom":97}]\n'
  else
    printf '[{"slot":1,"name":"Preset 1","pan":11600,"tilt":10400,"zoom":100},{"slot":2,"name":"Preset 2","pan":11600,"tilt":10400,"zoom":100}]\n'
  fi
}

external_probe() {
  local position=$1 expected_pan=$2 expected_tilt=$3 expected_zoom=$4
  local acquisition_state=${5:-none} acquisition_streak=${6:-0}
  PTZ_READS=("$position")
  ptz_queue_prepare

  is_externally_controlled cam-1 Overwatch 0 0 \
    "$expected_pan" "$expected_tilt" "$expected_zoom" \
    "$acquisition_state" "$acquisition_streak"
  local rc=$?
  local reads
  reads=$(ptz_reads_consumed)
  printf '\n__external_status=%s magnitude=%s reads=%s goto_failed=%s acquisition=%s/%s\n' \
    "$rc" "$_LAST_DRIFT_MAGNITUDE" "$reads" "$_LAST_GOTO_FAILED" \
    "$_LAST_ACQUISITION_STATE" "$_LAST_ACQUISITION_STREAK"
  rm -f "$PTZ_QUEUE_FILE" "${PTZ_QUEUE_FILE}.next"
  return "$rc"
}

goto_failure_reset_probe() {
  PTZ_READS=(
    $'7200\t10400\t97'
    $'19000\t10400\t97'
  )
  ptz_queue_prepare

  is_externally_controlled cam-1 Overwatch 0 0 11600 10400 97 acquiring 0
  local first_rc=$?
  local first_failed=$_LAST_GOTO_FAILED
  is_externally_controlled cam-1 Overwatch 0 0 11600 10400 97 acquired 2
  local second_rc=$?
  local second_failed=$_LAST_GOTO_FAILED
  local reads
  reads=$(ptz_reads_consumed)
  printf '\n__reset_first=%s/%s second=%s/%s reads=%s\n' \
    "$first_rc" "$first_failed" "$second_rc" "$second_failed" "$reads"
  rm -f "$PTZ_QUEUE_FILE" "${PTZ_QUEUE_FILE}.next"
  return "$second_rc"
}

home_probe() {
  local dwell=$1
  local last_goto_ts=0
  local expected_pan=-1 expected_tilt=-1 expected_zoom=-1
  local tracking_enabled=0 external_control_until=0
  local acquisition_state=none acquisition_streak=0
  HOME_CAMERA_INDEX=0
  ptz_queue_prepare

  _patrol_home_dwell cam-1 Overwatch "$dwell" 60 0 120 false 1
  local rc=$?
  local reads
  reads=$(ptz_reads_consumed)
  printf '\n__home_status=%s ptz_reads=%s expected=%s/%s/%s acquisition=%s/%s\n' \
    "$rc" "$reads" "$expected_pan" "$expected_tilt" "$expected_zoom" \
    "$acquisition_state" "$acquisition_streak"
  rm -f "$PTZ_QUEUE_FILE" "${PTZ_QUEUE_FILE}.next"
  return "$rc"
}

patrol_probe() {
  local dwell=$1 mode=$2
  PATROL_MODE=$mode
  PATROL_DWELL=$dwell
  PATROL_GOTO_COUNT=0
  PATROL_SLEEP_COUNT=0
  PATROL_FAKE_NOW=1000
  PATROL_SETTLE_CALLS=0
  HOME_CAMERA_INDEX=0
  ptz_queue_prepare

  local discovery_json='{"id":"cam-1","name":"Overwatch","presets":[{"slot":1},{"slot":2}]}'
  patrol_camera cam-1 Overwatch "$discovery_json"
  local rc=$?
  printf '\n__patrol_status=%s gotos=%s sleeps=%s\n' \
    "$rc" "$PATROL_GOTO_COUNT" "$PATROL_SLEEP_COUNT"
  return "$rc"
}
