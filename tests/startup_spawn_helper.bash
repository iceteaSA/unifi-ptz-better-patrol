#!/usr/bin/env bash

# shellcheck source=/dev/null
source "$BATS_TEST_DIRNAME/field_test_helper.bash"

STARTUP_JQ_FILE=""

jq() {
  printf 'jq\n' >> "$STARTUP_JQ_FILE"
  command jq "$@"
}

api_ensure_auth() {
  local -a calls=()
  mapfile -t calls < "$STARTUP_JQ_FILE"
  printf '__startup_jq=%s\n' "${#calls[@]}"
  exit 0
}

startup_spawn_probe() {
  STARTUP_JQ_FILE="$BATS_TEST_TMPDIR/startup-jq"
  printf '' > "$STARTUP_JQ_FILE"
  field_probe '{"dynamic_auto_tracking":false,"auto_tracking_object_types":[],"status_heartbeat_seconds":29}' 2
}
