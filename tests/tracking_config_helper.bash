#!/usr/bin/env bash

# shellcheck source=/dev/null
source "$BATS_TEST_DIRNAME/field_test_helper.bash"

api_patch() {
  printf '%s\n' "$@" >> "$BATS_TEST_TMPDIR/patch-args"
  printf '%s\n' "$2" >> "$BATS_TEST_TMPDIR/patch-bodies"
  printf '200'
}

tracking_config_probe() {
  export FIELD_DISCOVERY="{\"feature_vehicle_tracking\":${2:-false},\"presets\":[{\"slot\":0},{\"slot\":4}]}"
  field_probe "$1" 2
}

tracking_disable_probe() {
  set_auto_tracking cam-1 Overwatch '[]' disabled false
}

is_within_schedule() {
  [[ "${TRACKING_PAUSE:-0}" != "1" || "$FIELD_NOW" != "1000" ]]
}

tracking_resume_probe() {
  export TRACKING_PAUSE=1
  tracking_config_probe '{"dynamic_auto_tracking":true,"auto_tracking_object_types":["person","vehicle"],"auto_tracking_with_zoom":false}' true
}
