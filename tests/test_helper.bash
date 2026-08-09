#!/usr/bin/env bash

source "$BATS_TEST_DIRNAME/../api.sh"

_LOG_LEVEL=3

tracking_probe() {
  is_tracking "$@"
  local rc=$?
  printf '\n__status=%s smart=%s\n' "$rc" "$_LAST_SMART_ACTIVE"
  return "$rc"
}

api_get_with_retry() {
  return 1
}

assert_contains() {
  local haystack=$1 needle=$2
  [[ "$haystack" == *"$needle"* ]]
}

assert_not_contains() {
  local haystack=$1 needle=$2
  [[ "$haystack" != *"$needle"* ]]
}

assert_detected_without_failsafe() {
  assert_contains "$output" "__status=0"
  assert_not_contains "$output" "Failed to fetch camera state — assuming active (fail-safe)"
  assert_not_contains "$output" "Invalid camera state response — assuming active (fail-safe)"
}
