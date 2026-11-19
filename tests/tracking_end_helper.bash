#!/usr/bin/env bash

# shellcheck source=/dev/null
source "$BATS_TEST_DIRNAME/activity_hold_helper.bash"

END_POSITION_BODY=$'8500\t10200\t250'
END_SECOND_POSITION_BODY=""
END_POSITION_RC=0
END_POSITION_FILE=""
END_LOG_FILE=""

api_get_ptz_position() {
  printf 'position %s\n' "$FIELD_NOW" >> "$ACTIVITY_READS_FILE"
  printf 'position\n' >> "$END_POSITION_FILE"
  local -a reads=()
  mapfile -t reads < "$END_POSITION_FILE"
  if (( ${#reads[@]} == 2 )) && [[ -n "$END_SECOND_POSITION_BODY" ]]; then
    printf '%s\n' "$END_SECOND_POSITION_BODY"
  else
    printf '%s\n' "$END_POSITION_BODY"
  fi
  return "$END_POSITION_RC"
}

log() {
  printf '[%s] %s: %s\n' "$1" "$2" "$3"
  [[ "$3" != 'Tracking ended'* ]] || printf 'end\n' >> "$END_LOG_FILE"
}

sleep() {
  printf 'sleep %s\n' "$FIELD_NOW" >> "$ACTIVITY_READS_FILE"
  FIELD_NOW=$(( FIELD_NOW + $1 ))
  (( FIELD_NOW < 1500 )) || exit 99
}

api_post_with_retry() {
  local -a positions=() logs=()
  mapfile -t positions < "$END_POSITION_FILE"
  mapfile -t logs < "$END_LOG_FILE"
  printf 'goto %s\n' "$FIELD_NOW" >> "$ACTIVITY_READS_FILE"
  printf '__goto=%s now=%s position_reads=%s end_logs=%s\n' "${1##*/}" "$FIELD_NOW" "${#positions[@]}" "${#logs[@]}" >&2
  exit 0
}

tracking_end_probe() {
  END_POSITION_FILE="$BATS_TEST_TMPDIR/end-position-reads"
  END_LOG_FILE="$BATS_TEST_TMPDIR/end-logs"
  : > "$END_POSITION_FILE"
  : > "$END_LOG_FILE"
  activity_hold_probe "$@"
}
