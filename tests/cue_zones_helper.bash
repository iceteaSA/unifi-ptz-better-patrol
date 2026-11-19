#!/usr/bin/env bash

# shellcheck source=/dev/null
source "$BATS_TEST_DIRNAME/cue_test_helper.bash"

ZONE_SOURCE_BODY=""
ZONE_SOURCE_CODE=200
ZONE_REQUESTS_FILE=""

api_get() {
  printf '%s\n' "$1" >> "$ZONE_REQUESTS_FILE"
  if [[ "$1" == /events* ]]; then
    _LAST_HTTP_CODE=200
    _LAST_BODY=$CUE_BODY
  else
    _LAST_HTTP_CODE=$ZONE_SOURCE_CODE
    _LAST_BODY=$ZONE_SOURCE_BODY
  fi
}

zone_probe() {
  local cam_id=cam1 cam_name=Overwatch cam_config="{\"cues\":$1}"
  local cam_discovery_json='{"presets":[{"slot":0},{"slot":4},{"slot":2}]}'
  local -a presets=(0 4 2) cue_camera_ids=() cue_slots=() cue_types=() cue_holds=() cue_cooldowns=() cue_names=() cue_until=() cue_zones=()
  local cue_query="" cue_pending=-1 cue_match="" last_commanded_slot=0
  local -x cue_matched_at=0 cue_poll_failed=0
  local -A cue_seen=()
  ZONE_REQUESTS_FILE="$BATS_TEST_TMPDIR/zone-requests"
  : > "$ZONE_REQUESTS_FILE"
  CUE_BODY=$(cue_fixture)
  CUE_BODY=$(command jq -c '.[0:1] | .[0].metadata.zonesStatus={"2":{"level":84,"status":"leave"}} | .[0].smartDetectTypes=["animal","person"]' <<< "$CUE_BODY")
  case "${2:-}" in
    other|later) CUE_BODY=$(command jq -c '.[0].metadata.zonesStatus={"1":{}}' <<< "$CUE_BODY") ;;
    no-zones) CUE_BODY=$(command jq -c 'del(.[0].metadata.zonesStatus)' <<< "$CUE_BODY") ;;
    bad-zones) CUE_BODY=$(command jq -c '.[0].metadata.zonesStatus=["2"]' <<< "$CUE_BODY") ;;
    two-zones) CUE_BODY=$(command jq -c '.[0].metadata.zonesStatus={"1":{},"2":{}}' <<< "$CUE_BODY") ;;
    five) CUE_BODY=$(command jq -c '.[0].metadata.zonesStatus={"5":{}}' <<< "$CUE_BODY") ;;
  esac
  _patrol_parse_cues
  printf '__entries=%s\n' "${#cue_slots[@]}"
  local i
  for (( i=0; i<${#cue_slots[@]}; i++ )); do
    printf '__zones[%s]=%q\n' "$i" "${cue_zones[$i]:-}"
  done
  _patrol_poll_cues || true
  printf '__first=%s seen=%s warnings=%s\n' "$cue_pending" "${#cue_seen[@]}" "$CUE_WARNINGS"
  if [[ "${2:-}" == later ]]; then
    CUE_NOW=1001
    CUE_BODY=$(command jq -c '.[0].metadata.zonesStatus={"1":{},"2":{}}' <<< "$CUE_BODY")
    _patrol_poll_cues || true
    printf '__second=%s seen=%s\n' "$cue_pending" "${#cue_seen[@]}"
    CUE_NOW=1002
    _patrol_poll_cues || true
    printf '__third=%s seen=%s\n' "$cue_pending" "${#cue_seen[@]}"
  fi
  local -a requests=()
  mapfile -t requests < "$ZONE_REQUESTS_FILE"
  printf '__requests=%s\n' "${requests[*]}"
}
