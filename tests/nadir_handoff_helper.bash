#!/usr/bin/env bash

# shellcheck source=/dev/null
source "$BATS_TEST_DIRNAME/cue_reacquire_helper.bash"

NADIR_MODE=empty
NADIR_COUNTS=""
NADIR_COUNTING=0
NADIR_LIMIT=3
NADIR_NEXT='[]'

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
        home-failure|home-only) _LAST_BODY='{"steps":{"pan":18362,"tilt":10914,"zoom":0}}' ;;
        home|failure|malformed)
          if (( FIELD_NOW >= 1003 )); then
            _LAST_BODY='{"steps":{"pan":18362,"tilt":10914,"zoom":0}}'
            [[ "$NADIR_MODE" != failure ]] || _LAST_HTTP_CODE=503
            [[ "$NADIR_MODE" != malformed ]] || _LAST_BODY='{"steps":{"pan":true}}'
          fi ;;
        shallow) _LAST_BODY='{"steps":{"pan":35000,"tilt":15000,"zoom":0}}' ;;
        flicker)
          if (( FIELD_NOW <= 1005 )); then _LAST_BODY='{"steps":{"pan":35000,"tilt":15000,"zoom":0}}'; fi ;;
        expire)
          if (( FIELD_NOW >= 1009 )); then _LAST_BODY='{"steps":{"pan":35000,"tilt":15000,"zoom":0}}'; fi ;;
      esac ;;
    /events*)
      printf '__events now=%s cutoff=%s\n' "$FIELD_NOW" "${nadir_event_cutoff:-0}"
      _LAST_BODY=$CUE_BODY
      case "$NADIR_MODE" in
        newer|same-second|expire) _LAST_BODY=$NADIR_NEXT ;;
      esac ;;
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
  if [[ "$NADIR_MODE" == pickup ]] && (( FIELD_NOW >= 1010 && FIELD_NOW < 1015 )); then
    _CACHED_CAM_STATE='{"id":"cam1","state":"CONNECTED","isAutoTracking":true}'
    return 0
  fi
  if [[ "$NADIR_MODE" == flicker ]] && (( FIELD_NOW >= 1005 && FIELD_NOW < 1015 )); then
    if (( FIELD_NOW < 1010 )); then
      _CACHED_CAM_STATE='{"id":"cam1","state":"CONNECTED","isMotionDetected":true}'
    else
      _CACHED_CAM_STATE='{"id":"cam1","state":"CONNECTED","isAutoTracking":true}'
    fi
    return 0
  fi
  if [[ "$NADIR_MODE" == current ]] && (( FIELD_NOW < 1002 )); then
    return 0
  fi
  # The pre-empting cue waits behind a second tracking hold until it expires.
  if [[ "$NADIR_MODE" == expire ]] && (( ${cue_pending:--1} >= 0 && FIELD_NOW < 1032 )); then
    _CACHED_CAM_STATE='{"id":"cam1","state":"CONNECTED","isAutoTracking":true}'
    return 0
  fi
  local tracking_end=1005
  [[ "$NADIR_MODE" != current ]] || tracking_end=1007
  if (( FIELD_NOW < tracking_end )); then
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
  if (( ${cue_in_progress:-0} )); then
    printf '__hold source=%s cutoff=%s slot=%s\n' "$status_cue_camera" "$nadir_event_cutoff" "$last_commanded_slot"
  fi
  printf 'sleep%s\n' "$1" >> "$NADIR_COUNTS"
  printf '__sleep=%s now=%s\n' "$1" "$FIELD_NOW"
  FIELD_NOW=$(( FIELD_NOW + $1 )); CUE_NOW=$FIELD_NOW
  (( FIELD_NOW < 1100 )) || exit 99
}

api_post_with_retry() {
  local -a counts=()
  mapfile -t counts < "$NADIR_COUNTS"
  printf '__counts=%s\n' "${counts[*]}" >&2
  printf '__goto=%s now=%s cue=%s source=%s cutoff=%s\n' "${1##*/}" "$FIELD_NOW" "$cue_in_progress" "$status_cue_camera" "$nadir_event_cutoff" >&2
  case "$NADIR_MODE" in
    handoff|priority|wrap|nomatch|newer|older|same-second|current|pickup|flicker|expire)
      FIELD_GOTOS=$(( FIELD_GOTOS + 1 ))
      (( FIELD_GOTOS < NADIR_LIMIT )) || exit 0
      _LAST_HTTP_CODE=200 ;;
    *) exit 0 ;;
  esac
}

nadir_hold_probe() {
  local _LOG_LEVEL=3
  NADIR_MODE=$1
  NADIR_COUNTS="$BATS_TEST_TMPDIR/nadir-counts"
  : > "$NADIR_COUNTS"
  FIELD_NOW=1000 CUE_NOW=1000 NADIR_COUNTING=0 FIELD_GOTOS=0 NADIR_LIMIT=3
  [[ "$NADIR_MODE" != expire ]] || NADIR_LIMIT=4
  FIELD_CONFIG='{"dwell_seconds":6,"ptz_settle_seconds":0,"nadir_handoff":{"tilt_min":15800,"sectors":[]}}'
  [[ "$NADIR_MODE" != disabled ]] || FIELD_CONFIG='{"dwell_seconds":6,"ptz_settle_seconds":0}'
  if [[ "$NADIR_MODE" == cues ]]; then
    FIELD_CONFIG=${FIELD_CONFIG%\}}',"cues":[{"camera_id":"fixed1","slot":4,"zones":["Past pole"]}]}'
  fi
  case "$NADIR_MODE" in
    handoff|priority|wrap|nomatch|newer|older|same-second|current|pickup|flicker|expire)
      FIELD_CONFIG='{"dwell_seconds":6,"ptz_settle_seconds":0,"nadir_handoff":{"tilt_min":15800,"hold_seconds":20,"sectors":[{"pan_min":34000,"pan_max":36000,"slot":4}]}}'
      [[ "$NADIR_MODE" != wrap ]] || FIELD_CONFIG=${FIELD_CONFIG/\"pan_max\":36000/\"pan_max\":1000}
      [[ "$NADIR_MODE" != nomatch ]] || FIELD_CONFIG=${FIELD_CONFIG/\"pan_min\":34000/\"pan_min\":35500}
      [[ "$NADIR_MODE" != current ]] || FIELD_CONFIG=${FIELD_CONFIG/\"slot\":4/\"slot\":0}
      case "$NADIR_MODE" in
        priority|nomatch|newer|older|same-second|expire)
          FIELD_CONFIG=${FIELD_CONFIG%\}}',"cues":[{"camera_id":"fixed1","slot":2,"zones":["Past pole"],"hold_seconds":5}]}' ;;
      esac ;;
  esac
  CUE_BODY=$(reacquire_fixture)
  NADIR_NEXT=$(reacquire_fixture 1006000)
  [[ "$NADIR_MODE" != same-second ]] || NADIR_NEXT=$(reacquire_fixture 1005999)
  _STATUS_WEBHOOK_URL='https://example.invalid/webhook'
  patrol_camera cam1 Overwatch "$FIELD_DISCOVERY"
}

nadir_parse_probe() {
  local cam_config=$1 cam_id=cam1 cam_name=Overwatch
  local preset_positions='[{"slot":7}]' cam_discovery_json='{"presets":[{"slot":0},{"slot":4}]}'
  local nadir_enabled=0 nadir_tilt_min=0 nadir_hold=20 nadir_cue_index=-1
  local -a nadir_pan_mins=() nadir_pan_maxs=() nadir_slots=()
  local -a cue_camera_ids=() cue_slots=() cue_types=() cue_holds=() cue_cooldowns=() cue_names=() cue_zones=() cue_until=()
  local -A cue_zone_labels=()
  local cue_query=""
  _patrol_parse_cues
  printf '__enabled=%s tilt=%s hold=%s sectors=%s warnings=%s query=%s\n' "$nadir_enabled" "$nadir_tilt_min" "$nadir_hold" "${#nadir_slots[@]}" "$CUE_WARNINGS" "$cue_query"
}

nadir_decision_probe() {
  local _LOG_LEVEL=3 cam_name=Overwatch
  local nadir_decided=0 nadir_sample_at=$1 nadir_pan=100 nadir_tilt=16000 nadir_zoom=0 nadir_tilt_min=15800
  local -a nadir_ring=("995:100/16000/0") nadir_slots=() nadir_pan_mins=() nadir_pan_maxs=() cue_slots=()
  local nadir_cue_index=0 cue_pending=-1 cue_matched_at=0 cue_no_goto=1 nadir_event_cutoff=0
  if [[ -n "${2:-}" ]]; then
    nadir_pan=$2
    nadir_slots=(4 2); nadir_pan_mins=(34000 34000); nadir_pan_maxs=(36000 36000)
    [[ "${3:-}" != wrap ]] || nadir_pan_maxs=(1000 1000)
  fi
  CUE_NOW=1000
  _patrol_nadir_decide || true
  printf '__decided=%s\n' "$nadir_decided"
  printf '__pending=%s slot=%s no_goto=%s cutoff=%s\n' "$cue_pending" "${cue_slots[0]:--1}" "$cue_no_goto" "$nadir_event_cutoff"
}

nadir_ring_probe() {
  local _LOG_LEVEL=3 cam_id=cam1 cam_name=Overwatch
  local nadir_sampling=0 nadir_decided=0 nadir_sample_at=0 nadir_pan=0 nadir_tilt=0 nadir_zoom=0 nadir_tilt_min=15800
  local nadir_home_pan="" nadir_home_tilt="" nadir_home_zoom=""
  local -a nadir_ring=() nadir_slots=()
  NADIR_COUNTS="$BATS_TEST_TMPDIR/ring"
  : > "$NADIR_COUNTS"
  _patrol_nadir_wait
  _patrol_nadir_wait
  _patrol_nadir_decide || true
  printf '__ring=%s\n' "${#nadir_ring[@]}"
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
