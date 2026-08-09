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

  if (( live_pan < 0 )); then
    # Failed to read — fail-safe, don't flag as external
    return 1
  fi

  # Compare each axis.  Thresholds in motor steps:
  #   pan:  200 steps (~1-2 degrees, depends on model)
  #   tilt: 200 steps
  #   zoom: 30  steps (~3% of 0-1000 range)
  local pan_thresh=200 tilt_thresh=200 zoom_thresh=30
  local pan_diff=0 tilt_diff=0 zoom_diff=0
  local drifted=""

  if (( expected_pan >= 0 )); then
    pan_diff=$(( live_pan - expected_pan ))
    pan_diff=${pan_diff#-}
    (( pan_diff > pan_thresh )) && drifted+="pan(${expected_pan}→${live_pan}) "
  fi
  if (( expected_tilt >= 0 )); then
    tilt_diff=$(( live_tilt - expected_tilt ))
    tilt_diff=${tilt_diff#-}
    (( tilt_diff > tilt_thresh )) && drifted+="tilt(${expected_tilt}→${live_tilt}) "
  fi
  if (( expected_zoom >= 0 )); then
    zoom_diff=$(( live_zoom - expected_zoom ))
    zoom_diff=${zoom_diff#-}
    (( zoom_diff > zoom_thresh )) && drifted+="zoom(${expected_zoom}→${live_zoom}) "
  fi

  log "$cam_name" "debug" "PTZ check: pan=${live_pan}/${expected_pan} tilt=${live_tilt}/${expected_tilt} zoom=${live_zoom}/${expected_zoom}"

  if [[ -n "$drifted" ]]; then
    log "$cam_name" "info" "PTZ drift detected: ${drifted}"
    return 0
  fi

  return 1
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
#   last_goto_ts  expected_pan  expected_tilt  expected_zoom
#   tracking_enabled  external_control_until
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
  # Home position has no preset data — sample live position after settle
  expected_pan=-1; expected_tilt=-1; expected_zoom=-1
  local home_sampled=0

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
      continue
    fi

    # Sample live position once after settle (home has no preset data)
    local now
    now=$(date +%s)
    if (( home_sampled == 0 && now - last_goto_ts >= settle_seconds )); then
      IFS=$'\t' read -r expected_pan expected_tilt expected_zoom <<< "$(api_get_ptz_position "$cam_id")"
      home_sampled=1
    fi

    # Check for external control (pan/tilt/zoom drift).
    # Skip when auto-tracking is enabled — the camera may have moved to track.
    if (( tracking_enabled == 0 )); then
      if is_externally_controlled "$cam_id" "$cam_name" "$settle_seconds" "$last_goto_ts" "$expected_pan" "$expected_tilt" "$expected_zoom"; then
        external_control_until=$(( $(date +%s) + manual_hold ))
        log "$cam_name" "info" "External control detected during home dwell — holding patrol for ${manual_hold}s"
        return 1
      fi
    fi

    # Check for motion/tracking (with motor-induced motion filtering)
    if is_tracking "$cam_id" "$motion_hold" "$last_goto_ts" "$settle_seconds" "$cam_state"; then
      log "$cam_name" "info" "Activity during home dwell — holding"
      return 1
    fi
  done

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
  local external_control_until=0
  local schedule_paused=0
  local tracking_enabled=0

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
          home_code=$(api_post_with_retry "/cameras/$cam_id/ptz/goto/-1" 2 3) || true
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
      log "$cam_name" "info" "Manual control hold expired — resuming patrol"
    fi

    # Single API fetch for top-of-loop tracking check.
    # On failure, sleep and retry next iteration (fail-safe: hold position).
    local top_state=""
    if api_get_camera_state "$cam_id"; then
      top_state="$_CACHED_CAM_STATE"
    else
      sleep 5
      continue
    fi

    if is_externally_controlled "$cam_id" "$cam_name" "$settle_seconds" "$last_goto_ts" "$expected_pan" "$expected_tilt" "$expected_zoom"; then
      external_control_until=$(( $(date +%s) + manual_hold ))
      log "$cam_name" "info" "External control detected — holding patrol for ${manual_hold}s"
      sleep 5
      continue
    fi

    # --- Hold while tracking/motion is active ---
    local slot="${presets[$idx]}"
    local waited=0
    # First iteration uses the already-fetched top_state; subsequent iterations
    # fetch fresh state since the camera may have moved during the sleep.
    while is_tracking "$cam_id" "$motion_hold" "$last_goto_ts" "$settle_seconds" "$top_state"; do
      top_state=""  # Clear so subsequent iterations fetch fresh state
      if (( waited == 0 )); then
        log "$cam_name" "info" "Tracking/motion active — holding"
      fi
      sleep 5
      waited=$((waited + 5))
      api_ensure_auth
      if (( waited >= max_wait )); then
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
    local code
    api_post_with_retry "/cameras/$cam_id/ptz/goto/$slot" 2 3 >/dev/null || true
    code="$_LAST_HTTP_CODE"

    case "$code" in
      200|204)
        last_goto_ts=$(date +%s)
        # Set expected position from preset data.  is_externally_controlled()
        # compares these against the live /ptz/position (motor steps), so the
        # coordinate system matches directly — no ISP zoom scaling needed.
        IFS=$'\t' read -r expected_pan expected_tilt expected_zoom <<< "$(get_preset_ptz "$preset_positions" "$slot")"
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
    while (( dwell_remaining > 0 )); do
      local poll_iv=$(( dwell_remaining < poll_interval_s ? dwell_remaining : poll_interval_s ))
      sleep "$poll_iv"
      dwell_remaining=$(( dwell_remaining - poll_iv ))

      # Single camera state fetch for tracking check (fail-safe: hold position).
      local cam_state=""
      if api_get_camera_state "$cam_id"; then
        cam_state="$_CACHED_CAM_STATE"
      else
        continue
      fi

      # Check for external control during dwell (pan/tilt/zoom drift via /ptz/position).
      # Skip when auto-tracking is enabled — the camera may have moved to track a
      # target, which is not external control.  is_tracking() will catch the activity.
      if (( tracking_enabled == 0 )); then
        if is_externally_controlled "$cam_id" "$cam_name" "$settle_seconds" "$last_goto_ts" "$expected_pan" "$expected_tilt" "$expected_zoom"; then
          external_control_until=$(( $(date +%s) + manual_hold ))
          log "$cam_name" "info" "External control detected — holding patrol for ${manual_hold}s"
          dwell_interrupted=1
          break
        fi
      fi

      # Check for new motion/tracking during dwell (catches pan/tilt manual
      # control since motor movement triggers the motion sensor).
      # Pass last_goto_ts + settle_seconds so motor-induced motion is filtered.
      if is_tracking "$cam_id" "$motion_hold" "$last_goto_ts" "$settle_seconds" "$cam_state"; then
        log "$cam_name" "info" "Activity during dwell — holding"
        dwell_interrupted=1
        break
      fi
    done

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
