#!/bin/bash
# Sourced by other scripts — not run directly.
# Provides auth, API calls, config reading, PTZ position queries,
# tracking/motion detection, and retry logic.

SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
CONFIG_FILE="${CONFIG_FILE:-$SCRIPT_DIR/config.json}"

# --- Private globals (per-process after fork) ---
_COOKIE_TEMP=""
_HEADERS_TEMP=""
_BODY_TEMP=""
_TOKEN=""
_CSRF_TOKEN=""
_LAST_AUTH=0
_LAST_HTTP_CODE=0
_LAST_BODY=""
_CONSECUTIVE_FAILURES=0

# --- Cached config (populated by api_load_config) ---
_NVR_ADDRESS=""
_REAUTH_SECONDS=3600
_USERNAME=""
_PASSWORD=""
_LOG_LEVEL=2  # 0=error, 1=warn, 2=info (default), 3=debug

# ---------------------------------------------------------------------------
# Init / cleanup
# ---------------------------------------------------------------------------

api_init() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    log "api" "error" "FATAL: Config file not found: $CONFIG_FILE"
    return 1
  fi
  _COOKIE_TEMP=$(mktemp /tmp/ptz-patrol-cookie-XXXXXX)
  _HEADERS_TEMP=$(mktemp /tmp/ptz-patrol-headers-XXXXXX)
  _BODY_TEMP=$(mktemp /tmp/ptz-patrol-body-XXXXXX)
  trap 'api_cleanup' EXIT
  api_load_config
}

api_cleanup() {
  rm -f "$_COOKIE_TEMP" "$_HEADERS_TEMP" "$_BODY_TEMP"
  local pids
  pids=$(jobs -p)
  # shellcheck disable=SC2086  # Intentional word-split: $pids is space-separated PID list
  [[ -n "$pids" ]] && kill $pids 2>/dev/null || true
}

api_load_config() {
  _NVR_ADDRESS=$(cfg '.nvr_address')
  _REAUTH_SECONDS=$(cfg '.reauth_seconds // 3600')
  _USERNAME=$(cfg '.username')
  _PASSWORD=$(cfg '.password')

  # Log level: error=0, warn=1, info=2 (default), debug=3
  local level_name; level_name=$(cfg '.log_level // "info"')
  _LOG_LEVEL=$(_log_level_num "$level_name")

  # Validate required fields (jq -r turns missing values into "null")
  if [[ -z "$_NVR_ADDRESS" || "$_NVR_ADDRESS" == "null" ]]; then
    log "api" "error" "FATAL: nvr_address not set in $CONFIG_FILE"
    return 1
  fi
  if [[ -z "$_USERNAME" || "$_USERNAME" == "null" ]]; then
    log "api" "error" "FATAL: username not set in $CONFIG_FILE"
    return 1
  fi
  if [[ -z "$_PASSWORD" || "$_PASSWORD" == "null" ]]; then
    log "api" "error" "FATAL: password not set in $CONFIG_FILE"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

cfg() {
  jq -r "$1" "$CONFIG_FILE"
}

# Log level constants for numeric comparison
_LOG_NUM_ERROR=0
_LOG_NUM_WARN=1
_LOG_NUM_INFO=2
_LOG_NUM_DEBUG=3

# Convert log level name to number
_log_level_num() {
  case "$1" in
    error) echo 0 ;; warn) echo 1 ;; info) echo 2 ;; debug) echo 3 ;;
    *) echo 2 ;;
  esac
}

# Usage: log <tag> <message>            → defaults to info level
#        log <tag> <level> <message>     → explicit level
# Levels: error, warn, info, debug
log() {
  local tag=$1 level msg
  if [[ $# -ge 3 ]]; then
    level=$2; msg=$3
  else
    level="info"; msg=$2
  fi

  local level_num
  case "$level" in
    error) level_num=0 ;; warn) level_num=1 ;; info) level_num=2 ;; debug) level_num=3 ;;
    *) level_num=2 ;;
  esac

  (( level_num > _LOG_LEVEL )) && return 0

  local level_tag
  level_tag=$(echo "$level" | tr '[:lower:]' '[:upper:]')

  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level_tag] [$tag] $msg"
}

# ---------------------------------------------------------------------------
# Auth
# ---------------------------------------------------------------------------

api_auth() {
  local response
  response=$(curl -k --connect-timeout 3 --max-time 10 -D "$_HEADERS_TEMP" -c "$_COOKIE_TEMP" -s -X POST \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg u "$_USERNAME" --arg p "$_PASSWORD" \
      '{username:$u, password:$p, rememberMe:true, token:""}')" \
    "$_NVR_ADDRESS/api/auth/login")

  _TOKEN=$(echo "$response" | jq -r '.deviceToken // empty')
  _CSRF_TOKEN=$(grep -i 'x-csrf-token:' "$_HEADERS_TEMP" | awk '{print $2}' | tr -d '\r')

  if [[ -z "$_TOKEN" ]]; then
    log "api" "error" "Auth failed"
    return 1
  fi
  _LAST_AUTH=$(date +%s)
  _CONSECUTIVE_FAILURES=0
  log "api" "info" "Authenticated"
}

# Retry auth up to N times with backoff (for cold start / NVR rebooting)
api_auth_with_retry() {
  local max_attempts=${1:-5}
  local delay=${2:-10}
  local attempt
  for (( attempt = 1; attempt <= max_attempts; attempt++ )); do
    api_auth && return 0
    log "api" "warn" "Auth attempt $attempt/$max_attempts failed — retrying in ${delay}s"
    sleep "$delay"
    delay=$(( delay * 2 > 60 ? 60 : delay * 2 ))
  done
  log "api" "error" "All $max_attempts auth attempts failed"
  return 1
}

api_ensure_auth() {
  local now; now=$(date +%s)
  if (( now - _LAST_AUTH >= _REAUTH_SECONDS )); then
    api_auth
  fi
}

# ---------------------------------------------------------------------------
# HTTP with retry
# ---------------------------------------------------------------------------

# Sets _LAST_HTTP_CODE and _LAST_BODY as side-effects.
# Reuses a persistent temp file (_BODY_TEMP) for the response body — no
# mktemp/rm per call, no leak risk if interrupted.
api_get() {
  # -o writes response body to file; -w prints HTTP code to stdout
  _LAST_HTTP_CODE=$(curl -k --connect-timeout 3 --max-time 10 -s -b "$_COOKIE_TEMP" \
    --header "TOKEN: $_TOKEN" \
    --header "X-CSRF-Token: $_CSRF_TOKEN" \
    -w '%{http_code}' -o "$_BODY_TEMP" \
    "$_NVR_ADDRESS/proxy/protect/api$1")

  _LAST_HTTP_CODE="${_LAST_HTTP_CODE:-000}"
  _LAST_BODY=$(<"$_BODY_TEMP")
}

api_post() {
  curl -k --connect-timeout 3 --max-time 10 -s -o /dev/null -w "%{http_code}" -X POST \
    "$_NVR_ADDRESS/proxy/protect/api$1" \
    --header "TOKEN: $_TOKEN" \
    --header "X-CSRF-Token: $_CSRF_TOKEN" \
    -b "$_COOKIE_TEMP"
}

api_patch() {
  local url=$1 data=$2
  curl -k --connect-timeout 3 --max-time 10 -s -o /dev/null -w "%{http_code}" -X PATCH \
    "$_NVR_ADDRESS/proxy/protect/api$url" \
    --header "TOKEN: $_TOKEN" \
    --header "X-CSRF-Token: $_CSRF_TOKEN" \
    --header "Content-Type: application/json" \
    -b "$_COOKIE_TEMP" \
    -d "$data"
}

# GET with retry: echoes body on success and returns 0; returns 1 on failure.
# Detects 401/403 and re-authenticates automatically.
# Uses _LAST_BODY / _LAST_HTTP_CODE globals set by api_get() — no subshell.
api_get_with_retry() {
  local url=$1
  local max_retries=${2:-3}
  local delay=${3:-5}
  local attempt

  for (( attempt = 1; attempt <= max_retries; attempt++ )); do
    api_get "$url"

    case "$_LAST_HTTP_CODE" in
      200)
        # Validate we got valid JSON
        if printf '%s' "$_LAST_BODY" | jq -e '.' >/dev/null 2>&1; then
          _CONSECUTIVE_FAILURES=0
          printf '%s' "$_LAST_BODY"
          return 0
        fi
        log "api" "warn" "GET $url returned 200 but invalid JSON (attempt $attempt/$max_retries)"
        ;;
      401|403)
        log "api" "warn" "Auth error on GET $url (HTTP $_LAST_HTTP_CODE) — re-authenticating"
        api_auth
        ;;
      *)
        log "api" "debug" "GET $url returned HTTP $_LAST_HTTP_CODE (attempt $attempt/$max_retries)"
        api_ensure_auth
        ;;
    esac
    sleep "$delay"
  done

  _CONSECUTIVE_FAILURES=$(( _CONSECUTIVE_FAILURES + 1 ))
  return 1
}

# POST with retry: returns HTTP status code
api_post_with_retry() {
  local url=$1
  local max_retries=${2:-3}
  local delay=${3:-5}
  local attempt code

  for (( attempt = 1; attempt <= max_retries; attempt++ )); do
    code=$(api_post "$url")
    _LAST_HTTP_CODE="$code"
    case "$code" in
      200|204)
        _CONSECUTIVE_FAILURES=0
        echo "$code"
        return 0
        ;;
      401|403)
        log "api" "warn" "Auth error on POST $url (HTTP $code) — re-authenticating"
        api_auth
        ;;
      *)
        log "api" "debug" "POST $url returned HTTP $code (attempt $attempt/$max_retries)"
        ;;
    esac
    sleep "$delay"
  done

  _CONSECUTIVE_FAILURES=$(( _CONSECUTIVE_FAILURES + 1 ))
  echo "$code"
  return 1
}

# Compute backoff delay based on consecutive failure count
api_backoff_delay() {
  local base=${1:-5}
  local max=${2:-120}
  local delay=$(( base * (2 ** (_CONSECUTIVE_FAILURES < 6 ? _CONSECUTIVE_FAILURES : 6)) ))
  (( delay > max )) && delay=$max
  echo "$delay"
}

# ---------------------------------------------------------------------------
# Camera state fetch (shared between tracking and zoom checks)
# ---------------------------------------------------------------------------

# Fetch full camera state JSON once per poll cycle.  Returns 0 on success,
# 1 on failure.  The raw JSON is stored in the global _CACHED_CAM_STATE so
# parse_* helpers and is_tracking can consume it without a second
# HTTP round-trip.
_CACHED_CAM_STATE=""

api_get_camera_state() {
  local cam_id=$1
  _CACHED_CAM_STATE=""
  if ! api_get_with_retry "/cameras/$cam_id" 2 3 >/dev/null; then
    return 1
  fi
  _CACHED_CAM_STATE="$_LAST_BODY"
  return 0
}

# ---------------------------------------------------------------------------
# Tracking / motion detection
# ---------------------------------------------------------------------------

# Returns 0 (true) if camera appears to be tracking or has recent activity.
# Extracts all needed fields in a single jq call to minimise process spawning
# on resource-constrained UniFi hardware.
#
# Arguments:
#   $1  cam_id
#   $2  motion_hold          — seconds to extend detection after lastMotion
#   $3  last_goto_ts         — (optional) epoch when we last sent a goto command
#   $4  settle_seconds       — (optional) settle window after goto
#   $5  pre_fetched_state    — (optional) JSON from api_get_camera_state()
#
# When last_goto_ts and settle_seconds are provided, lastMotion timestamps
# that fall within the settle window after our goto are ignored — the motor
# movement itself triggers the motion sensor, which is not real activity.
#
# Side-effect: sets _LAST_SMART_ACTIVE=1 if smart detection (AI) is active,
#              0 otherwise. Used by dynamic auto-tracking to avoid a second API call.
#              Sets _LAST_TRACKING_ACTIVE to the live auto-tracking state, or 1
#              when the response is unknown so callers preserve the fail-safe.
#              Sets _LAST_ACTIVITY_KNOWN=1 only for a valid CONNECTED response.
_LAST_SMART_ACTIVE=0
_LAST_TRACKING_ACTIVE=1
_LAST_ACTIVITY_KNOWN=0

is_tracking() {
  local cam_id=$1 motion_hold=$2
  local last_goto_ts=${3:-0}
  local settle_seconds=${4:-0}
  local state=${5:-}
  _LAST_SMART_ACTIVE=0
  _LAST_TRACKING_ACTIVE=1
  _LAST_ACTIVITY_KNOWN=0

  if [[ -z "$state" ]]; then
    if ! api_get_with_retry "/cameras/$cam_id" 2 3 >/dev/null; then
      log "$cam_id" "warn" "Failed to fetch camera state — assuming active (fail-safe)"
      return 0
    fi
    state="$_LAST_BODY"
  fi

  # Extract all needed fields in one jq invocation (6→1 process spawn)
  local fields
  fields=$(echo "$state" | jq -r '[
    (if (.id // "") == "" then "0" else "1" end),
    (.state // "UNKNOWN"),
    (.isAutoTracking // .isPtzAutoTracking // .isTracking // false),
    (.isSmartDetected // false),
    (.isMotionDetected // false),
    (.lastMotion // 0)
  ] | @tsv' 2>/dev/null) || {
    log "$cam_id" "warn" "Invalid camera state response — assuming active (fail-safe)"
    return 0
  }

  local response_id_present cam_state tracking smart_detected motion_detected last_motion
  IFS=$'\t' read -r response_id_present cam_state tracking smart_detected motion_detected last_motion <<< "$fields"

  # An absent id makes the response unusable even when jq supplied defaults.
  if [[ "$response_id_present" != "1" ]]; then
    log "$cam_id" "warn" "Invalid camera state response — assuming active (fail-safe)"
    return 0
  fi

  # Check camera is still connected
  if [[ "$cam_state" != "CONNECTED" ]]; then
    log "$cam_id" "warn" "Camera state=$cam_state — treating as active"
    return 0
  fi
  _LAST_ACTIVITY_KNOWN=1

  # Explicit tracking flag (firmware-dependent, may not exist)
  if [[ "$tracking" == "true" ]]; then
    _LAST_TRACKING_ACTIVE=1
    _LAST_SMART_ACTIVE=1
    return 0
  fi
  _LAST_TRACKING_ACTIVE=0

  # Real-time smart detection boolean (person/vehicle/animal detected now)
  if [[ "$smart_detected" == "true" ]]; then
    _LAST_SMART_ACTIVE=1
    return 0
  fi

  # Capture time once for both motion checks below (avoid redundant date spawns).
  local now_s; now_s=$(date +%s)

  # Real-time motion boolean — but ignore if we're still within the settle
  # window after our own goto (motor movement triggers the sensor).
  if [[ "$motion_detected" == "true" ]]; then
    if (( last_goto_ts > 0 && now_s - last_goto_ts < settle_seconds )); then
      log "$cam_id" "debug" "Ignoring isMotionDetected during settle window (motor-induced)"
    else
      return 0
    fi
  fi

  # Fallback: lastMotion timestamp for hold window tail.
  # Skip if lastMotion falls within the settle window after our last goto —
  # the motor physically moving to a preset triggers the motion sensor and
  # updates lastMotion. Without this filter, motion_hold > dwell causes a
  # permanent hold loop because every goto refreshes lastMotion.
  local now_ms=$(( now_s * 1000 ))
  local hold_ms=$(( motion_hold * 1000 ))
  if (( now_ms - last_motion < hold_ms )); then
    # Check if this lastMotion event is just our own motor movement
    if (( last_goto_ts > 0 )); then
      local goto_ms=$(( last_goto_ts * 1000 ))
      local settle_ms=$(( settle_seconds * 1000 ))
      if (( last_motion >= goto_ms && last_motion <= goto_ms + settle_ms )); then
        # lastMotion is within [goto, goto+settle] — motor-induced, ignore
        return 1
      fi
    fi
    return 0
  fi

  return 1
}

# ---------------------------------------------------------------------------
# PTZ position queries (for manual control detection)
# ---------------------------------------------------------------------------

# Get preset positions: returns JSON array [{slot, pan, tilt, zoom}, ...]
api_get_preset_positions() {
  local cam_id=$1
  local raw
  if ! api_get_with_retry "/cameras/$cam_id/ptz/preset" 2 3 >/dev/null; then
    echo "[]"
    return
  fi
  raw="$_LAST_BODY"
  echo "$raw" | jq '[.[] | {slot: .slot, name: .name, pan: .ptz.pan, tilt: .ptz.tilt, zoom: .ptz.zoom}]' 2>/dev/null || echo "[]"
}

# Get live PTZ position (pan/tilt/zoom in steps) from the /ptz/position endpoint.
# Echoes a tab-separated line: pan_steps tilt_steps zoom_steps
# Echoes "-1 -1 -1" on failure.
api_get_ptz_position() {
  local cam_id=$1
  local raw
  if ! api_get_with_retry "/cameras/$cam_id/ptz/position" 2 3 >/dev/null; then
    printf '%s\t%s\t%s\n' -1 -1 -1
    return
  fi
  raw="$_LAST_BODY"
  local fields
  fields=$(echo "$raw" | jq -r '[.steps.pan // -1, .steps.tilt // -1, .steps.zoom // -1] | @tsv' 2>/dev/null) || { echo "-1	-1	-1"; return; }
  echo "$fields"
}

# Get the expected pan/tilt/zoom (in steps) for a preset slot from cached preset JSON.
# Echoes tab-separated: pan tilt zoom.  Echoes "-1 -1 -1" if slot not found.
get_preset_ptz() {
  local preset_json=$1
  local slot=$2
  local fields
  fields=$(echo "$preset_json" | jq -r --argjson s "$slot" \
    '.[] | select(.slot == $s) | [(.pan // -1), (.tilt // -1), (.zoom // -1)] | @tsv' 2>/dev/null)
  echo "${fields:--1	-1	-1}"
}


