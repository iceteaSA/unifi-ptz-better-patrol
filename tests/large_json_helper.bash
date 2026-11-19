#!/usr/bin/env bash

# shellcheck source=/dev/null
source "$BATS_TEST_DIRNAME/cue_test_helper.bash"
# shellcheck source=/dev/null
source "$BATS_TEST_DIRNAME/../discover.sh"

LARGE_CAMERAS=""
LARGE_PRESETS=""
LARGE_CONFIG=""

large_prepare() {
  LARGE_CAMERAS=$(command jq -nc '[range(20) | {id:("cam"+tostring),name:("Camera "+tostring),state:"CONNECTED",type:"PTZ",featureFlags:{isPtz:true},padding:("x"*11000),smartDetectZones:[{id:2,name:"Trail"}]}]')
  LARGE_PRESETS=$(command jq -nc '[range(80) | {slot:.,name:("x"*3000),ptz:{pan:100,tilt:200,zoom:30}}]')
  LARGE_CONFIG=$(command jq -nc '{defaults:{dwell_seconds:30},camera_overrides:{cam0:{dwell_seconds:42,padding:("x"*220000)}}}')
  printf '__sizes=%s/%s/%s\n' "${#LARGE_CAMERAS}" "${#LARGE_PRESETS}" "${#LARGE_CONFIG}"
}

api_get_with_retry() {
  case "$1" in
    /cameras) printf '%s' "$LARGE_CAMERAS" ;;
    */ptz/preset) printf '%s' "$LARGE_PRESETS" ;;
    *) return 1 ;;
  esac
}

large_probe() {
  local mode=$1 body
  large_prepare
  case "$mode" in
    cli)
      local sandbox="$BATS_TEST_TMPDIR/discover-cli"
      mkdir -p "$sandbox"
      cp "$BATS_TEST_DIRNAME/../discover.sh" "$sandbox/discover.sh"
      cp "$BATS_TEST_DIRNAME/fixtures/large-discover-api" "$sandbox/api.sh"
      local -x LARGE_CAMERAS_FILE="$sandbox/cameras.json" LARGE_CONFIG_FILE="$sandbox/config-test.json"
      LARGE_CAMERAS=$(command jq -c '.[].featureFlags.isPtz=false | .[].type="Fixed" | .[0].featureFlags.isPtz=true | .[0].type="PTZ"' <<< "$LARGE_CAMERAS")
      printf '%s' "$LARGE_CAMERAS" > "$LARGE_CAMERAS_FILE"
      printf '%s' '{"defaults":{"cues":[{"camera_id":"cam1","slot":4,"zones":[2]}]},"camera_overrides":{}}' > "$LARGE_CONFIG_FILE"
      SCRIPT_DIR="$sandbox" bash "$sandbox/discover.sh"
      ;;
    cues)
      discover_cue_lines '{"cues":[{"camera_id":"cam0","slot":4,"zones":[2]}]}' "$LARGE_CAMERAS"
      ;;
    discovery)
      LARGE_CAMERAS=$(command jq -c '.[0:1]' <<< "$LARGE_CAMERAS")
      body=$(discover_ptz_cameras) || return
      command jq -er '.[0] | select(.id=="cam0" and .preset_count==80 and .presets[79].slot==79) | "__discovered=80"' <<< "$body"
      ;;
    camera)
      LARGE_CAMERAS=$(command jq -nc '[{id:"cam0",name:("x"*220000),state:"CONNECTED",type:"PTZ"}]')
      LARGE_PRESETS='[]'
      body=$(discover_ptz_cameras) || return
      command jq -er '.[0] | select((.name | length)==220000 and .preset_count==0) | "__camera=220000"' <<< "$body"
      ;;
    groups)
      body=$(command jq -nc '[range(3000) | {id:("cam"+tostring),name:("x"*80),is_ptz:true}]')
      body=$(discover_duplicate_names "$body") || return
      [[ "$body" == cam0$'\n'* && "$body" == *$'\n'cam2999 ]] || return 1
      printf '__duplicates=3000\n'
      ;;
    overrides)
      cfg() { command jq -r "$1" <<< "$LARGE_CONFIG"; }
      body=$(get_camera_config cam0) || return
      command jq -er 'select(.dwell_seconds==42 and (.padding|length)==220000) | "__merged=42"' <<< "$body"
      ;;
    positions|patrol-discovery)
      local -x cam_id=cam1 cam_name=Overwatch cam_config='{"cues":[{"camera_id":"fixed1","slot":79}]}'
      local preset_positions='[]' cam_discovery_json='{}'
      local -a presets=(0 79) cue_camera_ids=() cue_slots=() cue_types=() cue_holds=() cue_cooldowns=() cue_names=() cue_until=() cue_zones=()
      local cue_query=""
      if [[ "$mode" == positions ]]; then
        preset_positions=$LARGE_PRESETS
      else
        cam_discovery_json=$(command jq -nc '{presets:[{slot:79}],padding:("x"*220000)}')
      fi
      _patrol_parse_cues
      printf '__entries=%s slot=%s\n' "${#cue_slots[@]}" "${cue_slots[0]:-none}"
      ;;
  esac
}
