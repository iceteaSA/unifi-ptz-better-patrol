#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source ./api.sh
CONFIG_FILE=$(mktemp)
trap 'rm -f "$CONFIG_FILE"; api_cleanup' EXIT
printf '%s\n' '{"auth_mode":"cloud","api_key":"test-key","console_id":"test-console"}' > "$CONFIG_FILE"
api_init
trap 'rm -f "$CONFIG_FILE"; api_cleanup' EXIT
curl() {
  local all="$*" out=""
  [[ "$all" != *" -k "* && "$all" != *test-key* && "$all" == *https://api.ui.com/v1/connector/consoles/test-console/proxy/protect/api/* ]] || return 99
  while (( $# )); do
    if [[ "$1" == "-o" ]]; then out=$2; shift; fi
    shift
  done
  [[ -z "$out" ]] || printf '[]' > "$out"
  printf 200
}
api_auth
[[ "$_LAST_BODY" == '[]' ]]
[[ "$(api_post /cameras/example/ptz/goto/0)" == 200 ]]
[[ "$(api_patch /cameras/example '{}')" == 200 ]]
[[ "$(stat -c %a "$_KEY_HEADER_TEMP")" == 600 ]]
header=$_KEY_HEADER_TEMP
rm -f "$CONFIG_FILE"
api_cleanup
[[ ! -f "$header" ]]
echo 'Cloud authentication, routing, TLS, secret handling and cleanup checks passed'
