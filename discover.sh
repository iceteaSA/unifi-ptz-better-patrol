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
      auto_tracking_with_zoom: .smartDetectSettings.autoTrackingWithZoom,
      feature_ptz: .featureFlags.isPtz,
      feature_liveview_tracking: .featureFlags.hasLiveviewTracking,
      feature_vehicle_tracking: .featureFlags.supportPtzVehicleTracking,
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

# Print ids of discovered PTZ cameras whose names are shared by another PTZ camera.
discover_duplicate_names() {
  jq -r '[.[] | select(.is_ptz == true or (.type | test("PTZ"; "i")))] as $cams | [$cams[].name] | group_by(.) | map(select(length > 1)) | flatten as $names | $cams[] | select(.name as $n | $names | index($n)) | .id' <<< "$1"
}

# Print duplicate-name groups for one warning per shared name.
discover_duplicate_name_groups() {
  jq -c '[.[] | select(.is_ptz == true or (.type | test("PTZ"; "i"))) | {name, id}] | group_by(.name) | map(select(length > 1))' <<< "$1"
}

# Format current tracking state and advertised support from discovery JSON.
discover_tracking_lines() {
  jq -r '.[] |
    "  Auto-tracking now: \(if ((.auto_tracking_types // .smartDetectSettings.autoTrackingObjectTypes // []) | length) == 0 then "off" else ((.auto_tracking_types // .smartDetectSettings.autoTrackingObjectTypes) | join(", ")) end)",
    "  Tracking support: \(if (.feature_ptz // .featureFlags.isPtz) == null or (.feature_liveview_tracking // .featureFlags.hasLiveviewTracking) == null then "unknown" elif (.feature_ptz // .featureFlags.isPtz) and (.feature_liveview_tracking // .featureFlags.hasLiveviewTracking) then (["person"] + (if (.feature_vehicle_tracking // .featureFlags.supportPtzVehicleTracking) then ["vehicle"] else [] end) | join(", ")) else "unknown" end)",
    "  Tracking with zoom: \(if (if .auto_tracking_with_zoom == null then .smartDetectSettings.autoTrackingWithZoom else .auto_tracking_with_zoom end) == null then "unknown" elif (if .auto_tracking_with_zoom == null then .smartDetectSettings.autoTrackingWithZoom else .auto_tracking_with_zoom end) then "on" else "off" end)"
  ' <<< "$1"
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

# Read installed version metadata without spawning external processes.
get_install_version() {
  local version=unknown ref=unknown commit=unknown key value
  if [[ -r "$SCRIPT_DIR/VERSION" ]]; then
    IFS= read -r version < "$SCRIPT_DIR/VERSION" || true
    [[ -n "$version" ]] || version=unknown
  fi
  if [[ -r "$SCRIPT_DIR/install-info" ]]; then
    while IFS='=' read -r key value; do
      case "$key" in
        ref) [[ -n "$value" ]] && ref=$value ;;
        commit) [[ -n "$value" ]] && commit=$value ;;
      esac
    done < "$SCRIPT_DIR/install-info"
  fi
  printf '%s (%s@%s)\n' "$version" "$ref" "${commit:0:7}"
}

# === Main (only when run directly, not sourced) ===
[[ "${BASH_SOURCE[0]}" != "$0" ]] && return 0

set -euo pipefail
api_init
api_auth

echo "=== Discovering PTZ cameras — ptz-patrol $(get_install_version) ==="
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
  "  Current zoom:     \(.zoom_position)%",
  "  Presets:          \(.preset_count)",
  (.presets[] | "    Slot \(.slot): \(.name // "(unnamed)")  [pan=\(.ptz.pan // "?") tilt=\(.ptz.tilt // "?") zoom=\(.ptz.zoom // "?")]")
'
discover_tracking_lines "$cameras"

echo ""
echo "=== Effective config per camera ==="
for (( i = 0; i < count; i++ )); do
  cam_id=$(echo "$cameras" | jq -r ".[$i].id")
  cam_name=$(echo "$cameras" | jq -r ".[$i].name")
  cam_config=$(get_camera_config "$cam_id")
  # jq's // treats false as missing, so `.enabled // true` cannot read false.
  enabled=$(echo "$cam_config" | jq -r 'if .enabled == null then true else .enabled end')

  echo ""
  echo "  $cam_name ($cam_id)"
  echo "    enabled:                    $enabled"
  echo "    dwell_seconds:              $(echo "$cam_config" | jq -r '.dwell_seconds // 30')"
  echo "    preset_dwell_seconds:       $(echo "$cam_config" | jq -r '.preset_dwell_seconds // "none"')"
  echo "    path_mode:                  $(echo "$cam_config" | jq -r '.path_mode // "loop"')"
  echo "    auto_tracking_object_types: $(echo "$cam_config" | jq -c 'if .auto_tracking_object_types == null then ["person"] else .auto_tracking_object_types end')"
  echo "    auto_tracking_with_zoom:    $(echo "$cam_config" | jq -r 'if .auto_tracking_with_zoom == null then "camera setting" else .auto_tracking_with_zoom end')"
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
