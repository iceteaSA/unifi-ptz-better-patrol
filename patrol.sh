#!/bin/bash
# Sourced by ptz-patrol.sh — provides the per-camera patrol loop.

SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
source "$SCRIPT_DIR/api.sh"
source "$SCRIPT_DIR/discover.sh"

# ---------------------------------------------------------------------------
# Manual control detection
# ---------------------------------------------------------------------------

# Detect if someone else is controlling the camera (not us).
#
# Strategy: after a successful goto, require two consecutive live positions at
# the commanded target before drift can mean external control.  A position
# away from an unacquired target is unresolved command execution, not drift.
#
# Arguments:
#   $1  cam_id
#   $2  cam_name
#   $3  settle_seconds
#   $4  last_goto_ts
#   $5  expected_pan   (steps, -1 = unknown)
#   $6  expected_tilt  (steps, -1 = unknown)
#   $7  expected_zoom  (steps, -1 = unknown)
#   $8  acquisition_state  (acquiring|acquired|none)
#   $9  acquisition_streak (consecutive samples at target)
#
# Returns 0 (true) if external control is detected.
is_externally_controlled() {
  local cam_id=$1
  local cam_name=$2
  local settle_seconds=$3
  local last_goto_ts=$4
  local expected_pan=$5
  local expected_tilt=$6
  local expected_zoom=$7
  local acquisition_state=${8:-none}
  local acquisition_streak=${9:-0}
  _LAST_DRIFT_MAGNITUDE=0
  _LAST_GOTO_FAILED=0
  _LAST_AT_HOMEVIEW=0
  _LAST_HOME_PAN=-1; _LAST_HOME_TILT=-1; _LAST_HOME_ZOOM=-1
  _LAST_ACQUISITION_STATE=$acquisition_state
  _LAST_ACQUISITION_STREAK=$acquisition_streak

  local now; now=$(date +%s)

  # Still in settle window after our last goto — not external
  if (( now - last_goto_ts < settle_seconds )); then
    return 1
  fi

  # Skip if we have no expected position to compare against
  if (( expected_pan < 0 && expected_tilt < 0 && expected_zoom < 0 )); then
    return 1
  fi

  # Fetch live PTZ position (separate lightweight endpoint, not full camera state)
  local live_pan live_tilt live_zoom
  IFS=$'\t' read -r live_pan live_tilt live_zoom <<< "$(api_get_ptz_position "$cam_id")"

  if [[ ! "$live_pan" =~ ^[0-9]+$ || ! "$live_tilt" =~ ^[0-9]+$ || ! "$live_zoom" =~ ^[0-9]+$ ]]; then
    # Failed to read — fail-safe, don't flag as external
    return 1
  fi

  # Compare each axis.  Thresholds in motor steps:
  #   pan:  200 steps (~1-2 degrees, depends on model)
  #   tilt: 200 steps
  #   zoom: 30  steps (~3% of 0-1000 range)
  local pan_thresh=200 tilt_thresh=200 zoom_thresh=30
  local pan_diff=0 tilt_diff=0 zoom_diff=0
  local drift_magnitude=0
  local drifted=""
  local target_axes=0
  local at_target=1

  if (( expected_pan >= 0 )); then
    target_axes=$(( target_axes + 1 ))
    pan_diff=$(( live_pan - expected_pan ))
    pan_diff=${pan_diff#-}
    (( pan_diff > drift_magnitude )) && drift_magnitude=$pan_diff
    (( pan_diff > pan_thresh )) && drifted+="pan(${expected_pan}→${live_pan}) "
    (( pan_diff > pan_thresh )) && at_target=0
  fi
  if (( expected_tilt >= 0 )); then
    target_axes=$(( target_axes + 1 ))
    tilt_diff=$(( live_tilt - expected_tilt ))
    tilt_diff=${tilt_diff#-}
    (( tilt_diff > drift_magnitude )) && drift_magnitude=$tilt_diff
    (( tilt_diff > tilt_thresh )) && drifted+="tilt(${expected_tilt}→${live_tilt}) "
    (( tilt_diff > tilt_thresh )) && at_target=0
  fi
  if (( expected_zoom >= 0 )); then
    target_axes=$(( target_axes + 1 ))
    zoom_diff=$(( live_zoom - expected_zoom ))
    zoom_diff=${zoom_diff#-}
    (( zoom_diff > drift_magnitude )) && drift_magnitude=$zoom_diff
    (( zoom_diff > zoom_thresh )) && drifted+="zoom(${expected_zoom}→${live_zoom}) "
    (( zoom_diff > zoom_thresh )) && at_target=0
  fi

  _LAST_DRIFT_MAGNITUDE=$drift_magnitude

  log "$cam_name" "debug" "PTZ check: pan=${live_pan}/${expected_pan} tilt=${live_tilt}/${expected_tilt} zoom=${live_zoom}/${expected_zoom}"

  if [[ "$acquisition_state" == "acquiring" ]]; then
    if (( target_axes > 0 && at_target == 1 )); then
      acquisition_streak=$(( acquisition_streak + 1 ))
      if (( acquisition_streak >= 2 )); then
        acquisition_state="acquired"
        log "$cam_name" "debug" "Goto target acquired after ${acquisition_streak} consecutive position reads"
      fi
    else
      acquisition_streak=0
      _LAST_GOTO_FAILED=1
      log "$cam_name" "warn" "Goto target not acquired — live pan=$live_pan tilt=$live_tilt zoom=$live_zoom, target pan=$expected_pan tilt=$expected_tilt zoom=$expected_zoom"
    fi
    _LAST_ACQUISITION_STATE=$acquisition_state
    _LAST_ACQUISITION_STREAK=$acquisition_streak
    return 1
  fi

  if [[ -n "$drifted" ]]; then
    log "$cam_name" "info" "PTZ drift detected: ${drifted}"
    local home_fields="" home_pan home_tilt home_zoom
    if home_fields=$(api_get_ptz_home "$cam_id"); then
      IFS=$'\t' read -r home_pan home_tilt home_zoom <<< "$home_fields"
      if [[ "$home_pan" =~ ^[0-9]+$ && "$home_tilt" =~ ^[0-9]+$ && "$home_zoom" =~ ^[0-9]+$ ]]; then
        _LAST_HOME_PAN=$home_pan; _LAST_HOME_TILT=$home_tilt; _LAST_HOME_ZOOM=$home_zoom
        pan_diff=$(( live_pan - home_pan )); pan_diff=${pan_diff#-}
        tilt_diff=$(( live_tilt - home_tilt )); tilt_diff=${tilt_diff#-}
        zoom_diff=$(( live_zoom - home_zoom )); zoom_diff=${zoom_diff#-}
        if (( pan_diff <= pan_thresh && tilt_diff <= tilt_thresh && zoom_diff <= zoom_thresh )); then
          log "$cam_name" "info" "Camera returned to its HomeView — not manual control"
          _LAST_AT_HOMEVIEW=1
          return 1
        fi
      fi
    fi
    return 0
  fi

  return 1
}

# Wait for the camera to finish a prior movement before the first patrol goto.
# A bounded startup wait prevents a restart's home command from being mistaken
# for manual control, while the expiry path keeps an unresponsive camera moving.
_patrol_wait_for_camera_settle() {
  local cam_id=$1
  local cam_name=$2
  local max_wait_s=${3:-30}
  local start_ts
  start_ts=$(date +%s)
  local now elapsed
  local previous_pan=-1 previous_tilt=-1 previous_zoom=-1
  local previous_valid=0
  local reason="no successful position reads"
  local pan_thresh=200 tilt_thresh=200 zoom_thresh=30

  while true; do
    local live_pan live_tilt live_zoom
    local had_previous=$previous_valid
    IFS=$'\t' read -r live_pan live_tilt live_zoom <<< "$(api_get_ptz_position "$cam_id")"

    if [[ "$live_pan" == "-1" && "$live_tilt" == "-1" && "$live_zoom" == "-1" ]]; then
      previous_valid=0
      reason="position read failed"
    elif [[ ! "$live_pan" =~ ^[0-9]+$ || ! "$live_tilt" =~ ^[0-9]+$ || ! "$live_zoom" =~ ^[0-9]+$ ]]; then
      previous_valid=0
      reason="malformed position response"
    else
      if (( previous_valid == 1 )); then
        local pan_diff=$(( live_pan - previous_pan ))
        local tilt_diff=$(( live_tilt - previous_tilt ))
        local zoom_diff=$(( live_zoom - previous_zoom ))
        pan_diff=${pan_diff#-}
        tilt_diff=${tilt_diff#-}
        zoom_diff=${zoom_diff#-}
        if (( pan_diff <= pan_thresh && tilt_diff <= tilt_thresh && zoom_diff <= zoom_thresh )); then
          now=$(date +%s)
          elapsed=$(( now - start_ts ))
          log "$cam_name" "info" "Camera settled before patrol start after ${elapsed}s"
          return 0
        fi
        reason="position remained in motion"
      fi
      previous_pan=$live_pan
      previous_tilt=$live_tilt
      previous_zoom=$live_zoom
      previous_valid=1
    fi

    now=$(date +%s)
    elapsed=$(( now - start_ts ))
    if (( elapsed >= max_wait_s )); then
      log "$cam_name" "warn" "Camera did not settle within ${max_wait_s}s (${reason}) — starting patrol anyway"
      return 1
    fi

    # The second read is immediate so an already-stationary camera adds no
    # meaningful delay; later movement checks are spaced to bound API load.
    if (( had_previous == 1 || previous_valid == 0 )); then
      sleep 1
    fi
  done
}

# Some firmware omits tracking flags for the PTZ's own smart events.
# Wait here so neither failed-goto caller can advance during that activity.
# Episode state uses caller scope and survives retries until an empty poll.
# Returns 1 after a hold: the position is stale, so the caller checks it again
# before any retry.
_patrol_hold_own_smart_event() {
  local poll_iv=${1:-5} now types poll_error held=0
  while true; do
    printf -v now '%(%s)T' -1
    types=""; poll_error=0
    api_get "/events?start=$(( (now - 120) * 1000 ))&end=$(( now * 1000 ))&types=smartDetectZone&cameras=$cam_id"
    if [[ "$_LAST_HTTP_CODE" != 200 ]]; then
      poll_error=1
    elif [[ "$_LAST_BODY" != '[]' ]]; then
      types=$(jq -rs --arg self "$cam_id" --argjson now "$(( now * 1000 ))" '
        if length != 1 then error("invalid events") else .[0] end
        | if type != "array" then error("invalid events") else . end
        | map(select(type == "object" and .camera == $self and has("end"))
          | select(.end == null or ((.end | type) == "number" and .end >= $now - 10000 and .end <= $now)))
        | if length == 0 then empty else
            [.[].smartDetectTypes[]? | select(type == "string" and length > 0)] | unique
            | if length == 0 then "unknown" else join(",") end
          end
      ' <<< "$_LAST_BODY" 2>/dev/null) || poll_error=1
    fi
    if (( poll_error )); then
      if (( own_event_poll_failed == 0 )); then
        log "$cam_name" "warn" "Own smart event check failed (HTTP $_LAST_HTTP_CODE, curl rc $_LAST_CURL_RC) — keeping goto retry behaviour"
      fi
      own_event_poll_failed=1
      return "$held"
    fi
    own_event_poll_failed=0
    if [[ -z "$types" ]]; then
      own_event_since=0
      own_event_capped=0
      return "$held"
    fi
    printf -v now '%(%s)T' -1
    if (( own_event_since == 0 )); then
      own_event_since=$now
      log "$cam_name" "info" "Goto target not acquired — own smart event ($types) open; holding instead of re-issuing"
    fi
    if (( max_smart_wait > 0 && now - own_event_since >= max_smart_wait )); then
      if (( own_event_capped == 0 )); then
        log "$cam_name" "warn" "Max smart wait (${max_smart_wait}s) hit on own smart event — resuming goto retries"
      fi
      own_event_capped=1
      return "$held"
    fi
    held=1
    _patrol_status_tick holding_activity "$now"
    sleep "$poll_iv"
    api_ensure_auth
  done
}

# Re-issue a goto whose target has not been acquired. The retry count is
# caller-scoped so the patrol can advance after the bounded limit instead of
# entering a hold loop.
_patrol_reissue_failed_goto() {
  local cam_id=$1
  local cam_name=$2
  local slot=$3
  local retry_limit=$4

  if (( goto_retry_count >= retry_limit )); then
    log "$cam_name" "warn" "Goto slot $slot still has not taken effect after ${retry_limit} retries — advancing patrol"
    expected_pan=-1; expected_tilt=-1; expected_zoom=-1
    last_commanded_slot=-1
    status_slot=""
    acquisition_state="none"
    acquisition_streak=0
    goto_retry_count=0
    return 1
  fi

  goto_retry_count=$(( goto_retry_count + 1 ))
  local code
  api_post_with_retry "/cameras/$cam_id/ptz/goto/$slot" 2 3 >/dev/null || true
  code="$_LAST_HTTP_CODE"
  case "$code" in
    200|204)
      last_goto_ts=$(date +%s)
      acquisition_state="acquiring"
      acquisition_streak=0
      log "$cam_name" "warn" "Re-issued goto for slot $slot after failed execution (attempt ${goto_retry_count}/${retry_limit}, HTTP $code)"
      ;;
    *)
      log "$cam_name" "warn" "Retry ${goto_retry_count}/${retry_limit} for slot $slot was not accepted (HTTP ${code:-timeout})"
      ;;
  esac
  return 0
}

# ---------------------------------------------------------------------------
# Schedule
# ---------------------------------------------------------------------------

# Parse the optional minute constraint.
# Arguments: camera_config camera_name schedule_set
#   camera_config: Effective camera configuration as JSON.
#   camera_name: Camera name for log messages.
#   schedule_set: 1 when both schedule start and end are set; otherwise 0.
# Sets _PATROL_CONSTRAIN_START, _PATROL_CONSTRAIN_END, and _PATROL_CONSTRAIN_ACTIVE.
# Returns 0 after parsing, including when the constraint is disabled.
_patrol_parse_constrain() {
  local cam_config=$1 cam_name=$2 fields start_token end_token
  local supplied_start supplied_end start_field end_field
  local jq_status=0 schedule_set=${3:-1}
  _PATROL_CONSTRAIN_START=""
  _PATROL_CONSTRAIN_END=""
  _PATROL_CONSTRAIN_ACTIVE=0
  fields=$(printf '%s' "$cam_config" | jq -r '
    def field($name):
      if ((.schedule // {}) | has($name)) then
        (.schedule // {})[$name] as $value
        | if (($value | type) == "number" or ($value | type) == "string")
             and ($value | try tonumber catch null) != null
             and (($value | tonumber) >= 0 and ($value | tonumber) <= 59)
             and (($value | tonumber) == (($value | tonumber) | floor))
          then "V:" + (($value | tonumber | floor) | tostring) + ":" + ($value | tojson)
          else "I:" + ($value | tojson)
          end
      else "A"
      end;
    [field("constrain_start_minute"), field("constrain_end_minute")] | @tsv
  ' 2>/dev/null) || jq_status=$?
  if (( jq_status != 0 )) || [[ -z "$fields" ]]; then
    log "$cam_name" "warn" "Could not read the constrained patrol window from the camera config — constraint disabled"
    return 0
  fi
  IFS=$'\t' read -r start_token end_token <<< "$fields"

  if [[ "$start_token" == "A" && "$end_token" == "A" ]]; then
    return 0
  fi
  if [[ "$schedule_set" != "1" ]]; then
    log "$cam_name" "warn" "Constrained patrol minutes require schedule.start and schedule.end — constraint disabled"
    return 0
  fi

  if [[ "$start_token" == "A" ]]; then
    supplied_start="absent"
  elif [[ "${start_token:0:2}" == "V:" ]]; then
    supplied_start=${start_token#*:*:}
  else
    supplied_start=${start_token#*:}
  fi
  if [[ "$end_token" == "A" ]]; then
    supplied_end="absent"
  elif [[ "${end_token:0:2}" == "V:" ]]; then
    supplied_end=${end_token#*:*:}
  else
    supplied_end=${end_token#*:}
  fi
  start_field=${start_token:0:2}
  end_field=${end_token:0:2}
  if [[ "$start_field" == "V:" && "$end_field" == "V:" ]]; then
    local start_value=${start_token#V:} end_value=${end_token#V:}
    _PATROL_CONSTRAIN_START=${start_value%%:*}
    _PATROL_CONSTRAIN_END=${end_value%%:*}
    if [[ "$_PATROL_CONSTRAIN_START" == "$_PATROL_CONSTRAIN_END" ]]; then
      log "$cam_name" "warn" "Invalid constrained patrol window: start and end values are equal (${supplied_start}, ${supplied_end}) — constraint disabled"
      _PATROL_CONSTRAIN_START=""
      _PATROL_CONSTRAIN_END=""
      return 0
    fi
    _PATROL_CONSTRAIN_ACTIVE=1
    log "$cam_name" "info" "Active constrained patrol period window: ${_PATROL_CONSTRAIN_START} through ${_PATROL_CONSTRAIN_END} minutes past the hour."
    return 0
  fi

  if [[ "$start_field" != "V:" && "$end_field" != "V:" ]]; then
    log "$cam_name" "warn" "Invalid constrained patrol window (${supplied_start}, ${supplied_end}) — both values must be integers from 0 to 59 — constraint disabled"
  elif [[ "$start_field" != "V:" ]]; then
    log "$cam_name" "warn" "Invalid constrained patrol start value (${supplied_start}) — expected an integer from 0 to 59 — constraint disabled"
  else
    log "$cam_name" "warn" "Invalid constrained patrol end value (${supplied_end}) — expected an integer from 0 to 59 — constraint disabled"
  fi
}

# Check if the current time falls within a patrol schedule window.
# Arguments: schedule_start schedule_end schedule_days_json schedule_constrain_start_minute schedule_constrain_end_minute
#   schedule_start/end: "HH:MM" strings (24h). Empty = no schedule (always active).
#   schedule_days_json: JSON array of 3-letter day names, e.g. '["mon","tue","wed"]'
#                       Empty or "null" = all days.
#   schedule_constrain_start_minute: Start minute (0-59) for the active patrol sub-window. Empty = no sub-window.
#   schedule_constrain_end_minute: End minute (0-59) for the active patrol sub-window. Empty = no sub-window.
# Returns 0 if patrol should be active, 1 if outside the schedule window.
#
# Day-of-week handling for overnight windows:
#   For "22:00-06:00" on ["mon","tue","wed","thu","fri"]:
#   - Friday 23:00 → check Friday (today) → in list → active
#   - Saturday 01:00 → in early-morning tail, check Friday (yesterday) → in list → active
#   - Saturday 23:00 → check Saturday (today) → not in list → inactive
is_within_schedule() {
  local sched_start=$1 sched_end=$2 sched_days=$3 sched_constrain_start_minute=${4:-} sched_constrain_end_minute=${5:-}

  # No schedule configured — always active
  if [[ -z "$sched_start" || -z "$sched_end" ]]; then
    return 0
  fi

  # LC_ALL=C forces English day names regardless of system locale
  local now_hhmm; now_hhmm=$(date +%H:%M)
  local is_overnight=0
  [[ "$sched_start" > "$sched_end" ]] && is_overnight=1

  # Determine which time portion we're in and check accordingly
  local in_window=0
  if (( is_overnight )); then
    # Overnight window: e.g. 22:00-06:00
    if [[ ! "$now_hhmm" < "$sched_start" || "$now_hhmm" < "$sched_end" ]]; then
      in_window=1
    fi
  else
    # Same-day window: e.g. 08:00-18:00
    if [[ ! "$now_hhmm" < "$sched_start" && "$now_hhmm" < "$sched_end" ]]; then
      in_window=1
    fi
  fi

  if (( ! in_window )); then
    return 1
  fi

  # Base-10 parsing keeps minutes 08 and 09 out of octal notation.
  local now_minute; now_minute="$((10#${now_hhmm##*:}))"
  local in_constrain_window=0

  if [[ -n "$sched_constrain_start_minute" && -n "$sched_constrain_end_minute" && "$sched_constrain_start_minute" -ne "$sched_constrain_end_minute" ]]; then
    if (( sched_constrain_start_minute < sched_constrain_end_minute )); then
      if (( now_minute >= sched_constrain_start_minute && now_minute < sched_constrain_end_minute )); then
        in_constrain_window=1
      fi
    else
      # sched_constrain_start_minute > sched_constrain_end_minute indicates a cross-hour sub-window (e.g., 45-15)
      if (( now_minute >= sched_constrain_start_minute || now_minute < sched_constrain_end_minute )); then
        in_constrain_window=1
      fi
    fi
  else
    # No valid sub-window configured, so the entire schedule window is active
    in_constrain_window=1
  fi

  if (( ! in_constrain_window )); then
    return 1
  fi

  # Check day-of-week if days are specified
  if [[ -n "$sched_days" && "$sched_days" != "null" ]]; then
    local check_day
    if (( is_overnight )) && [[ "$now_hhmm" < "$sched_end" ]]; then
      # Early-morning tail of an overnight window — check yesterday's day
      # because the window started the previous calendar day
      check_day=$(LC_ALL=C date -d "yesterday" +%a 2>/dev/null \
               || LC_ALL=C date -v-1d +%a 2>/dev/null)
    else
      check_day=$(LC_ALL=C date +%a)
    fi
    check_day=$(echo "$check_day" | tr '[:upper:]' '[:lower:]')

    local match; match=$(echo "$sched_days" | jq -r --arg d "$check_day" '[.[] | ascii_downcase] | index($d)')
    if [[ "$match" == "null" ]]; then
      return 1
    fi
  fi

  return 0
}

# ---------------------------------------------------------------------------
# Dynamic auto-tracking
# ---------------------------------------------------------------------------

# Enable or disable auto-tracking on a camera via API PATCH.
# Arguments: cam_id cam_name types_json action_label [zoom]
#   types_json: validated object types to enable, '[]' to disable
#   action_label: "enabled" or "disabled" (for logging)
#   zoom: "true", "false" or "null" — sent only when enabling
set_auto_tracking() {
  local cam_id=$1 cam_name=$2 types_json=$3 action_label=$4
  local zoom=${5:-null} zoom_field=""
  if [[ "$types_json" != "[]" && ( "$zoom" == "true" || "$zoom" == "false" ) ]]; then
    zoom_field=",\"autoTrackingWithZoom\":$zoom"
  fi
  api_ensure_auth
  local code
  code=$(api_patch "/cameras/$cam_id" \
    "{\"smartDetectSettings\":{\"autoTrackingObjectTypes\":$types_json$zoom_field}}") || true
  if [[ "$code" == "200" ]]; then
    log "$cam_name" "info" "Auto-tracking $action_label ($types_json)"
    return 0
  else
    log "$cam_name" "warn" "Failed to set auto-tracking (HTTP ${code:-timeout})"
    return 1
  fi
}

# These values use caller scope to prevent poll-time parsing.
# Reads/writes these caller-scope variables directly (not local to this
# function, shared through Bash dynamic scoping):
#   tracking_types_json tracking_types_label tracking_with_zoom
_patrol_parse_tracking_config() {
  local cam_config=$1 cam_discovery_json=$2 cam_name=$3
  local requested vehicle_capable type separator=""
  local -A seen_types=()
  requested=$(jq -c 'if .auto_tracking_object_types == null then ["person"] else .auto_tracking_object_types end' <<< "$cam_config")
  vehicle_capable=$(jq -r '.feature_vehicle_tracking == true' <<< "${cam_discovery_json:-\{\}}")
  tracking_types_json="["
  tracking_types_label=""
  if jq -e 'type == "array"' <<< "$requested" >/dev/null; then
    while IFS= read -r type; do
      case "$type" in
        '"person"') ;;
        '"vehicle"')
          if [[ "$vehicle_capable" != "true" ]]; then
            log "$cam_name" "warn" "Unsupported auto-tracking type $type — ignoring"
            continue
          fi
          ;;
        *)
          log "$cam_name" "warn" "Unknown auto-tracking type $type — ignoring"
          continue
          ;;
      esac
      [[ -z "${seen_types[$type]+x}" ]] || continue
      seen_types["$type"]=1
      tracking_types_json+="$separator$type"
      type=${type#\"}; type=${type%\"}
      tracking_types_label+="$separator$type"
      separator=","
    done < <(jq -c '.[]' <<< "$requested")
  fi
  tracking_types_json+="]"
  if [[ "$tracking_types_json" == "[]" ]]; then
    log "$cam_name" "warn" 'Invalid or empty auto_tracking_object_types — using ["person"]'
    tracking_types_json='["person"]'
    tracking_types_label="person"
  fi
  tracking_with_zoom=$(jq -r 'if .auto_tracking_with_zoom == null then null else .auto_tracking_with_zoom end' <<< "$cam_config")
  case "$tracking_with_zoom" in
    true|false|null) ;;
    *)
      log "$cam_name" "warn" "Invalid auto_tracking_with_zoom — keeping camera setting"
      tracking_with_zoom=null
      ;;
  esac
}

# Cue arrays and the query use caller scope. Parse one time, not at each poll.
# Writes cue_camera_ids, cue_slots, cue_types, cue_holds, cue_cooldowns,
# cue_names, cue_zones, cue_zone_labels, cue_until and cue_query. Reads cam_config and the preset lists.
_patrol_parse_cues() {
  local src slot hold cooldown types name zone zone_id zone_name zone_label zones invalid_zone info=""
  local discovery=${cam_discovery_json:-}
  [[ -n "$discovery" ]] || discovery='{}'
  local -A names=() zone_names=() zone_ids=() zone_labels=() source_ok=()
  local -a requested_zones=()
  while IFS=$'\t' read -r src slot hold cooldown types; do
    if [[ "$src" == zone ]]; then
      requested_zones+=("$slot")
      continue
    fi
    if [[ "$src" == invalid ]]; then
      log "$cam_name" "warn" "Invalid cues entry $slot — ignoring"
      continue
    fi
    src=${src#camera:}
    if [[ -z "${names[$src]+x}" ]]; then
      name=""
      source_ok["$src"]=0
      api_get "/cameras/$src"
      if [[ "$_LAST_HTTP_CODE" == 200 ]]; then
        # NUL separates records because camera names can contain tabs or newlines.
        {
          if IFS= read -r -d '' name; then source_ok["$src"]=1; fi
          while IFS= read -r -d '' zone_id && IFS= read -r -d '' zone_name && IFS= read -r -d '' zone_label; do
            [[ "$zone_name" == '""' ]] || zone_names["$src:$zone_name"]=$zone_id
            zone_ids["$src:$zone_id"]=$zone_id
            zone_labels["$src:$zone_id"]=$zone_label
          done
        } < <(jq -j '
          (if (.name | type) == "string" then .name else "" end) + "\u0000",
          (.smartDetectZones[]? | select(.id != null)
            | (if (.name | type) == "string" then .name else "" end) as $name
            | (.id | tostring) + "\u0000" + ($name | tojson) + "\u0000" + $name + "\u0000")
        ' <<< "$_LAST_BODY" 2>/dev/null)
      fi
      if [[ -z "$name" ]]; then
        name=$src
        log "$cam_name" "warn" "Cannot resolve cue camera $src — using id"
      fi
      names["$src"]=$name
      cue_query+="&cameras=$src"
    fi
    zones=""; invalid_zone=0
    for zone in "${requested_zones[@]}"; do
      zone_id=${zone_names["$src:$zone"]:-}
      if [[ -z "$zone_id" ]]; then
        zone_name=${zone#\"}; zone_name=${zone_name%\"}
        if [[ "$zone_name" =~ ^[0-9]+$ ]]; then
          zone_id=${zone_ids["$src:$zone_name"]:-}
          if [[ "${source_ok[$src]}" == 0 ]]; then zone_id=$zone_name; fi
        fi
      fi
      if [[ -z "$zone_id" ]]; then
        [[ "$zone" == \"* ]] || zone="\"$zone\""
        log "$cam_name" "warn" "Cue zone $zone not found on ${names[$src]} — ignoring this cue entry"
        invalid_zone=1
        break
      fi
      [[ -n "$zones" ]] || zones=$'\t'
      zones+="$zone_id"$'\t'
      cue_zone_labels["${#cue_slots[@]}:$zone_id"]=${zone_labels["$src:$zone_id"]:-$zone_id}
    done
    requested_zones=()
    (( invalid_zone == 0 )) || continue
    cue_camera_ids+=("$src")
    cue_slots+=("$slot")
    cue_holds+=("$hold")
    cue_cooldowns+=("$cooldown")
    cue_types+=($'\t'"$types"$'\t')
    cue_names+=("${names[$src]}")
    cue_zones+=("$zones")
    cue_until+=(0)
    info+="${info:+, }${names[$src]}→$slot"
  done < <(jq -r --arg self "$cam_id" \
    --slurpfile positions <(printf '%s' "${preset_positions:-[]}") --slurpfile discovery <(printf '%s' "$discovery") '
    def integer: type == "number" and floor == .;
    ([$positions[0][].slot | tostring] + [$discovery[0].presets[]?.slot | tostring]) as $slots
    | if .cues == null then [] else .cues end
    | if type != "array" then "invalid\t<array>" else
      to_entries[] | .key as $index | .value
      | if type != "object" then "invalid\t\($index)" else
        (if .types == null then ["person"] else .types end) as $types
        | (if .hold_seconds == null then 30 else .hold_seconds end) as $hold
        | (if .cooldown_seconds == null then 120 else .cooldown_seconds end) as $cooldown
        | . as $cue
        | if ((.camera_id | type) == "string" and (.camera_id | test("^[A-Za-z0-9]{1,64}$")) and .camera_id != $self
            and (.slot | integer) and ($slots | index($cue.slot | tostring)) != null)
          and ($types | type == "array" and length > 0 and all(.[]; type == "string" and length > 0))
          and ($hold | integer and . >= 5) and ($cooldown | integer and . >= 0)
          and (if has("zones") then (.zones | type == "array" and length > 0
            and all(.[]; type == "string" or (integer and . >= 0))) else true end)
          then (.zones[]? | ["zone", tojson] | join("\t")),
            (([("camera:" + .camera_id), (.slot | tostring), ($hold | tostring), ($cooldown | tostring)]
            + ($types | reduce .[] as $t ([]; if index($t) == null then . + [$t] else . end) | map(tojson))) | join("\t"))
          else "invalid\t\($index)" end
      end
    end
  ' <<< "$cam_config")
  [[ -z "$info" ]] || log "$cam_name" "info" "Cues: $info"
  return 0
}

# Cue completion and pending-cue expiry must clear the same caller-scope state.
_patrol_end_cue_hold() {
  cue_in_progress=0
  status_idle_state=patrolling
  status_cue_camera=""
  log "$cam_name" "info" "Cue hold ended"
  if [[ "${presets[$idx]}" == "$cue_slot" ]]; then
    log "$cam_name" "debug" "Skipping slot $cue_slot — the cue just held it"
    idx=$(( (idx + 1) % ${#presets[@]} ))
    step_repeated=0
  fi
}

# The two priority passes can reject a pair before the other pass accepts it.
# Emit only the final reason, not an intermediate priority rejection.
_patrol_log_cue_skips() {
  (( _LOG_LEVEL >= 3 )) || return 0
  local key i j
  for key in "${!cue_skip_reasons[@]}"; do
    i=${key%%:*}; j=${key#*:}
    log "$cam_name" "debug" "Cue skip entry=$i (${cue_names[$i]}) reason=${cue_skip_reasons[$key]} ${event_debug[$j]}"
  done
}

# Reads the caller's cue arrays and last_commanded_slot. Writes cue_seen,
# cue_pending, cue_match, cue_matched_at, cue_until and cue_poll_failed.
# A poll error must not hold patrol.
_patrol_poll_cues() {
  local reacquire=${1:-0}
  local now cutoff recent_cutoff id src start zones now_zones types rows i j etype zone_id zone_match priority matched_zone key snapshot
  local debug=$(( _LOG_LEVEL >= 3 ))
  local poll_error=0
  local -a event_cameras=() event_types=() event_ids=() event_starts=() event_zones=() event_now_zones=() tokens=() zone_tokens=() event_debug=()
  local -A cue_skip_reasons=()
  cue_no_goto=0
  (( reacquire )) || cue_pending=-1
  [[ -n "${cue_query:-}" ]] || return 1
  printf -v now '%(%s)T' -1
  cutoff=$(( (now - 120) * 1000 ))
  for id in "${!cue_seen[@]}"; do
    start=${cue_seen[$id]}
    if (( start < cutoff )); then unset 'cue_seen[$id]'; fi
  done
  api_get "/events?start=$cutoff&end=$(( now * 1000 ))&types=smartDetectZone$cue_query"
  if [[ "$_LAST_HTTP_CODE" != 200 ]]; then
    poll_error=1
  elif [[ "$_LAST_BODY" != '[]' ]]; then
    rows=$(jq -rs --argjson debug "$debug" '
      if length != 1 then error("invalid events") else .[0] end
      | if type != "array" then error("invalid events") else .[] end
      | select(type == "object")
      | select((.id | type) == "string" and (.id | length) > 0
        and (.camera | type) == "string" and (.start | type) == "number"
        and (.start | floor) == .start and (.smartDetectTypes | type) == "array")
      | (.metadata.zonesStatus | if type == "object" then to_entries else [] end) as $zones
      | [(.id | tojson), (.camera | tojson), (.start | tostring),
          (if $debug == 1 then "event=\(.id[0:8]) types=\(.smartDetectTypes | tojson) zonesStatus=\($zones | map(.key + ":" + (.value.status | tostring)) | join(",") | tojson)" else "-" end),
          ($zones | map(select((.value | type) == "object" and .value.status != "none") | .key) | tojson),
          ($zones | map(select((.value | type) == "object"
            and (.value.status == "enter" or .value.status == "moving")) | .key) | tojson)]
        + [.smartDetectTypes[] | select(type == "string" and length > 0) | tojson]
      | join("\t")
    ' <<< "$_LAST_BODY" 2>/dev/null) || poll_error=1
  fi
  if (( poll_error )); then
    if (( cue_poll_failed == 0 )); then
      log "$cam_name" "warn" "Cue poll failed (HTTP $_LAST_HTTP_CODE, curl rc $_LAST_CURL_RC) — cues paused until the events request succeeds"
    fi
    cue_poll_failed=1
    return 1
  fi
  if (( cue_poll_failed )); then
    log "$cam_name" "info" "Cue poll recovered"
    cue_poll_failed=0
  fi
  [[ "$_LAST_BODY" != '[]' ]] || return 1
  printf -v now '%(%s)T' -1
  recent_cutoff=$(( (now - 15) * 1000 ))
  cutoff=$(( (now - 120) * 1000 ))
  while IFS=$'\t' read -r id src start snapshot zones now_zones types; do
    [[ -n "$id" && -n "$types" ]] || continue
    [[ "$start" =~ ^[0-9]+$ ]] || continue
    event_cameras+=("$src")
    event_types+=("$types")
    event_ids+=("$id")
    event_starts+=("$start")
    event_zones+=("$zones")
    event_now_zones+=("$now_zones")
    event_debug+=("$snapshot")
  done <<< "$rows"
  # Current zone presence has priority over a recent event with another status.
  for (( priority=1; priority>=0; priority-- )); do
  for (( i=0; i<${#cue_slots[@]}; i++ )); do
    for (( j=0; j<${#event_cameras[@]}; j++ )); do
      if (( now < cue_until[i] )); then
        (( debug == 0 )) || cue_skip_reasons["$i:$j"]=cooldown
        continue
      fi
      if [[ "${event_cameras[$j]}" != "\"${cue_camera_ids[$i]}\"" ]]; then
        (( debug == 0 )) || cue_skip_reasons["$i:$j"]=camera
        continue
      fi
      key="$i:${event_ids[$j]}"
      if [[ -n "${cue_seen[$key]+x}" ]]; then
        (( debug == 0 )) || cue_skip_reasons["$i:$j"]=seen
        continue
      fi
      if (( event_starts[j] < cutoff || event_starts[j] > now * 1000 )); then
        (( debug == 0 )) || cue_skip_reasons["$i:$j"]=window
        continue
      fi
      zones=${event_zones[$j]}
      if (( priority )); then
        zones=${event_now_zones[$j]}
        if [[ "$zones" == '[]' ]]; then
          if (( debug && event_starts[j] < recent_cutoff )); then cue_skip_reasons["$i:$j"]=window; fi
          continue
        fi
      else
        if (( event_starts[j] < recent_cutoff )); then
          if (( debug )) && [[ "${cue_skip_reasons["$i:$j"]:-}" != type ]]; then cue_skip_reasons["$i:$j"]=window; fi
          continue
        fi
      fi
      matched_zone=""
      if [[ -n "${cue_zones[$i]:-}" ]]; then
        zone_match=0
        IFS=$'\t' read -r -a zone_tokens <<< "${cue_zones[$i]}"
        for zone_id in "${zone_tokens[@]}"; do
          if [[ "$zones" == *\""$zone_id"\"* ]]; then
            zone_match=1
            matched_zone=" (${cue_zone_labels["$i:$zone_id"]:-$zone_id})"
            break
          fi
        done
        if (( zone_match == 0 )); then
          if (( debug && (priority == 0 || event_starts[j] < recent_cutoff) )); then cue_skip_reasons["$i:$j"]=zone; fi
          continue
        fi
      fi
      IFS=$'\t' read -r -a tokens <<< "${event_types[$j]}"
      for etype in "${tokens[@]}"; do
        if [[ "${cue_types[$i]}" == *$'\t'"$etype"$'\t'* ]]; then
          cue_seen["$key"]=${event_starts[$j]}
          cue_pending=$i
          cue_match=${etype:1:${#etype}-2}
          cue_matched_at=$now
          cue_until[i]=$(( now + cue_cooldowns[i] ))
          if (( reacquire == 0 )) && [[ "${cue_slots[$i]}" == "$last_commanded_slot" ]]; then
            cue_no_goto=1
          fi
          local prefix=""
          (( reacquire == 0 )) || prefix="Tracking lost — "
          local suffix=""
          if (( cue_no_goto )); then
            suffix=" (already there)"
          elif (( ${cue_in_progress:-0} )) && [[ "${cue_slots[$i]}" != "${cue_slot:--1}" ]]; then
            suffix=" (pre-empts $status_cue_camera)"
          fi
          log "$cam_name" "info" "${prefix}Cue: ${cue_names[$i]} $cue_match$matched_zone → slot ${cue_slots[$i]}$suffix"
          if (( debug )); then
            unset 'cue_skip_reasons[$i:$j]'
            _patrol_log_cue_skips
            log "$cam_name" "debug" "Cue fired entry=$i ${event_debug[$j]}"
          fi
          return 0
        fi
      done
      (( debug == 0 )) || cue_skip_reasons["$i:$j"]="type"
    done
  done
  done
  (( debug == 0 )) || _patrol_log_cue_skips
  return 1
}

# ---------------------------------------------------------------------------
# Status and camera-name updates
# ---------------------------------------------------------------------------

# The state fields use caller scope so home dwell reports the same camera state.
# Reads/writes these caller-scope variables directly (not local to this
# function, shared through Bash dynamic scoping):
#   cam_id cam_name status_state status_since status_last_post status_slot
#   status_heartbeat_seconds status_version status_cue_camera
_patrol_status_tick() {
  local next_state=$1 now=${2:-}
  [[ -n "$_STATUS_WEBHOOK_URL" ]] || return 0
  if [[ -z "$now" ]]; then
    # The Bash builtin gets current time without a date process on each status poll.
    printf -v now '%(%s)T' -1
  fi
  if [[ "$next_state" != "$status_state" ]]; then
    status_state=$next_state
    status_since=$now
  elif [[ "$next_state" != cued || "${status_cue_changed:-0}" == 0 ]] && (( status_heartbeat_seconds == 0 || now - status_last_post < status_heartbeat_seconds )); then
    return 0
  fi
  local cue_camera=""
  [[ "$status_state" != cued ]] || cue_camera=${status_cue_camera:-}
  api_post_status "$cam_id" "$cam_name" "$status_state" "$status_slot" "$status_since" "$now" "$status_version" "$cue_camera"
  status_cue_changed=0
  status_last_post=$now
}

# Reads/writes these caller-scope variables directly (not local to this
# function, shared through Bash dynamic scoping):
#   status_state status_idle_state
# Nested status updates share the caller's other status fields.
_patrol_status_activity() {
  local active=$1 known=$2 now=${3:-}
  [[ -n "$_STATUS_WEBHOOK_URL" ]] || return 0
  if [[ "$known" == "0" && "$status_state" == "unreadable" ]]; then
    _patrol_status_tick unreadable "$now"
  elif [[ "$active" == "1" ]]; then
    _patrol_status_tick holding_activity "$now"
  else
    _patrol_status_tick "${status_idle_state:-patrolling}" "$now"
  fi
}

# Dynamic scoping lets this helper update the caller's cam_name and protect_name.
_patrol_refresh_camera_name() {
  [[ -z "${protect_name+x}" ]] && return 0
  if [[ -n "$_LAST_CAM_NAME" && "$_LAST_CAM_NAME" != "$protect_name" ]]; then
    log "$cam_name" "info" "Camera renamed in Protect: '$protect_name' → '$_LAST_CAM_NAME'"
    protect_name=$_LAST_CAM_NAME
    cam_name="${protect_name}${id_suffix:+ #$id_suffix}"
  fi
}

# ---------------------------------------------------------------------------
# Home-between-cycles dwell
# ---------------------------------------------------------------------------

# Send the camera to its home position and dwell there for the configured
# dwell time, polling for motion/tracking and external control exactly like
# a normal preset dwell.
#
# Arguments: cam_id cam_name dwell motion_hold settle_seconds manual_hold
#            dyn_tracking poll_interval_s
#
# Reads/writes these caller-scope variables directly (not local to this
# function, shared via bash dynamic scoping):
#   last_goto_ts expected_pan expected_tilt expected_zoom
#   acquisition_state acquisition_streak
#   tracking_enabled external_control_until cam_name protect_name cue_pending
#   hold_home_pan hold_home_tilt hold_home_zoom hold_home_streak
#
# Returns 0 if dwell completed normally, 1 if interrupted (caller should
# continue back to the top of the main patrol loop).
_patrol_home_dwell() {
  local cam_id=$1 dwell=$3 motion_hold=$4 settle_seconds=$5
  cam_name=$2
  local manual_hold=$6 dyn_tracking=$7 poll_iv_s=${8:-5}

  local hbc_code
  api_post_with_retry "/cameras/$cam_id/ptz/goto/-1" 2 3 >/dev/null || true
  hbc_code="$_LAST_HTTP_CODE"

  if [[ "$hbc_code" != "200" && "$hbc_code" != "204" ]]; then
    log "$cam_name" "warn" "Failed to go home between cycles (HTTP ${hbc_code:-timeout})"
    return 0  # Not interrupted — just skip the home dwell
  fi

  log "$cam_name" "info" "→ Home (between cycles) [HTTP $hbc_code]"
  last_goto_ts=$(date +%s)
  # Home position has no preset data — establish a stable live baseline after settle.
  expected_pan=-1; expected_tilt=-1; expected_zoom=-1
  last_commanded_slot=-1
  status_slot=-1
  acquisition_state="acquiring"
  acquisition_streak=0
  goto_retry_count=0
  local home_sampled=0
  local home_sample_valid=0
  local home_sample_pan=-1 home_sample_tilt=-1 home_sample_zoom=-1
  local home_baseline_ready=0
  local home_drift_attempts=0 home_drift_streak=0 home_previous_drift=0
  local home_drift_attempt_limit=3
  local home_activity_checked=0
  local home_unknown_seconds=0
  local home_pan_stable_thresh=200 home_tilt_stable_thresh=200 home_zoom_stable_thresh=30

  local hbc_remaining=$dwell
  while (( hbc_remaining > 0 )); do
    local hbc_poll
    hbc_poll=$(( hbc_remaining < poll_iv_s ? hbc_remaining : poll_iv_s ))
    sleep "$hbc_poll"
    hbc_remaining=$(( hbc_remaining - hbc_poll ))

    # Single API fetch per poll cycle (for tracking check).
    # On failure, skip this poll cycle (fail-safe: hold position).
    local cam_state=""
    if api_get_camera_state "$cam_id"; then
      cam_state="$_CACHED_CAM_STATE"
    else
      home_drift_attempts=0
      home_drift_streak=0
      home_previous_drift=0
      home_unknown_seconds=$(( home_unknown_seconds + hbc_poll ))
      if (( home_unknown_seconds >= 300 )); then
        log "$cam_name" "warn" "Camera unreadable for $(( home_unknown_seconds / 60 ))m during home dwell — holding position (no activity check succeeded)"
        _patrol_status_tick unreadable
        home_unknown_seconds=0
      fi
      _patrol_status_activity 1 0
      continue
    fi

    # Keep sampling after settle until two consecutive reads are materially
    # unchanged. A first read can still be mid-transit to home.
    local now
    now=$(date +%s)
    home_baseline_ready=0
    if (( home_sampled == 0 && now - last_goto_ts >= settle_seconds )); then
      local sample_pan sample_tilt sample_zoom
      IFS=$'\t' read -r sample_pan sample_tilt sample_zoom <<< "$(api_get_ptz_position "$cam_id")"
      if [[ "$sample_pan" =~ ^[0-9]+$ && "$sample_tilt" =~ ^[0-9]+$ && "$sample_zoom" =~ ^[0-9]+$ ]]; then
        if (( home_sample_valid == 1 )); then
          local sample_pan_diff=$(( sample_pan - home_sample_pan ))
          local sample_tilt_diff=$(( sample_tilt - home_sample_tilt ))
          local sample_zoom_diff=$(( sample_zoom - home_sample_zoom ))
          sample_pan_diff=${sample_pan_diff#-}
          sample_tilt_diff=${sample_tilt_diff#-}
          sample_zoom_diff=${sample_zoom_diff#-}
          if (( sample_pan_diff <= home_pan_stable_thresh &&
                sample_tilt_diff <= home_tilt_stable_thresh &&
                sample_zoom_diff <= home_zoom_stable_thresh )); then
            expected_pan=$sample_pan
            expected_tilt=$sample_tilt
            expected_zoom=$sample_zoom
            home_sampled=1
            home_baseline_ready=1
            # The baseline is acquired by observation, not by a goto target.
            acquisition_state="acquired"
            acquisition_streak=2
            log "$cam_name" "debug" "Home baseline accepted after stable position reads"
          fi
        fi
        home_sample_pan=$sample_pan
        home_sample_tilt=$sample_tilt
        home_sample_zoom=$sample_zoom
        home_sample_valid=1
      else
        home_sample_valid=0
      fi
    fi

    # Classify activity before the external-control check so the freshest live
    # tracking state can suppress drift detection without changing priority.
    local activity_active=0
    if is_tracking "$cam_id" "$motion_hold" "$last_goto_ts" "$settle_seconds" "$cam_state"; then
      activity_active=1
    fi
    _patrol_refresh_camera_name
    if (( _LAST_TRACKING_ACTIVE == 1 )); then
      expected_pan=-1; expected_tilt=-1; expected_zoom=-1
      acquisition_state="acquiring"
      acquisition_streak=0
    fi
    if (( _LAST_ACTIVITY_KNOWN == 1 )); then
      home_activity_checked=1
      home_unknown_seconds=0
    else
      home_unknown_seconds=$(( home_unknown_seconds + hbc_poll ))
      if (( home_unknown_seconds >= 300 )); then
        log "$cam_name" "warn" "Camera unreadable for $(( home_unknown_seconds / 60 ))m during home dwell — holding position (no activity check succeeded)"
        _patrol_status_tick unreadable "$now"
        home_unknown_seconds=0
      fi
    fi
    _patrol_status_activity "$activity_active" "$_LAST_ACTIVITY_KNOWN" "$now"

    # Check for external control (pan/tilt/zoom drift).
    # Skip when live auto-tracking is enabled — the camera may have moved to track.
    if (( home_sampled == 1 && home_baseline_ready == 0 && _LAST_TRACKING_ACTIVE == 0 )); then
      local external_controlled=0
      is_externally_controlled "$cam_id" "$cam_name" "$settle_seconds" "$last_goto_ts" "$expected_pan" "$expected_tilt" "$expected_zoom" "$acquisition_state" "$acquisition_streak"
      external_controlled=$?
      acquisition_state="$_LAST_ACQUISITION_STATE"
      acquisition_streak=$_LAST_ACQUISITION_STREAK
      if (( _LAST_AT_HOMEVIEW == 1 )); then
        expected_pan=-1; expected_tilt=-1; expected_zoom=-1
        acquisition_state="none"
        acquisition_streak=0
      fi
      if (( external_controlled == 0 )); then
        # Retain at least 75% of the previous drift. A ratio handles pan/tilt
        # and zoom's different motor-step scales while rejecting convergence.
        if (( home_drift_streak > 0 && _LAST_DRIFT_MAGNITUDE * 4 >= home_previous_drift * 3 )); then
          external_control_until=$(( $(date +%s) + manual_hold ))
          hold_home_pan=${_LAST_HOME_PAN:--1}; hold_home_tilt=${_LAST_HOME_TILT:--1}; hold_home_zoom=${_LAST_HOME_ZOOM:--1}
          hold_home_streak=0
          acquisition_state="acquiring"
          acquisition_streak=0
          log "$cam_name" "info" "External control detected during home dwell — holding patrol for ${manual_hold}s"
          _patrol_status_tick holding_manual "$now"
          home_drift_attempts=0
          home_drift_streak=0
          home_previous_drift=0
          return 1
        fi
        home_drift_attempts=$(( home_drift_attempts + 1 ))
        if (( home_drift_attempts >= home_drift_attempt_limit )); then
          log "$cam_name" "debug" "PTZ drift did not persist during home dwell — continuing"
          home_drift_attempts=0
          home_drift_streak=0
          home_previous_drift=0
        elif (( home_drift_streak > 0 )); then
          home_drift_streak=0
          home_previous_drift=0
        else
          home_drift_streak=1
          home_previous_drift=$_LAST_DRIFT_MAGNITUDE
        fi
      elif (( _LAST_GOTO_FAILED == 1 )); then
        # Home has no commanded preset coordinates, so this path is defensive
        # and must never convert a home baseline anomaly into a manual hold.
        home_drift_attempts=0
        home_drift_streak=0
        home_previous_drift=0
      else
        home_drift_attempts=0
        home_drift_streak=0
        home_previous_drift=0
      fi
    else
      home_drift_attempts=0
      home_drift_streak=0
      home_previous_drift=0
    fi

    # Check for motion/tracking (with motor-induced motion filtering)
    if (( activity_active )); then
      log "$cam_name" "info" "Activity during home dwell — holding"
      return 1
    fi
    if [[ -n "${cue_query:-}" ]] && (( _LAST_ACTIVITY_KNOWN == 1 && _LAST_TRACKING_ACTIVE == 0 && home_drift_attempts == 0 )); then
      if _patrol_poll_cues; then return 1; fi
    fi
  done

  if (( home_activity_checked == 0 )); then
    log "$cam_name" "warn" "No successful activity checks during home dwell — holding patrol"
    return 1
  fi

  return 0
}

# ---------------------------------------------------------------------------
# Patrol loop
# ---------------------------------------------------------------------------

# Resolve settings and preset list, then loop forever
# Arguments: cam_id cam_name cam_discovery_json [id_suffix]
patrol_camera() {
  local cam_id=$1 cam_name=$2
  local protect_name=$cam_name id_suffix=${4:-}
  cam_name="${protect_name}${id_suffix:+ #$id_suffix}"
  # Optional: pre-fetched camera JSON from discovery (3rd arg)
  local cam_discovery_json=${3:-}

  local cam_config
  cam_config=$(get_camera_config "$cam_id")

  # jq's // treats false as missing, so `.enabled // true` cannot read false.
  local enabled
  enabled=$(echo "$cam_config" | jq -r 'if .enabled == null then true else .enabled end')
  if [[ "$enabled" == "false" ]]; then
    log "$cam_name" "info" "Disabled — skipping"
    return
  fi

  local status_state="" status_since=0 status_last_post=0 status_slot=""
  local status_idle_state=patrolling status_cue_camera="" status_cue_changed=0
  local status_heartbeat_seconds=300 status_version=""
  if [[ -n "$_STATUS_WEBHOOK_URL" ]]; then
    status_heartbeat_seconds=$(jq -r '
      (if .status_heartbeat_seconds == null then 300 else .status_heartbeat_seconds end) as $v
      | if ($v | type) == "number" and ($v == 0 or $v >= 30) and ($v | floor) == $v
        then $v else "invalid" end
    ' <<< "$cam_config")
    if [[ "$status_heartbeat_seconds" == "invalid" ]]; then
      log "$cam_name" "warn" "Invalid status_heartbeat_seconds — using 300"
      status_heartbeat_seconds=300
    fi
    status_version=$(get_install_version)
  fi

  local dwell motion_hold max_wait max_smart_wait manual_hold settle_seconds
  dwell=$(echo "$cam_config" | jq -r '.dwell_seconds // 30')
  motion_hold=$(echo "$cam_config" | jq -r '.motion_hold_seconds // 15')
  IFS=$'\t' read -r max_wait max_smart_wait <<< "$(jq -r '
    (if .max_smart_wait == null then 1800 else .max_smart_wait end) as $v
    | [.max_tracking_wait // 300,
       (if ($v | type) == "number" and $v >= 0 and ($v | floor) == $v
        then $v else "invalid" end)] | @tsv
  ' <<< "$cam_config")"
  if [[ "$max_smart_wait" == invalid ]]; then
    log "$cam_name" "warn" "Invalid max_smart_wait — using 1800"
    max_smart_wait=1800
  fi
  manual_hold=$(echo "$cam_config" | jq -r '.manual_control_hold_seconds // 120')
  settle_seconds=$(echo "$cam_config" | jq -r '.ptz_settle_seconds // 10')
  local configured_settle_seconds=$settle_seconds

  # --- Sanity-clamp timing relationships ---
  # Settle must be less than dwell so there are detection windows during dwell.
  # Clamp to at most dwell/2 (minimum 1s) to guarantee at least 1-2 polls
  # where external-control and motion detection are actually active.
  local max_settle=$(( dwell / 2 ))
  (( max_settle < 1 )) && max_settle=1
  if (( settle_seconds >= dwell )); then
    log "$cam_name" "warn" "ptz_settle_seconds ($settle_seconds) >= dwell_seconds ($dwell) — clamping to ${max_settle}s"
    settle_seconds=$max_settle
  elif (( settle_seconds > max_settle )); then
    log "$cam_name" "info" "ptz_settle_seconds ($settle_seconds) > dwell/2 — clamping to ${max_settle}s for better detection"
    settle_seconds=$max_settle
  fi

  # Compute adaptive poll interval: min(5, dwell/3) with a 2s floor.
  # Short dwells need faster polling to get enough detection windows.
  local poll_interval_s=$(( dwell / 3 ))
  (( poll_interval_s > 5 )) && poll_interval_s=5
  (( poll_interval_s < 2 )) && poll_interval_s=2
  local camera_settle_seconds=$settle_seconds camera_poll_interval_s=$poll_interval_s
  local slot_dwell=$dwell
  local path_mode path_info=""
  path_mode=$(printf '%s' "$cam_config" | jq -r 'if .path_mode == null then "loop" else .path_mode end')
  case "$path_mode" in
    loop) ;;
    pingpong) path_info=" path=pingpong" ;;
    *)
      log "$cam_name" "warn" "Invalid path_mode '$path_mode' — using loop"
      path_mode="loop"
      ;;
  esac

  # Schedule: optional time window for when patrol should be active
  local sched_start sched_end sched_days sched_constrain_start_minute sched_constrain_end_minute sched_home
  sched_start=$(echo "$cam_config" | jq -r '.schedule.start // empty')
  sched_end=$(echo "$cam_config" | jq -r '.schedule.end // empty')
  sched_days=$(echo "$cam_config" | jq -c '.schedule.days // null')
  local schedule_set=0
  if [[ -n "$sched_start" && -n "$sched_end" ]]; then
    schedule_set=1
  fi
  _patrol_parse_constrain "$cam_config" "$cam_name" "$schedule_set"
  local constrain_active=$_PATROL_CONSTRAIN_ACTIVE
  sched_constrain_start_minute=$_PATROL_CONSTRAIN_START
  sched_constrain_end_minute=$_PATROL_CONSTRAIN_END
  sched_home=$(echo "$cam_config" | jq -r '.schedule.home_on_pause // false')

  if [[ -n "$sched_start" && -n "$sched_end" && "$sched_start" == "$sched_end" ]]; then
    log "$cam_name" "warn" "Schedule start and end are the same ($sched_start) — patrol will never run. Remove schedule or fix times."
  fi

  # Home between cycles: go to home position after cycling through all presets
  local home_between_cycles
  home_between_cycles=$(echo "$cam_config" | jq -r '.home_between_cycles // false')

  # Dynamic auto-tracking: enable tracking on smart detection, disable when clear
  local dyn_tracking
  dyn_tracking=$(echo "$cam_config" | jq -r '.dynamic_auto_tracking // false')
  local tracking_types_json='["person"]' tracking_types_label=person tracking_with_zoom=null
  if [[ "$dyn_tracking" == "true" ]]; then
    _patrol_parse_tracking_config "$cam_config" "$cam_discovery_json" "$cam_name"
  fi

  # Presets: explicit override or auto-discovered
  local -a presets
  local override_slots
  override_slots=$(echo "$cam_config" | jq -r '.preset_slots // empty')

  if [[ -n "$override_slots" ]]; then
    mapfile -t presets < <(echo "$override_slots" | jq -r '.[]')
  elif [[ -n "$cam_discovery_json" ]]; then
    # Use presets from discovery data (avoids extra API call)
    mapfile -t presets < <(echo "$cam_discovery_json" | jq -r '.presets[].slot')
  else
    # Fetch from the per-camera preset endpoint (ptzPresetPositions on the
    # camera object is empty on many firmware versions)
    local preset_response
    if api_get_with_retry "/cameras/$cam_id/ptz/preset" 3 5 >/dev/null; then
      preset_response="$_LAST_BODY"
    else
      preset_response="[]"
    fi
    mapfile -t presets < <(printf '%s' "$preset_response" | jq -r '
      [. // [] | sort_by(.slot) | .[].slot] | .[]
    ')
  fi

  local -A preset_dwells=()
  local preset_dwell_info="" dwell_key dwell_value dwell_valid dwell_normalized patrol_slot slot_found
  while IFS=$'\t' read -r dwell_key dwell_value dwell_valid dwell_normalized; do
    dwell_key=${dwell_key#K:}
    if [[ "$dwell_valid" != "1" ]]; then
      log "$cam_name" "warn" "Invalid preset_dwell_seconds entry ${dwell_key}=${dwell_value} — ignoring"
      continue
    fi
    slot_found=0
    for patrol_slot in "${presets[@]}"; do
      [[ "$dwell_key" == "$patrol_slot" ]] && slot_found=1
    done
    if (( slot_found == 0 )); then
      log "$cam_name" "warn" "Unknown patrol slot in preset_dwell_seconds: ${dwell_key}=${dwell_value} — ignoring"
      continue
    fi
    preset_dwells["$dwell_key"]=$dwell_normalized
    if [[ -z "$preset_dwell_info" ]]; then
      preset_dwell_info=" preset_dwell=${dwell_key}:${dwell_normalized}"
    else
      preset_dwell_info+=",${dwell_key}:${dwell_normalized}"
    fi
  done < <(printf '%s' "$cam_config" | jq -r '
    (.preset_dwell_seconds // {}) | if type == "object" then
      to_entries[] | .value as $v
      | (if (.key | test("^[0-9]+$")) and
          (($v | type) == "number" or ($v | type) == "string") and
          ($v | tostring | test("^[0-9]+$")) and
          ($v | tonumber) >= 1
         then "1" else "0" end) as $valid
      | [("K:" + .key), ($v | tojson), $valid,
         (if $valid == "1" then ($v | tostring | sub("^0+"; "")) else "-" end)] | @tsv
    else ["K:<map>", tojson, "0", "-"] | @tsv end
  ')

  if [[ "$path_mode" == "pingpong" ]] && (( ${#presets[@]} >= 3 )); then
    local reverse_idx
    for (( reverse_idx = ${#presets[@]} - 2; reverse_idx >= 1; reverse_idx-- )); do
      presets+=("${presets[$reverse_idx]}")
    done
  fi

  if (( ${#presets[@]} < 2 )); then
    log "$cam_name" "warn" "Only ${#presets[@]} preset(s) — need 2+. Skipping."
    return 2  # Permanent condition — caller should not retry frequently
  fi

  # Cache preset positions (pan/tilt/zoom in motor steps) for drift detection.
  # This JSON array is used by get_preset_ptz() to look up expected positions.
  local preset_positions
  preset_positions=$(api_get_preset_positions "$cam_id")

  local -a cue_camera_ids=() cue_slots=() cue_types=() cue_holds=() cue_cooldowns=() cue_names=() cue_until=() cue_zones=()
  local -A cue_zone_labels=()
  local -A cue_seen=()
  local cue_query="" cue_pending=-1 cue_match="" cue_in_progress=0 cue_resume=0 cue_hold=0
  local cue_matched_at=0 cue_poll_failed=0 cue_no_goto=0
  # Failed-goto exhaustion clears last_commanded_slot. Retain the cue target.
  local cue_slot=-1
  _patrol_parse_cues

  local constrain_info=""
  if (( constrain_active )); then
    constrain_info=", constrained to minutes ${sched_constrain_start_minute} through ${sched_constrain_end_minute} after the hour"
  fi
  local sched_info=""
  if [[ -n "$sched_start" && -n "$sched_end" ]]; then
    sched_info=" schedule=${sched_start}-${sched_end}"
    if (( constrain_active )); then
      sched_info+=" constrain_patrol_minutes=${sched_constrain_start_minute}-${sched_constrain_end_minute}"
    fi
    if [[ -n "$sched_days" && "$sched_days" != "null" ]]; then
      local days_str; days_str=$(echo "$sched_days" | jq -r 'join(",")')
      sched_info+=" days=${days_str}"
    fi
    sched_info+=" home_on_pause=${sched_home}"
  fi
  local dyn_info=""
  if [[ "$dyn_tracking" == "true" ]]; then
    dyn_info=" dynamic_tracking=on types=$tracking_types_label"
    case "$tracking_with_zoom" in
      true) dyn_info+=" zoom=on" ;;
      false) dyn_info+=" zoom=off" ;;
    esac
  fi
  local home_cycle_info=""
  if [[ "$home_between_cycles" == "true" ]]; then
    home_cycle_info=" home_between_cycles=on"
  fi
  log "$cam_name" "info" "Patrol: presets=[${presets[*]}] dwell=${dwell}s settle=${settle_seconds}s poll=${poll_interval_s}s hold=${motion_hold}s max_wait=${max_wait}s max_smart_wait=${max_smart_wait}s manual_hold=${manual_hold}s${sched_info}${dyn_info}${home_cycle_info}${preset_dwell_info}${path_info}"

  local idx=0
  # Fresh zero-cooldown events must not keep a path step in a repeat loop.
  local step_repeated=0
  local last_goto_ts=0
  local expected_pan=-1
  local expected_tilt=-1
  local expected_zoom=-1
  local last_commanded_slot=-1
  local acquisition_state="none"
  local acquisition_streak=0
  local goto_retry_count=0
  local goto_retry_limit=2
  local own_event_since=0 own_event_poll_failed=0 own_event_capped=0
  local external_control_until=0
  local hold_home_pan=-1 hold_home_tilt=-1 hold_home_zoom=-1 hold_home_streak=0
  local schedule_paused=0
  local tracking_enabled=0
  local unknown_hold_seconds=0
  local top_drift_attempts=0 top_drift_streak=0 top_previous_drift=0
  local top_drift_attempt_limit=3
  local startup_settle_pending=1

  # Enable auto-tracking once at patrol start (stays on permanently).
  # Only disabled on schedule pause and shutdown.
  if [[ "$dyn_tracking" == "true" ]]; then
    if set_auto_tracking "$cam_id" "$cam_name" "$tracking_types_json" "enabled" "$tracking_with_zoom"; then
      tracking_enabled=1
    fi
  fi

  while true; do
    if (( cue_in_progress && cue_pending < 0 )); then
      _patrol_end_cue_hold
    fi
    api_ensure_auth

    # --- Schedule check ---
    if ! is_within_schedule "$sched_start" "$sched_end" "$sched_days" "$sched_constrain_start_minute" "$sched_constrain_end_minute"; then
      if (( schedule_paused == 0 )); then
        log "$cam_name" "info" "Outside schedule window (${sched_start}-${sched_end}${constrain_info}) — pausing patrol"
        if [[ "$sched_home" == "true" ]]; then
          local home_code
          api_post_with_retry "/cameras/$cam_id/ptz/goto/-1" 2 3 >/dev/null || true
          home_code="$_LAST_HTTP_CODE"
          if [[ "$home_code" == "200" || "$home_code" == "204" ]]; then
            status_slot=-1
            log "$cam_name" "info" "Sent to home position"
          else
            log "$cam_name" "warn" "Failed to send to home position (HTTP ${home_code:-timeout})"
          fi
        fi
        # Disable dynamic auto-tracking while paused
        if [[ "$dyn_tracking" == "true" ]] && (( tracking_enabled == 1 )); then
          set_auto_tracking "$cam_id" "$cam_name" "[]" "disabled"
          tracking_enabled=0
        fi
        schedule_paused=1
        cue_no_goto=0
        expected_pan=-1; expected_tilt=-1; expected_zoom=-1
        acquisition_state="acquiring"
        acquisition_streak=0
      fi
      _patrol_status_tick paused_schedule
      sleep 60
      continue
    fi
    if (( schedule_paused == 1 )); then
      log "$cam_name" "info" "Schedule window active (${sched_start}-${sched_end}${constrain_info}) — resuming patrol"
      schedule_paused=0
      expected_pan=-1; expected_tilt=-1; expected_zoom=-1
      acquisition_state="acquiring"
      acquisition_streak=0
      # Re-enable auto-tracking after schedule pause
      if [[ "$dyn_tracking" == "true" ]] && (( tracking_enabled == 0 )); then
        if set_auto_tracking "$cam_id" "$cam_name" "$tracking_types_json" "enabled" "$tracking_with_zoom"; then
          tracking_enabled=1
        fi
      fi
    fi

    # --- Backoff if too many consecutive API failures ---
    if (( _CONSECUTIVE_FAILURES >= 3 )); then
      local backoff
      backoff=$(api_backoff_delay 10 120)
      log "$cam_name" "warn" "$_CONSECUTIVE_FAILURES consecutive failures — backing off ${backoff}s"
      sleep "$backoff"
      api_ensure_auth
    fi

    local now; now=$(date +%s)

    # --- Check for external control (manual PTZ use) ---
    local hold_returned=0
    if (( now < external_control_until )); then
      if (( hold_home_pan >= 0 && hold_home_tilt >= 0 && hold_home_zoom >= 0 )); then
        local hold_position="" hold_live_pan hold_live_tilt hold_live_zoom
        hold_position=$(api_get_ptz_position "$cam_id") || hold_position=""
        IFS=$'\t' read -r hold_live_pan hold_live_tilt hold_live_zoom <<< "$hold_position"
        if [[ "$hold_live_pan" =~ ^[0-9]+$ && "$hold_live_tilt" =~ ^[0-9]+$ && "$hold_live_zoom" =~ ^[0-9]+$ ]]; then
          local hold_pan_diff=$(( hold_live_pan - hold_home_pan ))
          local hold_tilt_diff=$(( hold_live_tilt - hold_home_tilt ))
          local hold_zoom_diff=$(( hold_live_zoom - hold_home_zoom ))
          hold_pan_diff=${hold_pan_diff#-}; hold_tilt_diff=${hold_tilt_diff#-}; hold_zoom_diff=${hold_zoom_diff#-}
          if (( hold_pan_diff <= 200 && hold_tilt_diff <= 200 && hold_zoom_diff <= 30 )); then
            hold_home_streak=$(( hold_home_streak + 1 ))
          else
            hold_home_streak=0
          fi
        else
          hold_home_streak=0
        fi
      fi
      if (( hold_home_streak >= 2 )); then
        hold_returned=1
        log "$cam_name" "info" "Camera returned to its HomeView — ending manual hold"
      else
        local remaining=$(( external_control_until - now ))
        log "$cam_name" "debug" "Manual control hold — ${remaining}s remaining"
        _patrol_status_tick holding_manual "$now"
        sleep 5
        continue
      fi
    fi
    if (( external_control_until > 0 )); then
      # Either hold exit must clear stale targets before drift checks resume.
      expected_pan=-1; expected_tilt=-1; expected_zoom=-1
      acquisition_state="acquiring"
      acquisition_streak=0
      external_control_until=0
      cue_no_goto=0
      top_drift_attempts=0
      top_drift_streak=0
      top_previous_drift=0
      hold_home_pan=-1; hold_home_tilt=-1; hold_home_zoom=-1
      hold_home_streak=0
      if (( hold_returned == 0 )); then
        log "$cam_name" "info" "Manual control hold expired — resuming patrol"
      fi
    fi

    # Single API fetch for top-of-loop tracking check.
    # On failure, sleep and retry next iteration (fail-safe: hold position).
    local top_state=""
    if api_get_camera_state "$cam_id"; then
      top_state="$_CACHED_CAM_STATE"
    else
      top_drift_attempts=0
      top_drift_streak=0
      top_previous_drift=0
      unknown_hold_seconds=$(( unknown_hold_seconds + 5 ))
      if (( unknown_hold_seconds >= 300 )); then
        log "$cam_name" "warn" "Camera unreadable for $(( unknown_hold_seconds / 60 ))m — holding position (no activity check succeeded)"
        _patrol_status_tick unreadable "$now"
        unknown_hold_seconds=0
      fi
      _patrol_status_activity 1 0 "$now"
      sleep 5
      continue
    fi

    # Classify activity before the external-control check so the freshest live
    # tracking state can suppress drift detection without changing priority.
    local activity_active=0
    if is_tracking "$cam_id" "$motion_hold" "$last_goto_ts" "$settle_seconds" "$top_state"; then
      activity_active=1
    fi
    _patrol_refresh_camera_name
    if (( _LAST_TRACKING_ACTIVE == 1 )); then
      cue_no_goto=0
      expected_pan=-1; expected_tilt=-1; expected_zoom=-1
      acquisition_state="acquiring"
      acquisition_streak=0
    fi
    if (( _LAST_ACTIVITY_KNOWN == 1 )); then
      unknown_hold_seconds=0
    fi

    if (( _LAST_TRACKING_ACTIVE == 0 )); then
      local external_controlled=0
      is_externally_controlled "$cam_id" "$cam_name" "$settle_seconds" "$last_goto_ts" "$expected_pan" "$expected_tilt" "$expected_zoom" "$acquisition_state" "$acquisition_streak"
      external_controlled=$?
      acquisition_state="$_LAST_ACQUISITION_STATE"
      acquisition_streak=$_LAST_ACQUISITION_STREAK
      if (( _LAST_AT_HOMEVIEW == 1 )); then
        expected_pan=-1; expected_tilt=-1; expected_zoom=-1
        acquisition_state="none"
        acquisition_streak=0
      fi
      if (( external_controlled == 0 )); then
        if (( top_drift_streak > 0 && _LAST_DRIFT_MAGNITUDE * 4 >= top_previous_drift * 3 )); then
          external_control_until=$(( $(date +%s) + manual_hold ))
          hold_home_pan=${_LAST_HOME_PAN:--1}; hold_home_tilt=${_LAST_HOME_TILT:--1}; hold_home_zoom=${_LAST_HOME_ZOOM:--1}
          hold_home_streak=0
          acquisition_state="acquiring"
          acquisition_streak=0
          log "$cam_name" "info" "External control detected — holding patrol for ${manual_hold}s"
          _patrol_status_tick holding_manual "$now"
          top_drift_attempts=0
          top_drift_streak=0
          top_previous_drift=0
          sleep 5
          continue
        fi
        top_drift_attempts=$(( top_drift_attempts + 1 ))
        if (( top_drift_attempts >= top_drift_attempt_limit )); then
          log "$cam_name" "debug" "PTZ drift did not persist — continuing patrol"
          top_drift_attempts=0
          top_drift_streak=0
          top_previous_drift=0
        elif (( top_drift_streak > 0 )); then
          top_drift_streak=0
          top_previous_drift=0
          sleep 5
          continue
        else
          top_drift_streak=1
          top_previous_drift=$_LAST_DRIFT_MAGNITUDE
          # Keep the current target while waiting for the confirming poll.
          sleep 5
          continue
        fi
      elif (( _LAST_GOTO_FAILED == 1 )); then
        top_drift_attempts=0
        top_drift_streak=0
        top_previous_drift=0
        # A pending cue replaces the old target. A completed cue must not restart.
        if (( last_commanded_slot >= 0 && cue_pending < 0 && cue_resume == 0 )); then
          # After a hold, check the position again before any retry.
          if ! _patrol_hold_own_smart_event 5; then
            continue
          fi
          if _patrol_reissue_failed_goto "$cam_id" "$cam_name" "$last_commanded_slot" "$goto_retry_limit"; then
            sleep 5
            continue
          fi
        fi
      else
        top_drift_attempts=0
        top_drift_streak=0
        top_previous_drift=0
      fi
    else
      top_drift_attempts=0
      top_drift_streak=0
      top_previous_drift=0
    fi

    # --- Hold while tracking/motion is active ---
    local slot="${presets[$idx]}"
    local waited=0
    local hold_reason motion_only_seconds=0 hold_had_tracking=0
    local tracking_seconds=0 smart_seconds=0 motion_seconds=0 unknown_seconds=0
    # First iteration uses the already-fetched top_state; subsequent iterations
    # fetch fresh state since the camera may have moved during the sleep.
    if (( activity_active )); then
      _patrol_status_activity 1 "$_LAST_ACTIVITY_KNOWN" "$now"
    fi
    while (( activity_active )); do
      top_state=""  # Clear so subsequent iterations fetch fresh state
      if (( _LAST_ACTIVITY_KNOWN == 0 )); then
        hold_reason=unknown
      elif (( _LAST_SMART_ACTIVE == 1 )); then
        motion_only_seconds=0
        if (( _LAST_TRACKING_ACTIVE == 1 )); then hold_reason=tracking; else hold_reason=smart; fi
      else
        hold_reason=motion
      fi
      [[ "$hold_reason" != tracking ]] || hold_had_tracking=1
      if (( waited == 0 )); then
        log "$cam_name" "info" "Tracking/motion active — holding ($hold_reason)"
      elif [[ "$hold_reason" == motion ]] && (( motion_only_seconds >= max_wait )); then
        log "$cam_name" "warn" "Max wait (${max_wait}s) hit on motion only — advancing anyway"
        break
      elif [[ "$hold_reason" == tracking || "$hold_reason" == smart ]] && (( max_smart_wait > 0 && waited >= max_smart_wait )); then
        log "$cam_name" "warn" "Max smart wait (${max_smart_wait}s) hit while $hold_reason active — advancing anyway"
        break
      fi
      # Charge each sleep to the last known reason, not the next response.
      # Unknown time pauses motion-only seconds; only smart activity resets them.
      case "$hold_reason" in
        tracking) tracking_seconds=$(( tracking_seconds + 5 )) ;;
        smart) smart_seconds=$(( smart_seconds + 5 )) ;;
        motion) motion_seconds=$(( motion_seconds + 5 )); motion_only_seconds=$(( motion_only_seconds + 5 )) ;;
        unknown) unknown_seconds=$(( unknown_seconds + 5 )) ;;
      esac
      sleep 5
      waited=$((waited + 5))
      api_ensure_auth
      if is_tracking "$cam_id" "$motion_hold" "$last_goto_ts" "$settle_seconds" "$top_state"; then
        activity_active=1
      else
        activity_active=0
      fi
      if [[ "$hold_reason" == tracking ]] && (( _LAST_ACTIVITY_KNOWN == 0 || _LAST_SMART_ACTIVE == 0 || _LAST_TRACKING_ACTIVE == 0 )); then
        local end_position end_pan end_tilt end_zoom
        end_position=$(api_get_ptz_position "$cam_id") || end_position=""
        IFS=$'\t' read -r end_pan end_tilt end_zoom <<< "$end_position"
        if [[ "$end_pan" =~ ^[0-9]+$ && "$end_tilt" =~ ^[0-9]+$ && "$end_zoom" =~ ^[0-9]+$ ]]; then
          log "$cam_name" "info" "Tracking ended at pan $end_pan tilt $end_tilt zoom $end_zoom"
        else
          log "$cam_name" "info" "Tracking ended (position unreadable)"
        fi
      fi
      _patrol_refresh_camera_name
      if (( _LAST_ACTIVITY_KNOWN == 0 )); then
        unknown_hold_seconds=$(( unknown_hold_seconds + 5 ))
        if (( unknown_hold_seconds >= 300 )); then
          log "$cam_name" "warn" "Camera unreadable for $(( unknown_hold_seconds / 60 ))m — holding position (no activity check succeeded)"
          _patrol_status_tick unreadable
          unknown_hold_seconds=0
        fi
      else
        unknown_hold_seconds=0
      fi
      _patrol_status_activity "$activity_active" "$_LAST_ACTIVITY_KNOWN"
      if (( hold_had_tracking && _LAST_ACTIVITY_KNOWN == 1 && _LAST_SMART_ACTIVE == 0 && _LAST_TRACKING_ACTIVE == 0 )) && [[ -n "$cue_query" ]]; then
        if _patrol_poll_cues 1; then break; fi
      fi
    done
    if (( waited > 0 )); then
      local unknown_info=""
      (( unknown_seconds == 0 )) || unknown_info=", unknown ${unknown_seconds}s"
      log "$cam_name" "info" "Activity hold ended after ${waited}s (tracking ${tracking_seconds}s, smart ${smart_seconds}s, motion ${motion_seconds}s${unknown_info})"
    fi
    if (( activity_active == 0 && cue_in_progress == 0 )); then
      _patrol_status_tick patrolling
    fi
    if (( cue_pending >= 0 )); then
      printf -v now '%(%s)T' -1
      local cue_age=$(( now - cue_matched_at ))
      if (( cue_age > 15 )); then
        cue_pending=-1
        cue_resume=1
        log "$cam_name" "info" "Cue dropped — ${cue_age}s old"
        if (( cue_in_progress )); then
          _patrol_end_cue_hold
          slot=${presets[$idx]}
        fi
      fi
    fi
    # Dynamic auto-tracking: tracking may have moved the camera, so reset
    # expected position and advance to next preset (don't snap back).
    if [[ "$dyn_tracking" == "true" ]] && (( tracking_enabled == 1 && waited > 0 && cue_resume == 0 && cue_pending < 0 )); then
      expected_pan=-1; expected_tilt=-1; expected_zoom=-1
      acquisition_state="acquiring"
      acquisition_streak=0
      # Advance to next preset — tracking served as the dwell for this one,
      # so don't snap back to the same position the camera just tracked away from
      idx=$(( (idx + 1) % ${#presets[@]} ))
      step_repeated=0
      # Home between cycles: visit home position when cycle wraps
      if [[ "$home_between_cycles" == "true" ]] && (( idx == 0 )); then
        settle_seconds=$camera_settle_seconds
        poll_interval_s=$camera_poll_interval_s
        if ! _patrol_home_dwell "$cam_id" "$cam_name" "$dwell" "$motion_hold" \
             "$settle_seconds" "$manual_hold" "$dyn_tracking" "$poll_interval_s"; then
          continue  # Interrupted — back to top for hold/tracking checks
        fi
      fi
      slot="${presets[$idx]}"
    fi
    if (( cue_pending >= 0 )); then
      slot=${cue_slots[$cue_pending]}
      cue_slot=$slot
      cue_hold=${cue_holds[$cue_pending]}
      status_cue_camera=${cue_names[$cue_pending]}
      status_cue_changed=1
      status_idle_state=cued
      cue_in_progress=1
      cue_resume=1
      cue_pending=-1
    else
      cue_resume=0
    fi

    # --- Move to next preset ---
    if (( startup_settle_pending == 1 )); then
      _patrol_wait_for_camera_settle "$cam_id" "$cam_name" 30 || true
      startup_settle_pending=0
    fi
    local code goto_skipped=0
    # The skip flag must not outlive its cue, or a real goto loses its target state.
    if (( cue_in_progress && cue_no_goto )); then
      code=200
      goto_skipped=1
    else
      cue_no_goto=0
      api_post_with_retry "/cameras/$cam_id/ptz/goto/$slot" 2 3 >/dev/null || true
      code="$_LAST_HTTP_CODE"
    fi

    case "$code" in
      200|204)
        slot_dwell=$dwell
        if [[ -n "$slot" ]]; then
          slot_dwell=${preset_dwells[$slot]:-$dwell}
        fi
        (( cue_in_progress == 0 )) || slot_dwell=$cue_hold
        local slot_max_settle=$(( slot_dwell / 2 ))
        (( slot_max_settle < 1 )) && slot_max_settle=1
        settle_seconds=$configured_settle_seconds
        (( settle_seconds > slot_max_settle )) && settle_seconds=$slot_max_settle
        poll_interval_s=$(( slot_dwell / 3 ))
        (( poll_interval_s > 5 )) && poll_interval_s=5
        (( poll_interval_s < 2 )) && poll_interval_s=2
        if (( goto_skipped == 0 )); then
          last_goto_ts=$(date +%s)
          acquisition_state="acquiring"
          acquisition_streak=0
        fi
        top_drift_attempts=0
        top_drift_streak=0
        top_previous_drift=0
        # Set expected position from preset data.  is_externally_controlled()
        # compares these against the live /ptz/position (motor steps), so the
        # coordinate system matches directly — no ISP zoom scaling needed.
        if (( goto_skipped == 0 )); then
          IFS=$'\t' read -r expected_pan expected_tilt expected_zoom <<< "$(get_preset_ptz "$preset_positions" "$slot")"
          goto_retry_count=0
          own_event_since=0
          own_event_capped=0
          log "$cam_name" "info" "→ Slot $slot [HTTP $code]"
        fi
        last_commanded_slot=$slot
        status_slot=$slot
        cue_no_goto=0
        (( cue_in_progress == 0 )) || _patrol_status_tick cued
        ;;
      404)
        status_slot=""
        log "$cam_name" "error" "Preset slot $slot not found (HTTP 404) — advancing"
        if (( cue_in_progress == 0 )); then
          idx=$(( (idx + 1) % ${#presets[@]} ))
          step_repeated=0
        fi
        continue
        ;;
      "")
        status_slot=""
        log "$cam_name" "error" "No response from goto command — advancing"
        if (( cue_in_progress == 0 )); then
          idx=$(( (idx + 1) % ${#presets[@]} ))
          step_repeated=0
        fi
        continue
        ;;
      *)
        status_slot=""
        log "$cam_name" "warn" "Unexpected HTTP $code on goto slot $slot"
        (( cue_in_progress == 0 )) || continue
        ;;
    esac

    # Dwell at current preset, polling for PTZ drift and motion.
    # Uses adaptive poll_interval_s and the /ptz/position endpoint to detect
    # pan/tilt/zoom changes (manual control via the Protect app).
    local dwell_remaining=$slot_dwell
    local dwell_interrupted=0
    local dwell_activity_checked=0
    local dwell_unknown_seconds=0
    local dwell_drift_attempts=0 dwell_drift_streak=0 dwell_previous_drift=0
    local dwell_drift_attempt_limit=3
    while (( dwell_remaining > 0 )); do
      local poll_iv=$(( dwell_remaining < poll_interval_s ? dwell_remaining : poll_interval_s ))
      sleep "$poll_iv"
      dwell_remaining=$(( dwell_remaining - poll_iv ))

      # Single camera state fetch for tracking check (fail-safe: hold position).
      local cam_state=""
      if api_get_camera_state "$cam_id"; then
        cam_state="$_CACHED_CAM_STATE"
      else
        dwell_drift_attempts=0
        dwell_drift_streak=0
        dwell_previous_drift=0
        dwell_unknown_seconds=$(( dwell_unknown_seconds + poll_iv ))
        if (( dwell_unknown_seconds >= 300 )); then
          log "$cam_name" "warn" "Camera unreadable for $(( dwell_unknown_seconds / 60 ))m during dwell — holding position (no activity check succeeded)"
          _patrol_status_tick unreadable
          dwell_unknown_seconds=0
        fi
        _patrol_status_activity 1 0
        continue
      fi

      # Classify activity before the external-control check so the freshest live
      # tracking state can suppress drift detection without changing priority.
      local activity_active=0
      if is_tracking "$cam_id" "$motion_hold" "$last_goto_ts" "$settle_seconds" "$cam_state"; then
        activity_active=1
      fi
      _patrol_refresh_camera_name
      if (( _LAST_TRACKING_ACTIVE == 1 )); then
        expected_pan=-1; expected_tilt=-1; expected_zoom=-1
        acquisition_state="acquiring"
        acquisition_streak=0
      fi
      if (( _LAST_ACTIVITY_KNOWN == 1 )); then
        dwell_activity_checked=1
        dwell_unknown_seconds=0
      else
        dwell_unknown_seconds=$(( dwell_unknown_seconds + poll_iv ))
        if (( dwell_unknown_seconds >= 300 )); then
          log "$cam_name" "warn" "Camera unreadable for $(( dwell_unknown_seconds / 60 ))m during dwell — holding position (no activity check succeeded)"
          _patrol_status_tick unreadable
          dwell_unknown_seconds=0
        fi
      fi
      _patrol_status_activity "$activity_active" "$_LAST_ACTIVITY_KNOWN"

      # Check for external control during dwell (pan/tilt/zoom drift via /ptz/position).
      # Skip when live auto-tracking is enabled — the camera may have moved to track a
      # target, which is not external control.
      if (( _LAST_TRACKING_ACTIVE == 0 )); then
        local external_controlled=0
        is_externally_controlled "$cam_id" "$cam_name" "$settle_seconds" "$last_goto_ts" "$expected_pan" "$expected_tilt" "$expected_zoom" "$acquisition_state" "$acquisition_streak"
        external_controlled=$?
        acquisition_state="$_LAST_ACQUISITION_STATE"
        acquisition_streak=$_LAST_ACQUISITION_STREAK
        if (( _LAST_AT_HOMEVIEW == 1 )); then
          expected_pan=-1; expected_tilt=-1; expected_zoom=-1
          acquisition_state="none"
          acquisition_streak=0
        fi
        if (( external_controlled == 0 )); then
          if (( dwell_drift_streak > 0 && _LAST_DRIFT_MAGNITUDE * 4 >= dwell_previous_drift * 3 )); then
            external_control_until=$(( $(date +%s) + manual_hold ))
            hold_home_pan=${_LAST_HOME_PAN:--1}; hold_home_tilt=${_LAST_HOME_TILT:--1}; hold_home_zoom=${_LAST_HOME_ZOOM:--1}
            hold_home_streak=0
            acquisition_state="acquiring"
            acquisition_streak=0
            log "$cam_name" "info" "External control detected — holding patrol for ${manual_hold}s"
            _patrol_status_tick holding_manual
            dwell_drift_attempts=0
            dwell_drift_streak=0
            dwell_previous_drift=0
            dwell_interrupted=1
            break
          fi
          dwell_drift_attempts=$(( dwell_drift_attempts + 1 ))
          if (( dwell_drift_attempts >= dwell_drift_attempt_limit )); then
            log "$cam_name" "debug" "PTZ drift did not persist during dwell — continuing"
            dwell_drift_attempts=0
            dwell_drift_streak=0
            dwell_previous_drift=0
          elif (( dwell_drift_streak > 0 )); then
            dwell_drift_streak=0
            dwell_previous_drift=0
          else
            dwell_drift_streak=1
            dwell_previous_drift=$_LAST_DRIFT_MAGNITUDE
          fi
        elif (( _LAST_GOTO_FAILED == 1 )); then
          dwell_drift_attempts=0
          dwell_drift_streak=0
          dwell_previous_drift=0
          # After a hold, check the position again before any retry.
          if ! _patrol_hold_own_smart_event "$poll_interval_s"; then
            continue
          fi
          if _patrol_reissue_failed_goto "$cam_id" "$cam_name" "$slot" "$goto_retry_limit"; then
            continue
          fi
          break
        else
          dwell_drift_attempts=0
          dwell_drift_streak=0
          dwell_previous_drift=0
        fi
      else
        dwell_drift_attempts=0
        dwell_drift_streak=0
        dwell_previous_drift=0
      fi

      # Check for new motion/tracking during dwell (catches pan/tilt manual
      # control since motor movement triggers the motion sensor).
      # Pass last_goto_ts + settle_seconds so motor-induced motion is filtered.
      if (( activity_active )); then
        log "$cam_name" "info" "Activity during dwell — holding"
        dwell_interrupted=1
        break
      fi
      if (( _LAST_ACTIVITY_KNOWN == 1 && _LAST_TRACKING_ACTIVE == 0 && dwell_drift_attempts == 0 )) && [[ -n "$cue_query" ]]; then
        if _patrol_poll_cues; then break; fi
      fi
    done

    if (( dwell_activity_checked == 0 )); then
      log "$cam_name" "warn" "No successful activity checks during dwell — holding patrol"
      dwell_interrupted=1
    fi

    if (( dwell_interrupted || cue_in_progress )); then
      continue  # Skip advancing — go back to top of loop (hold/tracking checks)
    fi

    if (( cue_pending < 0 || step_repeated || (slot_dwell - dwell_remaining) * 2 >= slot_dwell )); then
      idx=$(( (idx + 1) % ${#presets[@]} ))
      step_repeated=0
    else
      step_repeated=1
    fi
    (( cue_pending < 0 )) || continue

    # Home between cycles: visit home position when cycle wraps back to first preset
    if [[ "$home_between_cycles" == "true" ]] && (( idx == 0 )); then
      settle_seconds=$camera_settle_seconds
      poll_interval_s=$camera_poll_interval_s
      if ! _patrol_home_dwell "$cam_id" "$cam_name" "$dwell" "$motion_hold" \
           "$settle_seconds" "$manual_hold" "$dyn_tracking" "$poll_interval_s"; then
        continue  # Interrupted — back to top for hold/tracking checks
      fi
    fi
  done
}
