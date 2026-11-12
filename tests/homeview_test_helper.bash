#!/usr/bin/env bash

# shellcheck source=/dev/null
source "$BATS_TEST_DIRNAME/field_test_helper.bash"

HOMEVIEW_BODY='{"slot":-1,"ptz":{"pan":10880,"tilt":11430,"zoom":0}}'
HOMEVIEW_CODE=200
HOMEVIEW_READS=0
external_control_until=0
expected_pan=-1
expected_tilt=-1
expected_zoom=-1

api_get() {
  [[ "$1" == /cameras/cam-1/ptz/home ]] || return 99
  HOMEVIEW_READS=$(( HOMEVIEW_READS + 1 ))
  printf '__home_read=%s\n' "$HOMEVIEW_READS" >&2
  _LAST_HTTP_CODE=$HOMEVIEW_CODE
  _LAST_BODY=$HOMEVIEW_BODY
}

api_get_preset_positions() {
  printf '[{"slot":0,"pan":11127,"tilt":10412,"zoom":710},{"slot":4,"pan":11127,"tilt":10412,"zoom":710}]'
}

sleep() {
  FIELD_NOW=$(( FIELD_NOW + $1 ))
  if (( external_control_until > 0 )); then
    printf '__external_hold=1 home_reads=%s\n' "$HOMEVIEW_READS"
    exit 0
  fi
  if (( FIELD_NOW > 1300 )); then exit 99; fi
}

api_post_with_retry() {
  FIELD_GOTOS=$(( FIELD_GOTOS + 1 ))
  if (( FIELD_GOTOS >= 2 )); then
    local reads
    reads=$(ptz_reads_consumed)
    printf '__next_goto=%s now=%s reads=%s home_reads=%s previous_expected=%s/%s/%s\n' \
      "${1##*/}" "$FIELD_NOW" "$reads" "$HOMEVIEW_READS" "$expected_pan" "$expected_tilt" "$expected_zoom" >&2
    exit 0
  fi
  _LAST_HTTP_CODE=200
}

homeview_patrol_probe() {
  local dwell=${1:-18} live=${2:-$'10880\t11430\t0'}
  PTZ_READS=($'11127\t10412\t710' $'11127\t10412\t710' "$live" "$live" "$live")
  ptz_queue_prepare
  field_probe "{\"dwell_seconds\":$dwell,\"ptz_settle_seconds\":0}" 2
}

homeview_home_probe() {
  PTZ_READS=($'11127\t10412\t710' $'11127\t10412\t710' $'10880\t11430\t0' $'10880\t11430\t0')
  home_probe 4
}

homeview_reset_probe() {
  PTZ_READS=($'10880\t11430\t0' '')
  ptz_queue_prepare
  printf '__queued=%s\n' "${#PTZ_READS[@]}"
  is_externally_controlled cam-1 Overwatch 0 0 11127 10412 710 acquired 2
  printf '__first_home=%s\n' "$_LAST_AT_HOMEVIEW"
  is_externally_controlled cam-1 Overwatch 0 0 11127 10412 710 acquired 2
  printf '__failed_position_home=%s\n' "$_LAST_AT_HOMEVIEW"
}
