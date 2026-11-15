#!/usr/bin/env bash

# shellcheck source=/dev/null
source "$BATS_TEST_DIRNAME/field_test_helper.bash"

HOLD_HOME_BODY='{"ptz":{"pan":8500,"tilt":10200,"zoom":250}}'
HOLD_HOME_CODE=200
HOLD_HOME_READS_FILE=""
HOLD_POSITION_READS_FILE=""
HOLD_ORIGIN=normal
HOLD_POSITIONS=()
HOLD_HERE=$'8500\t10200\t250'
HOLD_OFF=$'8800\t10200\t250'

_hold_position_definition=$(declare -f api_get_ptz_position)
_hold_position_definition=${_hold_position_definition/api_get_ptz_position/_hold_detector_position}
eval "$_hold_position_definition"
_hold_external_definition=$(declare -f is_externally_controlled)
_hold_external_definition=${_hold_external_definition/is_externally_controlled/_hold_real_external}
eval "$_hold_external_definition"

is_externally_controlled() {
  printf '__classify now=%s expected=%s/%s/%s acquisition=%s/%s drift=%s/%s/%s\n' \
    "$FIELD_NOW" "$5" "$6" "$7" "${8:-none}" "${9:-0}" \
    "${top_drift_attempts:-0}" "${top_drift_streak:-0}" "${top_previous_drift:-0}"
  _hold_real_external "$@"
}

api_get() {
  [[ "$1" == /cameras/cam-1/ptz/home ]] || return 99
  local count
  IFS= read -r count < "$HOLD_HOME_READS_FILE"
  printf '%s\n' "$(( count + 1 ))" > "$HOLD_HOME_READS_FILE"
  _LAST_HTTP_CODE=$HOLD_HOME_CODE
  _LAST_BODY=$HOLD_HOME_BODY
}

api_get_ptz_position() {
  if (( ${external_control_until:-0} <= FIELD_NOW )); then
    _hold_detector_position "$@"
    return
  fi
  local count index position
  IFS= read -r count < "$HOLD_POSITION_READS_FILE"
  printf '%s\n' "$(( count + 1 ))" > "$HOLD_POSITION_READS_FILE"
  index=$count
  (( index < ${#HOLD_POSITIONS[@]} )) || index=$(( ${#HOLD_POSITIONS[@]} - 1 ))
  position=${HOLD_POSITIONS[$index]}
  printf '__hold_position=%s now=%s\n' "$(( count + 1 ))" "$FIELD_NOW" >&2
  if [[ "$position" == __FAIL__ ]]; then
    printf '%s\n' "$HOLD_HERE"
    return 1
  fi
  printf '%s\n' "$position"
}

api_get_preset_positions() {
  printf '[{"slot":0,"pan":8500,"tilt":10200,"zoom":250},{"slot":4,"pan":8500,"tilt":10200,"zoom":250}]'
}

api_post_with_retry() {
  FIELD_GOTOS=$(( FIELD_GOTOS + 1 ))
  printf '__goto=%s now=%s\n' "${1##*/}" "$FIELD_NOW" >&2
  local limit=2
  [[ "$HOLD_ORIGIN" != home ]] || limit=4
  if (( FIELD_GOTOS >= limit )); then
    local position_reads home_reads
    IFS= read -r position_reads < "$HOLD_POSITION_READS_FILE"
    IFS= read -r home_reads < "$HOLD_HOME_READS_FILE"
    # shellcheck disable=SC2154 # patrol_camera owns these caller-scope movement fields.
    printf '__next_goto=%s now=%s hold_reads=%s home_reads=%s expected=%s/%s/%s acquisition=%s/%s\n' \
      "${1##*/}" "$FIELD_NOW" "$position_reads" "$home_reads" \
      "$expected_pan" "$expected_tilt" "$expected_zoom" "$acquisition_state" "$acquisition_streak" >&2
    exit 0
  fi
  _LAST_HTTP_CODE=200
}

api_post_status() { printf '__state=%s now=%s\n' "$3" "$FIELD_NOW"; }

log() {
  printf '[%s] %s: %s\n' "$1" "$2" "$3"
  if [[ "$3" == External\ control\ detected*holding\ patrol* ]]; then
    printf '__hold_start origin=%s now=%s target=%s/%s/%s deadline=%s\n' \
      "$HOLD_ORIGIN" "$FIELD_NOW" "${hold_home_pan:--1}" "${hold_home_tilt:--1}" "${hold_home_zoom:--1}" "$external_control_until"
  fi
}

sleep() {
  FIELD_NOW=$(( FIELD_NOW + $1 ))
  if (( FIELD_NOW > 1500 )); then exit 99; fi
}

hold_files_prepare() {
  HOLD_HOME_READS_FILE="$BATS_TEST_TMPDIR/home-reads"
  HOLD_POSITION_READS_FILE="$BATS_TEST_TMPDIR/hold-reads"
  printf '0\n' > "$HOLD_HOME_READS_FILE"
  printf '0\n' > "$HOLD_POSITION_READS_FILE"
  PTZ_QUEUE_FILE="$BATS_TEST_TMPDIR/detect-queue"
  printf '%s\n' "${PTZ_READS[@]}" > "$PTZ_QUEUE_FILE"
}

hold_patrol_probe() {
  HOLD_ORIGIN=$1
  shift
  HOLD_POSITIONS=("$@")
  if (( ${#HOLD_POSITIONS[@]} == 0 )); then HOLD_POSITIONS=("$HOLD_HERE" "$HOLD_HERE"); fi
  local config='{"dwell_seconds":24,"ptz_settle_seconds":0,"manual_control_hold_seconds":120,"status_heartbeat_seconds":0}'
  PTZ_READS=("$HOLD_HERE" "$HOLD_HERE" "$HOLD_OFF" "$HOLD_OFF")
  case "$HOLD_ORIGIN" in
    top)
      config='{"dwell_seconds":10,"ptz_settle_seconds":0,"manual_control_hold_seconds":120,"status_heartbeat_seconds":0}'
      PTZ_READS=("$HOLD_HERE" "$HOLD_HERE" "$HOLD_HERE" "$HOLD_HERE" "$HOLD_OFF" "$HOLD_OFF")
      ;;
    home)
      config='{"preset_slots":[0,4],"home_between_cycles":true,"dwell_seconds":20,"ptz_settle_seconds":0,"manual_control_hold_seconds":120,"status_heartbeat_seconds":0}'
      PTZ_READS=("$HOLD_HERE" "$HOLD_HERE" "$HOLD_HERE" "$HOLD_HERE" "$HOLD_HERE" "$HOLD_HERE" "$HOLD_HERE" "$HOLD_HERE" "$HOLD_HERE" "$HOLD_HERE" "$HOLD_HERE" "$HOLD_OFF" "$HOLD_OFF")
      ;;
  esac
  hold_files_prepare
  _STATUS_WEBHOOK_URL=https://example.invalid/status
  field_probe "$config" 99
}

hold_globals_probe() {
  PTZ_READS=("$HOLD_OFF" "$HOLD_OFF")
  hold_files_prepare
  is_externally_controlled cam-1 Overwatch 0 0 8500 10200 250 acquired 2 || true
  printf '__known_home=%s/%s/%s\n' "${_LAST_HOME_PAN:--1}" "${_LAST_HOME_TILT:--1}" "${_LAST_HOME_ZOOM:--1}"
  is_externally_controlled cam-1 Overwatch 0 0 -1 -1 -1 acquiring 0 || true
  printf '__unread_home=%s/%s/%s\n' "${_LAST_HOME_PAN:--1}" "${_LAST_HOME_TILT:--1}" "${_LAST_HOME_ZOOM:--1}"
  HOLD_HOME_CODE=503
  is_externally_controlled cam-1 Overwatch 0 0 8500 10200 250 acquired 2 || true
  printf '__failed_home=%s/%s/%s\n' "${_LAST_HOME_PAN:--1}" "${_LAST_HOME_TILT:--1}" "${_LAST_HOME_ZOOM:--1}"
  local count
  IFS= read -r count < "$HOLD_HOME_READS_FILE"
  printf '__home_requests=%s\n' "$count"
}
