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
# Strategy: compare the live PTZ position (pan/tilt/zoom in motor steps from
# the /ptz/position endpoint) against the preset's expected position.  Any
# axis drifting beyond a threshold while outside the settle window → external.
#
# Arguments:
#   $1  cam_id
#   $2  cam_name
#   $3  settle_seconds
#   $4  last_goto_ts
#   $5  expected_pan   (steps, -1 = unknown)
#   $6  expected_tilt  (steps, -1 = unknown)
#   $7  expected_zoom  (steps, -1 = unknown)
#   $8  previous_pan   (steps, -1 = unavailable)
#   $9  previous_tilt  (steps, -1 = unavailable)
#   $10 previous_zoom  (steps, -1 = unavailable)
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
  local previous_pan=${8:--1}
  local previous_tilt=${9:--1}
  local previous_zoom=${10:--1}
  _LAST_DRIFT_MAGNITUDE=0
  _LAST_GOTO_FAILED=0

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

  if (( expected_pan >= 0 )); then
    pan_diff=$(( live_pan - expected_pan ))
    pan_diff=${pan_diff#-}
    (( pan_diff > drift_magnitude )) && drift_magnitude=$pan_diff
    (( pan_diff > pan_thresh )) && drifted+="pan(${expected_pan}→${live_pan}) "
  fi
  if (( expected_tilt >= 0 )); then
    tilt_diff=$(( live_tilt - expected_tilt ))
    tilt_diff=${tilt_diff#-}
    (( tilt_diff > drift_magnitude )) && drift_magnitude=$tilt_diff
    (( tilt_diff > tilt_thresh )) && drifted+="tilt(${expected_tilt}→${live_tilt}) "
  fi
  if (( expected_zoom >= 0 )); then
    zoom_diff=$(( live_zoom - expected_zoom ))
    zoom_diff=${zoom_diff#-}
    (( zoom_diff > drift_magnitude )) && drift_magnitude=$zoom_diff
    (( zoom_diff > zoom_thresh )) && drifted+="zoom(${expected_zoom}→${live_zoom}) "
  fi

  _LAST_DRIFT_MAGNITUDE=$drift_magnitude

  log "$cam_name" "debug" "PTZ check: pan=${live_pan}/${expected_pan} tilt=${live_tilt}/${expected_tilt} zoom=${live_zoom}/${expected_zoom}"

  if [[ -n "$drifted" ]]; then
    # A live position matching the prior target means the accepted goto did
    # not move the camera. Preset coordinates are unavailable during home
    # dwell, so all three previous axes must be known before classifying this.
    if (( previous_pan >= 0 && previous_tilt >= 0 && previous_zoom >= 0 )); then
      local previous_pan_diff=$(( live_pan - previous_pan ))
      local previous_tilt_diff=$(( live_tilt - previous_tilt ))
      local previous_zoom_diff=$(( live_zoom - previous_zoom ))
      previous_pan_diff=${previous_pan_diff#-}
      previous_tilt_diff=${previous_tilt_diff#-}
      previous_zoom_diff=${previous_zoom_diff#-}
      if (( previous_pan_diff <= pan_thresh &&
            previous_tilt_diff <= tilt_thresh &&
            previous_zoom_diff <= zoom_thresh )); then
        _LAST_GOTO_FAILED=1
        log "$cam_name" "warn" "Goto did not take effect — live position matches previous commanded preset"
        return 1
      fi
    fi
    log "$cam_name" "info" "PTZ drift detected: ${drifted}"
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

# Re-issue a goto that was accepted while the camera stayed at the previous
# preset. The retry count is caller-scoped so the patrol can advance after the
# bounded limit instead of entering a hold loop.
_patrol_reissue_failed_goto() {
  local cam_id=$1
  local cam_name=$2
  local slot=$3
  local retry_limit=$4

  if (( goto_retry_count >= retry_limit )); then
    log "$cam_name" "warn" "Goto slot $slot still has not taken effect after ${retry_limit} retries — advancing patrol"
    expected_pan=-1; expected_tilt=-1; expected_zoom=-1
    previous_pan=-1; previous_tilt=-1; previous_zoom=-1
    expected_is_preset=0
    last_commanded_slot=-1
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

# Check if the current time falls within a patrol schedule window.
# Arguments: schedule_start schedule_end schedule_days_json
#   schedule_start/end: "HH:MM" strings (24h). Empty = no schedule (always active).
#   schedule_days_json: JSON array of 3-letter day names, e.g. '["mon","tue","wed"]'
#                       Empty or "null" = all days.
# Returns 0 if patrol should be active, 1 if outside the schedule window.
#
# Day-of-week handling for overnight windows:
#   For "22:00-06:00" on ["mon","tue","wed","thu","fri"]:
#   - Friday 23:00 → check Friday (today) → in list → active
#   - Saturday 01:00 → in early-morning tail, check Friday (yesterday) → in list → active
#   - Saturday 23:00 → check Saturday (today) → not in list → inactive
is_within_schedule() {
  local sched_start=$1 sched_end=$2 sched_days=$3

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
# Arguments: cam_id cam_name types_json action_label
#   types_json: '["person"]' to enable, '[]' to disable
#   action_label: "enabled" or "disabled" (for logging)
set_auto_tracking() {
  local cam_id=$1 cam_name=$2 types_json=$3 action_label=$4
  api_ensure_auth
  local code
  code=$(api_patch "/cameras/$cam_id" \
    "{\"smartDetectSettings\":{\"autoTrackingObjectTypes\":$types_json}}") || true
  if [[ "$code" == "200" ]]; then
    log "$cam_name" "info" "Auto-tracking $action_label ($types_json)"
    return 0
  else
    log "$cam_name" "warn" "Failed to set auto-tracking (HTTP ${code:-timeout})"
    return 1
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
#   previous_pan previous_tilt previous_zoom expected_is_preset
#   tracking_enabled external_control_until
#
# Returns 0 if dwell completed normally, 1 if interrupted (caller should
# continue back to the top of the main patrol loop).
_patrol_home_dwell() {
  local cam_id=$1 cam_name=$2 dwell=$3 motion_hold=$4 settle_seconds=$5
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
  previous_pan=-1; previous_tilt=-1; previous_zoom=-1
  expected_is_preset=0
  last_commanded_slot=-1
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
        home_unknown_seconds=0
      fi
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
    if (( _LAST_ACTIVITY_KNOWN == 1 )); then
      home_activity_checked=1
      home_unknown_seconds=0
    else
      home_unknown_seconds=$(( home_unknown_seconds + hbc_poll ))
      if (( home_unknown_seconds >= 300 )); then
        log "$cam_name" "warn" "Camera unreadable for $(( home_unknown_seconds / 60 ))m during home dwell — holding position (no activity check succeeded)"
        home_unknown_seconds=0
      fi
    fi

    # Check for external control (pan/tilt/zoom drift).
    # Skip when live auto-tracking is enabled — the camera may have moved to track.
    if (( home_sampled == 1 && home_baseline_ready == 0 && _LAST_TRACKING_ACTIVE == 0 )); then
      if is_externally_controlled "$cam_id" "$cam_name" "$settle_seconds" "$last_goto_ts" "$expected_pan" "$expected_tilt" "$expected_zoom" "$previous_pan" "$previous_tilt" "$previous_zoom"; then
        # Retain at least 75% of the previous drift. A ratio handles pan/tilt
        # and zoom's different motor-step scales while rejecting convergence.
        if (( home_drift_streak > 0 && _LAST_DRIFT_MAGNITUDE * 4 >= home_previous_drift * 3 )); then
          external_control_until=$(( $(date +%s) + manual_hold ))
          log "$cam_name" "info" "External control detected during home dwell — holding patrol for ${manual_hold}s"
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
patrol_camera() {
  local cam_id=$1 cam_name=$2
  # Optional: pre-fetched camera JSON from discovery (3rd arg)
  local cam_discovery_json=${3:-}

  local cam_config
  cam_config=$(get_camera_config "$cam_id")

  local enabled
  enabled=$(echo "$cam_config" | jq -r '.enabled // true')
  if [[ "$enabled" == "false" ]]; then
    log "$cam_name" "info" "Disabled — skipping"
    return
  fi

  local dwell motion_hold max_wait manual_hold settle_seconds
  dwell=$(echo "$cam_config" | jq -r '.dwell_seconds // 30')
  motion_hold=$(echo "$cam_config" | jq -r '.motion_hold_seconds // 15')
  max_wait=$(echo "$cam_config" | jq -r '.max_tracking_wait // 300')
  manual_hold=$(echo "$cam_config" | jq -r '.manual_control_hold_seconds // 120')
  settle_seconds=$(echo "$cam_config" | jq -r '.ptz_settle_seconds // 10')

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

  # Schedule: optional time window for when patrol should be active
  local sched_start sched_end sched_days sched_home
  sched_start=$(echo "$cam_config" | jq -r '.schedule.start // empty')
  sched_end=$(echo "$cam_config" | jq -r '.schedule.end // empty')
  sched_days=$(echo "$cam_config" | jq -c '.schedule.days // null')
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

  if (( ${#presets[@]} < 2 )); then
    log "$cam_name" "warn" "Only ${#presets[@]} preset(s) — need 2+. Skipping."
    return 2  # Permanent condition — caller should not retry frequently
  fi

  # Cache preset positions (pan/tilt/zoom in motor steps) for drift detection.
  # This JSON array is used by get_preset_ptz() to look up expected positions.
  local preset_positions
  preset_positions=$(api_get_preset_positions "$cam_id")

  local sched_info=""
  if [[ -n "$sched_start" && -n "$sched_end" ]]; then
    sched_info=" schedule=${sched_start}-${sched_end}"
    if [[ -n "$sched_days" && "$sched_days" != "null" ]]; then
      local days_str; days_str=$(echo "$sched_days" | jq -r 'join(",")')
      sched_info+=" days=${days_str}"
    fi
    sched_info+=" home_on_pause=${sched_home}"
  fi
  local dyn_info=""
  if [[ "$dyn_tracking" == "true" ]]; then
    dyn_info=" dynamic_tracking=on"
  fi
  local home_cycle_info=""
  if [[ "$home_between_cycles" == "true" ]]; then
    home_cycle_info=" home_between_cycles=on"
  fi
  log "$cam_name" "info" "Patrol: presets=[${presets[*]}] dwell=${dwell}s settle=${settle_seconds}s poll=${poll_interval_s}s hold=${motion_hold}s max_wait=${max_wait}s manual_hold=${manual_hold}s${sched_info}${dyn_info}${home_cycle_info}"

  local idx=0
  local last_goto_ts=0
  local expected_pan=-1
  local expected_tilt=-1
  local expected_zoom=-1
  local previous_pan=-1
  local previous_tilt=-1
  local previous_zoom=-1
  local expected_is_preset=0
  local last_commanded_slot=-1
  local goto_retry_count=0
  local goto_retry_limit=2
  local external_control_until=0
  local schedule_paused=0
  local tracking_enabled=0
  local unknown_hold_seconds=0
  local top_drift_attempts=0 top_drift_streak=0 top_previous_drift=0
  local top_drift_attempt_limit=3
  local startup_settle_pending=1

  # Enable auto-tracking once at patrol start (stays on permanently).
  # Only disabled on schedule pause and shutdown.
  if [[ "$dyn_tracking" == "true" ]]; then
    if set_auto_tracking "$cam_id" "$cam_name" '["person"]' "enabled"; then
      tracking_enabled=1
    fi
  fi

  while true; do
    api_ensure_auth

    # --- Schedule check ---
    if ! is_within_schedule "$sched_start" "$sched_end" "$sched_days"; then
      if (( schedule_paused == 0 )); then
        log "$cam_name" "info" "Outside schedule window (${sched_start}-${sched_end}) — pausing patrol"
        if [[ "$sched_home" == "true" ]]; then
          local home_code
          api_post_with_retry "/cameras/$cam_id/ptz/goto/-1" 2 3 >/dev/null || true
          home_code="$_LAST_HTTP_CODE"
          if [[ "$home_code" == "200" || "$home_code" == "204" ]]; then
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
      fi
      sleep 60
      continue
    fi
    if (( schedule_paused == 1 )); then
      log "$cam_name" "info" "Schedule window active (${sched_start}-${sched_end}) — resuming patrol"
      schedule_paused=0
      expected_pan=-1; expected_tilt=-1; expected_zoom=-1
      # Re-enable auto-tracking after schedule pause
      if [[ "$dyn_tracking" == "true" ]] && (( tracking_enabled == 0 )); then
        if set_auto_tracking "$cam_id" "$cam_name" '["person"]' "enabled"; then
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
    if (( now < external_control_until )); then
      local remaining=$(( external_control_until - now ))
      log "$cam_name" "debug" "Manual control hold — ${remaining}s remaining"
      sleep 5
      continue
    elif (( external_control_until > 0 )); then
      # Hold just expired — reset expected position so we don't immediately
      # re-trigger drift detection against the stale pre-hold values
      expected_pan=-1; expected_tilt=-1; expected_zoom=-1
      external_control_until=0
      top_drift_attempts=0
      top_drift_streak=0
      top_previous_drift=0
      log "$cam_name" "info" "Manual control hold expired — resuming patrol"
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
        unknown_hold_seconds=0
      fi
      sleep 5
      continue
    fi

    # Classify activity before the external-control check so the freshest live
    # tracking state can suppress drift detection without changing priority.
    local activity_active=0
    if is_tracking "$cam_id" "$motion_hold" "$last_goto_ts" "$settle_seconds" "$top_state"; then
      activity_active=1
    fi
    if (( _LAST_ACTIVITY_KNOWN == 1 )); then
      unknown_hold_seconds=0
    fi

    if (( _LAST_TRACKING_ACTIVE == 0 )); then
      if is_externally_controlled "$cam_id" "$cam_name" "$settle_seconds" "$last_goto_ts" "$expected_pan" "$expected_tilt" "$expected_zoom" "$previous_pan" "$previous_tilt" "$previous_zoom"; then
        if (( top_drift_streak > 0 && _LAST_DRIFT_MAGNITUDE * 4 >= top_previous_drift * 3 )); then
          external_control_until=$(( $(date +%s) + manual_hold ))
          log "$cam_name" "info" "External control detected — holding patrol for ${manual_hold}s"
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
        if (( last_commanded_slot >= 0 )); then
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
    # First iteration uses the already-fetched top_state; subsequent iterations
    # fetch fresh state since the camera may have moved during the sleep.
    while (( activity_active )); do
      top_state=""  # Clear so subsequent iterations fetch fresh state
      if (( waited == 0 )); then
        log "$cam_name" "info" "Tracking/motion active — holding"
      fi
      sleep 5
      waited=$((waited + 5))
      api_ensure_auth
      if is_tracking "$cam_id" "$motion_hold" "$last_goto_ts" "$settle_seconds" "$top_state"; then
        activity_active=1
      else
        activity_active=0
      fi
      if (( _LAST_ACTIVITY_KNOWN == 0 )); then
        unknown_hold_seconds=$(( unknown_hold_seconds + 5 ))
        if (( unknown_hold_seconds >= 300 )); then
          log "$cam_name" "warn" "Camera unreadable for $(( unknown_hold_seconds / 60 ))m — holding position (no activity check succeeded)"
          unknown_hold_seconds=0
        fi
      else
        unknown_hold_seconds=0
      fi
      if (( activity_active && _LAST_ACTIVITY_KNOWN == 1 && waited >= max_wait )); then
        log "$cam_name" "warn" "Max wait (${max_wait}s) hit — advancing anyway"
        break
      fi
    done
    # Dynamic auto-tracking: tracking may have moved the camera, so reset
    # expected position and advance to next preset (don't snap back).
    if [[ "$dyn_tracking" == "true" ]] && (( tracking_enabled == 1 && waited > 0 )); then
      expected_pan=-1; expected_tilt=-1; expected_zoom=-1
      # Advance to next preset — tracking served as the dwell for this one,
      # so don't snap back to the same position the camera just tracked away from
      idx=$(( (idx + 1) % ${#presets[@]} ))
      # Home between cycles: visit home position when cycle wraps
      if [[ "$home_between_cycles" == "true" ]] && (( idx == 0 )); then
        if ! _patrol_home_dwell "$cam_id" "$cam_name" "$dwell" "$motion_hold" \
             "$settle_seconds" "$manual_hold" "$dyn_tracking" "$poll_interval_s"; then
          continue  # Interrupted — back to top for hold/tracking checks
        fi
      fi
      slot="${presets[$idx]}"
    fi
    if (( waited > 0 && waited < max_wait )); then
      log "$cam_name" "debug" "Clear after ${waited}s — resuming"
    fi

    # --- Move to next preset ---
    if (( startup_settle_pending == 1 )); then
      _patrol_wait_for_camera_settle "$cam_id" "$cam_name" 30 || true
      startup_settle_pending=0
    fi
    local code
    api_post_with_retry "/cameras/$cam_id/ptz/goto/$slot" 2 3 >/dev/null || true
    code="$_LAST_HTTP_CODE"

    case "$code" in
      200|204)
        last_goto_ts=$(date +%s)
        top_drift_attempts=0
        top_drift_streak=0
        top_previous_drift=0
        # Preserve the prior preset before replacing the current expectation.
        # Home baselines are explicitly excluded from failed-goto matching.
        if (( expected_is_preset == 1 )); then
          previous_pan=$expected_pan
          previous_tilt=$expected_tilt
          previous_zoom=$expected_zoom
        else
          previous_pan=-1; previous_tilt=-1; previous_zoom=-1
        fi
        # Set expected position from preset data.  is_externally_controlled()
        # compares these against the live /ptz/position (motor steps), so the
        # coordinate system matches directly — no ISP zoom scaling needed.
        IFS=$'\t' read -r expected_pan expected_tilt expected_zoom <<< "$(get_preset_ptz "$preset_positions" "$slot")"
        expected_is_preset=1
        last_commanded_slot=$slot
        goto_retry_count=0
        log "$cam_name" "info" "→ Slot $slot [HTTP $code]"
        ;;
      404)
        log "$cam_name" "error" "Preset slot $slot not found (HTTP 404) — advancing"
        idx=$(( (idx + 1) % ${#presets[@]} ))
        continue
        ;;
      "")
        log "$cam_name" "error" "No response from goto command — advancing"
        idx=$(( (idx + 1) % ${#presets[@]} ))
        continue
        ;;
      *)
        log "$cam_name" "warn" "Unexpected HTTP $code on goto slot $slot"
        ;;
    esac

    # Dwell at current preset, polling for PTZ drift and motion.
    # Uses adaptive poll_interval_s and the /ptz/position endpoint to detect
    # pan/tilt/zoom changes (manual control via the Protect app).
    local dwell_remaining=$dwell
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
          dwell_unknown_seconds=0
        fi
        continue
      fi

      # Classify activity before the external-control check so the freshest live
      # tracking state can suppress drift detection without changing priority.
      local activity_active=0
      if is_tracking "$cam_id" "$motion_hold" "$last_goto_ts" "$settle_seconds" "$cam_state"; then
        activity_active=1
      fi
      if (( _LAST_ACTIVITY_KNOWN == 1 )); then
        dwell_activity_checked=1
        dwell_unknown_seconds=0
      else
        dwell_unknown_seconds=$(( dwell_unknown_seconds + poll_iv ))
        if (( dwell_unknown_seconds >= 300 )); then
          log "$cam_name" "warn" "Camera unreadable for $(( dwell_unknown_seconds / 60 ))m during dwell — holding position (no activity check succeeded)"
          dwell_unknown_seconds=0
        fi
      fi

      # Check for external control during dwell (pan/tilt/zoom drift via /ptz/position).
      # Skip when live auto-tracking is enabled — the camera may have moved to track a
      # target, which is not external control.
      if (( _LAST_TRACKING_ACTIVE == 0 )); then
        if is_externally_controlled "$cam_id" "$cam_name" "$settle_seconds" "$last_goto_ts" "$expected_pan" "$expected_tilt" "$expected_zoom" "$previous_pan" "$previous_tilt" "$previous_zoom"; then
          if (( dwell_drift_streak > 0 && _LAST_DRIFT_MAGNITUDE * 4 >= dwell_previous_drift * 3 )); then
            external_control_until=$(( $(date +%s) + manual_hold ))
            log "$cam_name" "info" "External control detected — holding patrol for ${manual_hold}s"
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
    done

    if (( dwell_activity_checked == 0 )); then
      log "$cam_name" "warn" "No successful activity checks during dwell — holding patrol"
      dwell_interrupted=1
    fi

    if (( dwell_interrupted )); then
      continue  # Skip advancing — go back to top of loop (hold/tracking checks)
    fi

    idx=$(( (idx + 1) % ${#presets[@]} ))

    # Home between cycles: visit home position when cycle wraps back to first preset
    if [[ "$home_between_cycles" == "true" ]] && (( idx == 0 )); then
      if ! _patrol_home_dwell "$cam_id" "$cam_name" "$dwell" "$motion_hold" \
           "$settle_seconds" "$manual_hold" "$dyn_tracking" "$poll_interval_s"; then
        continue  # Interrupted — back to top for hold/tracking checks
      fi
    fi
  done
}
