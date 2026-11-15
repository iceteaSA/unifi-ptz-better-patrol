#!/usr/bin/env bats

setup() {
  source "$BATS_TEST_DIRNAME/../api.sh"
  _BODY_TEMP="$BATS_TEST_TMPDIR/body"
  _LOG_LEVEL=3
  api_ensure_auth() { :; }
  sleep() { :; }
  curl() {
    [[ ! -s "$_BODY_TEMP" ]] || printf 'not truncated\n' >> "$BATS_TEST_TMPDIR/stale"
    if [[ "$transfer_rc" == 18 ]]; then
      printf '{"id":' > "$_BODY_TEMP"
    fi
    printf 200
    return "$transfer_rc"
  }
}

probe_failed_transfer() {
  printf '{"id":"cam1","state":"CONNECTED","lastMotion":0}' > "$_BODY_TEMP"
  local rc=0
  api_get_with_retry /cameras/cam1 1 0 > "$BATS_TEST_TMPDIR/reply" || rc=$?
  [[ "$rc" == 1 ]]
  [[ "$_LAST_HTTP_CODE" == 000 ]]
  [[ "$_LAST_CURL_RC" == "$transfer_rc" ]]
  [[ -z "$_LAST_BODY" ]]
  [[ ! -e "$BATS_TEST_TMPDIR/stale" ]]
  [[ ! -s "$BATS_TEST_TMPDIR/reply" || "$(<"$BATS_TEST_TMPDIR/reply")" == *"HTTP 000"* ]]
  printf '{"id":"cam1","state":"CONNECTED","lastMotion":0}' > "$_BODY_TEMP"
  is_tracking cam1 60 0 0 > "$BATS_TEST_TMPDIR/activity"
  [[ "$_LAST_ACTIVITY_KNOWN" == 0 ]]
  [[ "$(<"$BATS_TEST_TMPDIR/activity")" == *"Failed to fetch camera state — assuming active (fail-safe)"* ]]
}

@test "timeout after HTTP 200 discards stale camera state and holds as unreadable" {
  local transfer_rc=28
  probe_failed_transfer
}

@test "partial HTTP 200 transfer discards partial camera state and holds as unreadable" {
  local transfer_rc=18
  probe_failed_transfer
}
