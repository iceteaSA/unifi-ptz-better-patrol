#!/bin/bash
# Can be sourced for functions or run directly for discovery output.

SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
source "$SCRIPT_DIR/api.sh"

# Returns JSON array of PTZ cameras with their presets and position data.
# Presets are fetched from the per-camera /ptz/preset endpoint because
# ptzPresetPositions on the camera object is empty on many firmware versions.
discover_ptz_cameras() {
  local all_cameras
  all_cameras=$(api_get_with_retry "/cameras" 3 5) || { echo "[]"; return 1; }

  # First pass: extract connected PTZ cameras (no presets yet)
  local ptz_cameras
  ptz_cameras=$(printf '%s' "$all_cameras" | jq '
    [.[] | select(
      .state == "CONNECTED" and (
        (.featureFlags.isPtz // false) or
        (.featureFlags.canPtz // false) or
        (.type | test("PTZ"; "i"))
      )
    ) | {
      id,
      name,
      type,
      state,
      is_ptz: (.featureFlags.isPtz // false),
      zoom_position: (.ispSettings.zoomPosition // -1),
      is_person_tracking: (
        .smartDetectSettings.autoTrackingObjectTypes // [] | map(select(. == "person")) | length > 0
      ),
      auto_tracking_types: (.smartDetectSettings.autoTrackingObjectTypes // []),
      active_patrol_slot: (.activePatrolSlot // null),
      return_home_ms: (.ptz.returnHomeAfterInactivityMs // null)
    }]
  ')

  local count
  count=$(printf '%s' "$ptz_cameras" | jq 'length')

  # Second pass: fetch presets per camera via the /ptz/preset endpoint
  local i cam_id presets result="[]"
  for (( i = 0; i < count; i++ )); do
    cam_id=$(printf '%s' "$ptz_cameras" | jq -r ".[$i].id")
    presets=$(api_get_with_retry "/cameras/$cam_id/ptz/preset" 2 3 2>/dev/null) || presets="[]"
    # Normalize preset fields
    presets=$(printf '%s' "$presets" | jq '[. // [] | sort_by(.slot) | .[] | {slot, name, ptz: {pan: .ptz.pan, tilt: .ptz.tilt, zoom: .ptz.zoom}}]' 2>/dev/null) || presets="[]"

    # Merge presets into the camera object
    result=$(printf '%s' "$result" | jq --argjson cam "$(printf '%s' "$ptz_cameras" | jq ".[$i]")" \
      --argjson presets "$presets" \
      '. + [$cam + {presets: $presets, preset_count: ($presets | length)}]')
  done

  printf '%s' "$result"
}

# Resolve per-camera settings: override > defaults
get_camera_config() {
  local cam_id=$1
  local overrides
  overrides=$(cfg ".camera_overrides[\"$cam_id\"] // {}")

  local defaults
  defaults=$(cfg '.defaults')

  # Merge: overrides win over defaults
  echo "$defaults" | jq --argjson o "$overrides" '. * $o'
}

# === Main (only when run directly, not sourced) ===
[[ "${BASH_SOURCE[0]}" != "$0" ]] && return 0

set -euo pipefail
api_init
api_auth

echo "=== Discovering PTZ cameras ==="
cameras=$(discover_ptz_cameras)
count=$(echo "$cameras" | jq 'length')

if (( count == 0 )); then
  echo "No PTZ cameras found."
  exit 0
fi

echo "Found $count PTZ camera(s):"
echo "$cameras" | jq -r '.[] |
  "\n  \(.name)",
  "  Model:            \(.type)",
  "  ID:               \(.id)",
  "  PTZ (firmware):   \(.is_ptz)",
  "  Person tracking:  \(.is_person_tracking)",
  "  Current zoom:     \(.zoom_position)%",
  "  Presets:          \(.preset_count)",
  (.presets[] | "    Slot \(.slot): \(.name // "(unnamed)")  [pan=\(.ptz.pan // "?") tilt=\(.ptz.tilt // "?") zoom=\(.ptz.zoom // "?")]")
'

echo ""
echo "=== Effective config per camera ==="
for (( i = 0; i < count; i++ )); do
  cam_id=$(echo "$cameras" | jq -r ".[$i].id")
  cam_name=$(echo "$cameras" | jq -r ".[$i].name")
  cam_config=$(get_camera_config "$cam_id")
  enabled=$(echo "$cam_config" | jq -r 'if .enabled == null then true else .enabled end')

  echo ""
  echo "  $cam_name ($cam_id)"
  echo "    enabled:                    $enabled"
  echo "    dwell_seconds:              $(echo "$cam_config" | jq -r '.dwell_seconds // 30')"
  echo "    motion_hold:                $(echo "$cam_config" | jq -r '.motion_hold_seconds // 15')s"
  echo "    max_tracking_wait:          $(echo "$cam_config" | jq -r '.max_tracking_wait // 300')s"
  echo "    manual_control_hold:        $(echo "$cam_config" | jq -r '.manual_control_hold_seconds // 120')s"
  echo "    ptz_settle:                 $(echo "$cam_config" | jq -r '.ptz_settle_seconds // 10')s"
  override_slots=$(echo "$cam_config" | jq -r '.preset_slots // empty')
  if [[ -n "$override_slots" ]]; then
    echo "    preset_slots:               $override_slots (override)"
  else
    echo "    preset_slots:               all discovered"
  fi
done

echo ""
echo "=== Full camera dump (for debugging tracking fields) ==="
echo "Run this to inspect raw fields on a specific camera:"
echo ""
echo "  source $SCRIPT_DIR/api.sh && api_init && api_auth"
echo "  api_get_with_retry /cameras/YOUR_CAM_ID | jq 'keys'"
echo "  api_get_with_retry /cameras/YOUR_CAM_ID | jq '{isAutoTracking, isPtzAutoTracking, isTracking, lastMotion, lastSmartDetect, ispSettings: {zoomPosition: .ispSettings.zoomPosition}, featureFlags: {isPtz: .featureFlags.isPtz}}'"
