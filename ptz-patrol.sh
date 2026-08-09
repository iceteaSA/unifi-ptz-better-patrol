#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/api.sh"
source "$SCRIPT_DIR/patrol.sh"

# ---------------------------------------------------------------------------
# Graceful shutdown
# ---------------------------------------------------------------------------

_CHILD_PIDS=()
_CAMERA_IDS=()
_DYN_TRACKING_IDS=()
declare -A _PID_TO_CAMERA=()   # Maps PID → camera_id (for pruning dead cameras)
_SHUTTING_DOWN=0

shutdown() {
  # Guard against re-entrancy (EXIT fires again after exit 0)
  (( _SHUTTING_DOWN )) && return
  _SHUTTING_DOWN=1

  log "main" "info" "Shutdown requested — stopping all patrols"
  for pid in "${_CHILD_PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  wait 2>/dev/null || true

  if [[ ${#_CAMERA_IDS[@]} -gt 0 ]]; then
    api_ensure_auth || true

    # Disable dynamic auto-tracking on cameras that had it enabled
    if [[ ${#_DYN_TRACKING_IDS[@]} -gt 0 ]]; then
      log "main" "info" "Disabling dynamic auto-tracking..."
      for cam_id in "${_DYN_TRACKING_IDS[@]}"; do
        api_patch "/cameras/$cam_id" '{"smartDetectSettings":{"autoTrackingObjectTypes":[]}}' >/dev/null 2>&1 || true
      done
    fi

    # Optionally send cameras home on shutdown
    local home_on_shutdown
    home_on_shutdown=$(cfg '.defaults.home_on_shutdown // false') || home_on_shutdown=false
    if [[ "$home_on_shutdown" == "true" ]]; then
      log "main" "info" "Sending cameras to home position..."
      for cam_id in "${_CAMERA_IDS[@]}"; do
        api_post "/cameras/$cam_id/ptz/goto/-1" >/dev/null 2>&1 || true
      done
    fi
  fi

  log "main" "info" "Shutdown complete"
  api_cleanup
  exit 0
}

# ---------------------------------------------------------------------------
# Main: init, discover, launch
# ---------------------------------------------------------------------------

api_init

# Set traps AFTER api_init (which sets its own EXIT trap for cleanup).
# This overrides api_cleanup on EXIT so shutdown() handles everything.
trap shutdown SIGTERM SIGINT EXIT

# Auth with retry (NVR may still be booting after firmware update)
if ! api_auth_with_retry 5 10; then
  log "main" "error" "Could not authenticate with NVR — exiting"
  exit 1
fi

auto_discover=$(cfg '.auto_discover // true')
if [[ "$auto_discover" != "true" ]]; then
  log "main" "error" "auto_discover is disabled — enable it in config.json to use patrol"
  exit 1
fi

log "main" "info" "Discovering PTZ cameras..."
discovery_attempts=0
discovery_max=10
discovery_delay=15
cameras="[]"
count=0

while (( count == 0 && discovery_attempts < discovery_max )); do
  discovery_attempts=$(( discovery_attempts + 1 ))
  cameras=$(discover_ptz_cameras) || cameras="[]"
  count=$(echo "$cameras" | jq 'length' 2>/dev/null) || count=0

  if (( count == 0 )); then
    if (( discovery_attempts >= discovery_max )); then
      log "main" "error" "No PTZ cameras found after $discovery_max attempts — exiting"
      exit 1
    fi
    log "main" "warn" "No PTZ cameras found (attempt $discovery_attempts/$discovery_max) — retrying in ${discovery_delay}s"
    sleep "$discovery_delay"
  fi
done

log "main" "info" "Found $count PTZ camera(s) — launching patrol loops"

# ---------------------------------------------------------------------------
# Per-camera setup & launch (used by initial discovery and re-discovery)
# ---------------------------------------------------------------------------

# Set up a single camera and launch its patrol subprocess.
# Skips cameras that are already being patrolled or disabled in config.
# Arguments: cameras_json index
#   cameras_json: full JSON array from discover_ptz_cameras()
#   index:        0-based index into that array
launch_patrol_for_camera() {
  local cameras_json=$1
  local idx=$2

  local cam_id; cam_id=$(echo "$cameras_json" | jq -r ".[$idx].id")
  local cam_name; cam_name=$(echo "$cameras_json" | jq -r ".[$idx].name")
  local cam_json; cam_json=$(echo "$cameras_json" | jq -c ".[$idx]")

  # Already patrolling this camera — skip
  local existing
  for existing in "${_CAMERA_IDS[@]}"; do
    if [[ "$existing" == "$cam_id" ]]; then
      return 0
    fi
  done

  # Skip cameras disabled in config
  local cam_config; cam_config=$(get_camera_config "$cam_id")
  local enabled; enabled=$(echo "$cam_config" | jq -r '.enabled // true')
  if [[ "$enabled" == "false" ]]; then
    log "main" "info" "$cam_name: disabled in config — skipping"
    return 0
  fi

  _CAMERA_IDS+=("$cam_id")

  # --- Auto-setup: disable conflicting Protect settings ---

  # Disable return-to-home if enabled (interferes with patrol positioning)
  local return_home_ms; return_home_ms=$(echo "$cam_json" | jq -r '.return_home_ms // "null"')
  if [[ "$return_home_ms" != "null" ]]; then
    local setup_code
    setup_code=$(api_patch "/cameras/$cam_id" '{"ptz":{"returnHomeAfterInactivityMs":null}}') || true
    if [[ "$setup_code" == "200" ]]; then
      log "main" "info" "$cam_name: disabled auto return-to-home (was ${return_home_ms}ms)"
    else
      log "main" "warn" "$cam_name: failed to disable auto return-to-home (HTTP ${setup_code:-timeout})"
    fi
  fi

  # Stop active built-in patrol if running (conflicts with our patrol)
  local active_patrol; active_patrol=$(echo "$cam_json" | jq -r '.active_patrol_slot // "null"')
  if [[ "$active_patrol" != "null" ]]; then
    local setup_code
    setup_code=$(api_post "/cameras/$cam_id/ptz/patrol/stop") || true
    if [[ "$setup_code" == "200" || "$setup_code" == "204" ]]; then
      log "main" "info" "$cam_name: stopped built-in patrol (was slot $active_patrol)"
    else
      log "main" "warn" "$cam_name: failed to stop built-in patrol (HTTP ${setup_code:-timeout})"
    fi
  fi

  # Disable auto-tracking on startup if dynamic tracking is configured
  # (it will be re-enabled dynamically when smart detections occur)
  local dyn_tracking; dyn_tracking=$(echo "$cam_config" | jq -r '.dynamic_auto_tracking // false')
  if [[ "$dyn_tracking" == "true" ]]; then
    _DYN_TRACKING_IDS+=("$cam_id")
    local current_types; current_types=$(echo "$cam_json" | jq -c '.auto_tracking_types // []')
    if [[ "$current_types" != "[]" ]]; then
      local setup_code
      setup_code=$(api_patch "/cameras/$cam_id" '{"smartDetectSettings":{"autoTrackingObjectTypes":[]}}') || true
      if [[ "$setup_code" == "200" ]]; then
        log "main" "info" "$cam_name: disabled auto-tracking for dynamic mode (was $current_types)"
      else
        log "main" "warn" "$cam_name: failed to disable auto-tracking (HTTP ${setup_code:-timeout})"
      fi
    fi
  fi

  # Each camera gets its own subshell with independent auth and temp files.
  # The restart wrapper ensures a single API error doesn't permanently kill
  # a camera's patrol — it just restarts after a delay.
  (
    # Fresh init for this subprocess (own cookie jar, own auth token)
    api_init
    api_auth_with_retry 5 10 || {
      log "$cam_name" "error" "Could not authenticate — patrol not started"
      exit 1
    }

    while true; do
      rc=0
      patrol_camera "$cam_id" "$cam_name" "$cam_json" || rc=$?

      if (( rc == 2 )); then
        # Permanent condition (e.g. no presets) — retry infrequently
        log "$cam_name" "warn" "No presets — will re-check in 5 minutes"
        sleep 300
        cam_json=""  # Clear stale discovery data so next call fetches fresh presets
      else
        log "$cam_name" "warn" "Patrol loop exited — restarting in 10s"
        sleep 10
      fi
      api_ensure_auth
    done
  ) &
  _CHILD_PIDS+=("$!")
  _PID_TO_CAMERA[$!]="$cam_id"
  log "main" "info" "$cam_name: patrol launched (PID $!)"
}

# ---------------------------------------------------------------------------
# Initial discovery & launch
# ---------------------------------------------------------------------------

for (( i = 0; i < count; i++ )); do
  launch_patrol_for_camera "$cameras" "$i"
done

# ---------------------------------------------------------------------------
# Re-discovery loop: detect new cameras without requiring a service restart
# ---------------------------------------------------------------------------

rediscovery_interval=$(cfg '.rediscovery_interval_seconds // 600')

if (( rediscovery_interval > 0 )); then
  log "main" "info" "Re-discovery enabled (every ${rediscovery_interval}s)"

  while true; do
    sleep "$rediscovery_interval"

    # Prune dead child PIDs, reap zombies, and remove their camera IDs
    # so re-discovery can relaunch them
    _LIVE_PIDS=()
    for pid in "${_CHILD_PIDS[@]}"; do
      if kill -0 "$pid" 2>/dev/null; then
        _LIVE_PIDS+=("$pid")
      else
        wait "$pid" 2>/dev/null || true  # reap zombie
        # Remove the dead camera from _CAMERA_IDS so it can be relaunched
        dead_cam="${_PID_TO_CAMERA[$pid]:-}"
        if [[ -n "$dead_cam" ]]; then
          _KEEP_CAMS=()
          for cid in "${_CAMERA_IDS[@]}"; do
            [[ "$cid" != "$dead_cam" ]] && _KEEP_CAMS+=("$cid")
          done
          _CAMERA_IDS=("${_KEEP_CAMS[@]}")
          unset "_PID_TO_CAMERA[$pid]"
          log "main" "warn" "Camera $dead_cam subprocess (PID $pid) exited — will relaunch on next discovery"
        fi
      fi
    done
    _CHILD_PIDS=("${_LIVE_PIDS[@]}")

    api_ensure_auth

    log "main" "debug" "Re-discovering PTZ cameras..."
    new_cameras=$(discover_ptz_cameras) || continue
    new_count=$(echo "$new_cameras" | jq 'length')

    for (( i = 0; i < new_count; i++ )); do
      launch_patrol_for_camera "$new_cameras" "$i"
    done
  done
else
  # No re-discovery — just wait for children (shutdown trap handles SIGTERM)
  wait
fi
