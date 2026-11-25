#!/usr/bin/env bats

load cue_reacquire_helper

check_debug_skip() {
  local mode=$1 reason=$2
  REACQUIRE_DEBUG=3
  run reacquire_poll_probe "$mode"
  [ "$status" -eq 0 ]
  assert_contains "$output" "Cue skip entry=0 (Horsetrail Up) reason=$reason event=eeeeeeee types="
  assert_contains "$output" 'zonesStatus="2:'
  assert_contains "$output" '4294967295:none'
  assert_contains "$output" 'jq=1'
}

@test "debug cue skip shows cooldown with its event snapshot" { check_debug_skip cooldown cooldown; }
@test "debug cue skip shows seen with its event snapshot" { check_debug_skip seen seen; }
@test "debug cue skip shows camera with its event snapshot" { check_debug_skip camera camera; }
@test "debug cue skip shows type with its event snapshot" { check_debug_skip types type; }
@test "debug cue skip shows zone with its event snapshot" { check_debug_skip zone zone; }
@test "debug cue skip shows window with its event snapshot" { check_debug_skip normal-leave window; }

@test "debug fired cue has the same event snapshot without a false skip for that pair" {
  REACQUIRE_DEBUG=3
  run reacquire_poll_probe normal-old
  [ "$status" -eq 0 ]
  assert_contains "$output" 'Cue fired entry=1 event=eeeeeeee types=["person"] zonesStatus="2:leave,3:enter,4294967295:none"'
  assert_not_contains "$output" 'Cue skip entry=1'
  assert_contains "$output" 'jq=1'
}

@test "info cue polls emit no debug lines and use the same one jq" {
  REACQUIRE_DEBUG=2
  run reacquire_poll_probe normal-old
  [ "$status" -eq 0 ]
  assert_contains "$output" 'Cue: Horsetrail Up person (Near side) → slot 2'
  assert_contains "$output" 'jq=1'
  assert_not_contains "$output" 'Cue skip'
  assert_not_contains "$output" 'Cue fired'
  assert_not_contains "$output" 'zonesStatus='
}
