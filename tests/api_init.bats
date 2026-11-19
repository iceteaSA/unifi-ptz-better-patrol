#!/usr/bin/env bats

load test_helper

@test "each failed API temp creation exits with all earlier paths cleaned" {
  local fail_at root
  local -a files=()
  shopt -s nullglob
  for fail_at in 1 2 3 4; do
    root="$BATS_TEST_TMPDIR/init-$fail_at"
    mkdir -p "$root"
    run bash "$BATS_TEST_DIRNAME/fixtures/api-init-failure" "$BATS_TEST_DIRNAME/.." "$root" "$fail_at"
    [ "$status" -eq 1 ]
    files=("$root"/ptz-patrol-*)
    [ "${#files[@]}" -eq 0 ]
    [ "$(< "$root/count")" = "$fail_at" ]
  done
}

@test "failed child API init does not remove inherited parent temp paths" {
  local fail_at root file
  for fail_at in 1 2 3 4; do
    root="$BATS_TEST_TMPDIR/inherited-$fail_at"
    mkdir -p "$root"
    run bash "$BATS_TEST_DIRNAME/fixtures/api-init-failure" "$BATS_TEST_DIRNAME/.." "$root" "$fail_at" inherited
    [ "$status" -eq 1 ]
    for file in cookie headers auth body; do
      [ -f "$root/parent-$file" ]
      [ "$(< "$root/parent-$file")" = parent ]
    done
  done
}
