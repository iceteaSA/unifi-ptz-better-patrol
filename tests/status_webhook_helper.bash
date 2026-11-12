#!/usr/bin/env bash

# shellcheck source=/dev/null
source "$BATS_TEST_DIRNAME/field_test_helper.bash"

STATUS_CONFIG='{}'
STATUS_DELAY=0
STATUS_END_TIME=1400

cfg() { jq -r "$1" <<< "$STATUS_CONFIG"; }

printf() {
  if [[ "${1:-}" == "-v" && "${3:-}" == '%(%s)T' ]]; then
    builtin printf -v "$2" '%s' "$FIELD_NOW"
  else
    # shellcheck disable=SC2059 # The wrapper must keep the caller's printf format.
    builtin printf "$@"
  fi
}

curl() {
  local payload="" previous="" argument config
  printf '%s\n' "$@" > "$BATS_TEST_TMPDIR/curl-$BASHPID.args"
  for argument in "$@"; do
    [[ "$previous" != "--data-binary" ]] || payload=$argument
    previous=$argument
  done
  IFS= read -r config
  printf '%s\n' "$config" > "$BATS_TEST_TMPDIR/curl-$BASHPID.stdin"
  printf '%s\n' "$payload" > "$BATS_TEST_TMPDIR/post-$BASHPID.json"
  command sleep "$STATUS_DELAY"
  printf 'done\n' > "$BATS_TEST_TMPDIR/done-$BASHPID"
}

status_initialize() {
  STATUS_CONFIG=$1
  _STATUS_WEBHOOK_LOADED=0
  api_load_status_webhook
  api_load_status_webhook
}

status_sequence_probe() {
  local -x cam_id=cam-1 cam_name=${STATUS_CAMERA_NAME:-Overwatch}
  local -x status_state="" status_since=0 status_last_post=0 status_slot=""
  local -x status_heartbeat_seconds=${STATUS_HEARTBEAT:-300} status_version='1.2.0 (main@test)'
  status_initialize "$1"
  shift
  local event state now
  for event in "$@"; do
    IFS=: read -r state now status_slot <<< "$event"
    _patrol_status_tick "$state" "$now"
    wait
  done
}

status_payloads() {
  local -a files=("$BATS_TEST_TMPDIR"/post-*.json)
  if [[ -e "${files[0]}" ]]; then
    jq -sc 'sort_by(.ts, .camera_id)' "${files[@]}"
  else
    printf '[]\n'
  fi
}

status_curl_trace() {
  local file line
  for file in "$BATS_TEST_TMPDIR"/curl-*".$1"; do
    [[ -e "$file" ]] || continue
    while IFS= read -r line; do printf '%s\n' "$line"; done < "$file"
  done
}

status_nonblocking_probe() {
  status_initialize '{"status_webhook_url":"https://example.invalid/api/webhook/test-secret"}'
  STATUS_DELAY=1
  api_post_status cam-1 Overwatch patrolling 4 1000 1000 test
  local -a done_files=("$BATS_TEST_TMPDIR"/done-*)
  [[ ! -e "${done_files[0]}" ]] && printf '__returned_before_curl=1\n'
  wait
}

sleep() {
  FIELD_NOW=$(( FIELD_NOW + $1 ))
  wait
  if (( FIELD_NOW > STATUS_END_TIME )); then exit 0; fi
}

status_patrol_probe() {
  status_initialize '{"status_webhook_url":"https://example.invalid/api/webhook/test-secret"}'
  field_probe "$1" 5
}

status_unreadable_probe() {
  # shellcheck disable=SC2034 # The sourced camera-state stub reads this queue.
  HOME_CAMERA_STATES=('__FAIL__')
  STATUS_END_TIME=1310
  status_patrol_probe '{"status_heartbeat_seconds":30}'
}

status_schedule_probe() {
  # shellcheck disable=SC2329 # patrol_camera calls this stub from the sourced library.
  is_within_schedule() { return 1; }
  STATUS_END_TIME=1060
  status_patrol_probe '{"status_heartbeat_seconds":30}'
}

status_manual_probe() {
  # shellcheck disable=SC2329 # patrol_camera calls this stub from the sourced library.
  is_externally_controlled() {
    _LAST_DRIFT_MAGNITUDE=500
    _LAST_GOTO_FAILED=0
    _LAST_AT_HOMEVIEW=0
    _LAST_ACQUISITION_STATE=acquired
    _LAST_ACQUISITION_STREAK=2
    return 0
  }
  STATUS_END_TIME=1020
  status_patrol_probe '{}'
}

status_load_shutdown() {
  local line definition="" reading=0
  while IFS= read -r line; do
    [[ "$line" != 'shutdown() {' ]] || reading=1
    if (( reading )); then
      definition+="$line"$'\n'
      [[ "$line" != '}' ]] || break
    fi
  done < "$BATS_TEST_DIRNAME/../ptz-patrol.sh"
  eval "$definition"
}

api_cleanup() {
  local -a done_files=("$BATS_TEST_TMPDIR"/done-*)
  printf '__shutdown_completed=%s elapsed=%s\n' "${#done_files[@]}" "$SECONDS"
}

status_shutdown_probe() {
  status_load_shutdown
  status_initialize '{"status_webhook_url":"https://example.invalid/api/webhook/test-secret"}'
  local _SHUTTING_DOWN=0 _STATUS_VERSION=test
  local -a _CHILD_PIDS=() _DYN_TRACKING_IDS=() _CAMERA_IDS=(cam-1 cam-2 cam-3)
  local -A _CAMERA_NAMES=([cam-1]=One [cam-2]=Two [cam-3]=Three)
  STATUS_DELAY=2
  SECONDS=0
  trap shutdown EXIT
  shutdown
}
