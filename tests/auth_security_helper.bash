#!/usr/bin/env bash

# shellcheck source=/dev/null
source "$BATS_TEST_DIRNAME/../api.sh"

auth_prepare() {
  export AUTH_AUDIT_DIR="$BATS_TEST_TMPDIR/audit" AUTH_REAL_JQ AUTH_MODE=success
  export AUTH_TOKEN AUTH_CSRF
  printf -v AUTH_TOKEN '%s' sample-session-one
  printf -v AUTH_CSRF '%s' sample-csrf-one
  AUTH_REAL_JQ=$(command -v jq)
  mkdir -p "$AUTH_AUDIT_DIR" "$BATS_TEST_TMPDIR/bin"
  cp "$BATS_TEST_DIRNAME/fixtures/auth-audit-jq" "$BATS_TEST_TMPDIR/bin/jq"
  cp "$BATS_TEST_DIRNAME/fixtures/auth-audit-curl" "$BATS_TEST_TMPDIR/bin/curl"
  chmod +x "$BATS_TEST_TMPDIR/bin/jq" "$BATS_TEST_TMPDIR/bin/curl"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  export PATH
  CONFIG_FILE="$BATS_TEST_TMPDIR/config-test.json"
  printf '{}' > "$CONFIG_FILE"
  printf -v _USERNAME '%s' $'sample-user"\n\\'
  printf -v _PASSWORD '%s' $'sample-value"\n\\'
  _NVR_ADDRESS=https://example.invalid
}

api_load_config() { :; }
log() { printf '%s\n' "$3"; }

auth_init() {
  local before
  before=$(umask)
  umask 000
  api_init || return
  umask "$before"
}

auth_strict_probe() {
  AUTH_MODE=no-csrf bash "$BATS_TEST_DIRNAME/fixtures/auth-strict" "$BATS_TEST_DIRNAME/.."
}

auth_probe() {
  local mode=$1 path file argument request_files=0 header_refs=0
  local -a arguments=()
  auth_init || return
  api_auth || return
  path=${_AUTH_HEADERS_TEMP:-}
  case "$mode" in
    argv|requests)
      api_get /cameras >/dev/null
      api_post /cameras/cam1/ptz/goto/4 >/dev/null
      api_patch /cameras/cam1 '{"enabled":true}' >/dev/null
      for file in "$AUTH_AUDIT_DIR"/*.argv; do
        mapfile -d '' -t arguments < "$file"
        for argument in "${arguments[@]}"; do
          if [[ "$argument" == *"${_PASSWORD%%\"*}"* || "$argument" == *"${_USERNAME%%\"*}"* || "$argument" == *"$AUTH_TOKEN"* || "$argument" == *"$AUTH_CSRF"* ]]; then
            printf '__secret-in-argv\n'; return 1
          fi
          [[ "$argument" != "@$path" ]] || header_refs=$(( header_refs + 1 ))
        done
      done
      for file in "$AUTH_AUDIT_DIR"/request-*.headers; do
        [[ -f "$file" ]] || continue
        [[ "$(< "$file")" == $'TOKEN: sample-session-one\nX-CSRF-Token: sample-csrf-one' ]] || return 1
        request_files=$(( request_files + 1 ))
      done
      printf '__argv-clean header_refs=%s request_files=%s\n' "$header_refs" "$request_files"
      ;;
    payload)
      [[ -f "$AUTH_AUDIT_DIR/login-body.json" ]] || return 1
      local decoded
      decoded=$("$AUTH_REAL_JQ" -r '.username' "$AUTH_AUDIT_DIR/login-body.json")
      [[ "$decoded" == "$_USERNAME" ]] || return 1
      decoded=$("$AUTH_REAL_JQ" -r '.password' "$AUTH_AUDIT_DIR/login-body.json")
      [[ "$decoded" == "$_PASSWORD" ]] || return 1
      "$AUTH_REAL_JQ" -e '.rememberMe == true and .token == ""' "$AUTH_AUDIT_DIR/login-body.json" >/dev/null || return
      printf '__payload-roundtrip\n'
      ;;
    file)
      [[ -f "$path" ]] || return 1
      [[ "$(stat -c %a "$path")" == 600 ]] || return 1
      local -a header_lines=()
      mapfile -t header_lines < "$path"
      [[ "${#header_lines[@]}" == 2 ]] || return 1
      [[ "$(< "$path")" == $'TOKEN: sample-session-one\nX-CSRF-Token: sample-csrf-one' ]] || return 1
      printf '__private-two-headers\n'
      ;;
    reauth)
      printf -v AUTH_TOKEN '%s' sample-session-two
      printf -v AUTH_CSRF '%s' sample-csrf-two
      _LAST_AUTH=0
      api_ensure_auth || return
      [[ -n "$path" && "${_AUTH_HEADERS_TEMP:-}" == "$path" ]] || return 1
      [[ "$(< "$path")" == $'TOKEN: sample-session-two\nX-CSRF-Token: sample-csrf-two' ]] || return 1
      printf '__rewritten\n'
      ;;
    failure|rate-limited|empty|transfer|no-csrf|malformed)
      AUTH_MODE=$mode
      local rc=0
      api_auth || rc=$?
      [[ "$rc" == 1 && -n "$path" && ! -s "$path" && -z "$_TOKEN" && -z "$_CSRF_TOKEN" ]] || return 1
      printf '__failure-cleared\n'
      ;;
    cleanup)
      [[ -f "$path" ]] || return 1
      api_cleanup
      [[ ! -e "$path" ]] || return 1
      printf '__cleaned\n'
      ;;
  esac
}
