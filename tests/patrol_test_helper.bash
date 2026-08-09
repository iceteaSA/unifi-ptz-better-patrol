#!/usr/bin/env bash

source "$BATS_TEST_DIRNAME/test_helper.bash"
source "$BATS_TEST_DIRNAME/../patrol.sh"

PTZ_READS=()
PTZ_QUEUE_FILE=""
HOME_CAMERA_STATES=()
HOME_CAMERA_INDEX=0
PATROL_MODE=""
PATROL_DWELL=0
PATROL_GOTO_COUNT=0
PATROL_SLEEP_COUNT=0

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
  if [[ -n "$PATROL_MODE" ]]; then
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
    if (( external_control_until > 0 )); then
      printf '__external_hold=1\n'
      exit 0
    fi
    if (( PATROL_SLEEP_COUNT > 20 )); then
      printf '__probe_timeout=1\n'
      exit 99
    fi
  fi
  return 0
}

api_ensure_auth() {
  return 0
}

is_within_schedule() {
  return 0
}

get_camera_config() {
  printf '{"enabled":true,"dwell_seconds":%s,"motion_hold_seconds":60,"manual_control_hold_seconds":120,"ptz_settle_seconds":0,"preset_slots":[1,2]}' "$PATROL_DWELL"
}

api_get_preset_positions() {
  printf '[{"slot":1,"name":"Preset 1","pan":11600,"tilt":10400,"zoom":100},{"slot":2,"name":"Preset 2","pan":11600,"tilt":10400,"zoom":100}]\n'
}

external_probe() {
  local position=$1 expected_pan=$2 expected_tilt=$3 expected_zoom=$4
  PTZ_READS=("$position")
  ptz_queue_prepare

  is_externally_controlled cam-1 Overwatch 0 0 \
    "$expected_pan" "$expected_tilt" "$expected_zoom"
  local rc=$?
  local reads
  reads=$(ptz_reads_consumed)
  printf '\n__external_status=%s magnitude=%s reads=%s\n' \
    "$rc" "$_LAST_DRIFT_MAGNITUDE" "$reads"
  rm -f "$PTZ_QUEUE_FILE" "${PTZ_QUEUE_FILE}.next"
  return "$rc"
}

home_probe() {
  local dwell=$1
  local last_goto_ts=0
  local expected_pan=-1 expected_tilt=-1 expected_zoom=-1
  local tracking_enabled=0 external_control_until=0
  HOME_CAMERA_INDEX=0
  ptz_queue_prepare

  _patrol_home_dwell cam-1 Overwatch "$dwell" 60 0 120 false 1
  local rc=$?
  local reads
  reads=$(ptz_reads_consumed)
  printf '\n__home_status=%s ptz_reads=%s expected=%s/%s/%s\n' \
    "$rc" "$reads" "$expected_pan" "$expected_tilt" "$expected_zoom"
  rm -f "$PTZ_QUEUE_FILE" "${PTZ_QUEUE_FILE}.next"
  return "$rc"
}

patrol_probe() {
  local dwell=$1 mode=$2
  PATROL_MODE=$mode
  PATROL_DWELL=$dwell
  PATROL_GOTO_COUNT=0
  PATROL_SLEEP_COUNT=0
  HOME_CAMERA_INDEX=0
  ptz_queue_prepare

  patrol_camera cam-1 Overwatch
  local rc=$?
  printf '\n__patrol_status=%s gotos=%s sleeps=%s\n' \
    "$rc" "$PATROL_GOTO_COUNT" "$PATROL_SLEEP_COUNT"
  return "$rc"
}
