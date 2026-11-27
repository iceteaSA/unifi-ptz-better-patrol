#!/usr/bin/env bash

# shellcheck source=/dev/null
source "$BATS_TEST_DIRNAME/cue_reacquire_helper.bash"

NADIR_MODE=empty
NADIR_COUNTS=""
NADIR_COUNTING=0

jq() {
  if (( NADIR_COUNTING )); then printf 'jq\n' >> "$NADIR_COUNTS"; fi
  command jq "$@"
}

api_get() {
  _LAST_HTTP_CODE=200
  case "$1" in
    */ptz/position)
      printf 'position\n' >> "$NADIR_COUNTS"
      printf '__sample now=%s\n' "$FIELD_NOW"
      _LAST_BODY='{"steps":{"pan":35000,"tilt":16000,"zoom":0}}'
      case "$NADIR_MODE" in
        home|failure|malformed)
          if (( FIELD_NOW >= 1003 )); then
            _LAST_BODY='{"steps":{"pan":18362,"tilt":10914,"zoom":0}}'
            [[ "$NADIR_MODE" != failure ]] || _LAST_HTTP_CODE=503
            [[ "$NADIR_MODE" != malformed ]] || _LAST_BODY='{"steps":{"pan":true}}'
          fi ;;
        shallow) _LAST_BODY='{"steps":{"pan":35000,"tilt":15000,"zoom":0}}' ;;
      esac ;;
    /events*)
      printf '__events now=%s\n' "$FIELD_NOW"
      _LAST_BODY=$CUE_BODY ;;
    *) _LAST_BODY=$REACQUIRE_SOURCE_BODY ;;
  esac
}

api_get_ptz_home() {
  printf 'home\n' >> "$NADIR_COUNTS"
  [[ "$NADIR_MODE" != home-failure ]] || return 1
  printf '18362\t10914\t0\n'
}

api_get_ptz_position() { printf '18362\t10914\t0\n'; }

api_get_camera_state() {
  NADIR_COUNTING=1
  _CACHED_CAM_STATE='{"id":"cam1","state":"CONNECTED"}'
  if (( FIELD_NOW < 1005 )); then
    if [[ "$NADIR_MODE" == later || "$NADIR_MODE" == never ]]; then
      _CACHED_CAM_STATE='{"id":"cam1","state":"CONNECTED","isMotionDetected":true}'
    else
      _CACHED_CAM_STATE='{"id":"cam1","state":"CONNECTED","isAutoTracking":true}'
    fi
  elif [[ "$NADIR_MODE" == later ]] && (( FIELD_NOW < 1010 )); then
    _CACHED_CAM_STATE='{"id":"cam1","state":"CONNECTED","isAutoTracking":true}'
  elif [[ "$NADIR_MODE" == once ]] && (( FIELD_NOW < 1020 )); then
    _CACHED_CAM_STATE='{"id":"cam1","state":"CONNECTED","isMotionDetected":true}'
  fi
}

sleep() {
  printf 'sleep%s\n' "$1" >> "$NADIR_COUNTS"
  printf '__sleep=%s now=%s\n' "$1" "$FIELD_NOW"
  FIELD_NOW=$(( FIELD_NOW + $1 )); CUE_NOW=$FIELD_NOW
  (( FIELD_NOW < 1100 )) || exit 99
}

api_post_with_retry() {
  local -a counts=()
  mapfile -t counts < "$NADIR_COUNTS"
  printf '__counts=%s\n' "${counts[*]}" >&2
  printf '__goto=%s now=%s cue=%s source=%s\n' "${1##*/}" "$FIELD_NOW" "$cue_in_progress" "$status_cue_camera" >&2
  exit 0
}

nadir_hold_probe() {
  local _LOG_LEVEL=3
  NADIR_MODE=$1
  NADIR_COUNTS="$BATS_TEST_TMPDIR/nadir-counts"
  : > "$NADIR_COUNTS"
  FIELD_NOW=1000 CUE_NOW=1000 NADIR_COUNTING=0
  FIELD_CONFIG='{"dwell_seconds":6,"ptz_settle_seconds":0,"nadir_handoff":{"tilt_min":15800,"sectors":[]}}'
  [[ "$NADIR_MODE" != disabled ]] || FIELD_CONFIG='{"dwell_seconds":6,"ptz_settle_seconds":0}'
  if [[ "$NADIR_MODE" == cues ]]; then
    FIELD_CONFIG=${FIELD_CONFIG%\}}',"cues":[{"camera_id":"fixed1","slot":4,"zones":["Past pole"]}]}'
  fi
  CUE_BODY=$(reacquire_fixture)
  patrol_camera cam1 Overwatch "$FIELD_DISCOVERY"
}

nadir_parse_probe() {
  local cam_config=$1 cam_id=cam1 cam_name=Overwatch
  local preset_positions='[{"slot":7}]' cam_discovery_json='{"presets":[{"slot":0},{"slot":4}]}'
  local nadir_enabled=0 nadir_tilt_min=0 nadir_hold=20
  local -a nadir_pan_mins=() nadir_pan_maxs=() nadir_slots=()
  local -a cue_camera_ids=() cue_slots=() cue_types=() cue_holds=() cue_cooldowns=() cue_names=() cue_zones=() cue_until=()
  local -A cue_zone_labels=()
  local cue_query=""
  _patrol_parse_cues
  printf '__enabled=%s tilt=%s hold=%s sectors=%s warnings=%s query=%s\n' "$nadir_enabled" "$nadir_tilt_min" "$nadir_hold" "${#nadir_slots[@]}" "$CUE_WARNINGS" "$cue_query"
}

nadir_config_probe() {
  source "$BATS_TEST_DIRNAME/../discover.sh"
  cfg() {
    if [[ "$1" == .defaults ]]; then
      printf '{"dwell_seconds":9,"nadir_handoff":{"tilt_min":1,"sectors":[]}}'
    else
      printf '%s' "${1:+$NADIR_OVERRIDE}"
    fi
  }
  get_camera_config cam1
}
