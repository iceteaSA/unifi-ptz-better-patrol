#!/usr/bin/env bats

load hold_homeview_helper

@test "drift publishes its existing HomeView read and clears it on unread or failed paths" {
  run hold_globals_probe
  [ "$status" -eq 0 ]
  assert_contains "$output" '__known_home=8500/10200/250'
  assert_contains "$output" '__unread_home=-1/-1/-1'
  assert_contains "$output" '__failed_home=-1/-1/-1'
  assert_contains "$output" '__home_requests=2'
}

@test "normal-dwell hold ends after two HomeView polls before its deadline" {
  run hold_patrol_probe normal
  [ "$status" -eq 0 ]
  assert_contains "$output" '__hold_start origin=normal now=1020 target=8500/10200/250 deadline=1140'
  assert_contains "$output" 'Camera returned to its HomeView — ending manual hold'
  assert_contains "$output" '__next_goto=0 now=1025 hold_reads=2 home_reads=2'
  assert_not_contains "$output" 'Manual control hold expired'
  [[ "$output" == *'__state=holding_manual'*'Camera returned to its HomeView — ending manual hold'*'__state=patrolling'*'__next_goto=0'* ]]
}

@test "an off-HomeView hold poll resets the consecutive-match streak" {
  run hold_patrol_probe normal "$HOLD_HERE" "$HOLD_OFF" "$HOLD_HERE" "$HOLD_HERE"
  [ "$status" -eq 0 ]
  assert_contains "$output" 'Camera returned to its HomeView — ending manual hold'
  assert_contains "$output" '__next_goto=0 now=1035 hold_reads=4 home_reads=2'
}

@test "unknown HomeView keeps the full manual hold with no hold position requests" {
  local mode
  for mode in failed malformed; do
    HOLD_HOME_CODE=503
    if [[ "$mode" == malformed ]]; then
      HOLD_HOME_CODE=200
      HOLD_HOME_BODY='{"ptz":{"pan":8500,"tilt":10200}}'
    fi
    run hold_patrol_probe normal
    [ "$status" -eq 0 ]
    assert_contains "$output" '__hold_start origin=normal now=1020 target=-1/-1/-1 deadline=1140'
    assert_contains "$output" '__next_goto=0 now=1140 hold_reads=0 home_reads=2'
    assert_contains "$output" 'Manual control hold expired — resuming patrol'
    assert_not_contains "$output" 'ending manual hold'
    assert_not_contains "$output" '__hold_position='
  done
}

@test "failed or nonnumeric hold reads reset the HomeView match streak" {
  local bad
  for bad in __FAIL__ $'bad\t10200\t250' $'-1\t-1\t-1' ''; do
    run hold_patrol_probe normal "$HOLD_HERE" "$bad" "$HOLD_HERE" "$HOLD_HERE"
    [ "$status" -eq 0 ]
    assert_contains "$output" 'Camera returned to its HomeView — ending manual hold'
    assert_contains "$output" '__next_goto=0 now=1035 hold_reads=4 home_reads=2'
  done
}

@test "hold release accepts positions just inside every positive and negative threshold" {
  local position
  for position in $'8699\t10200\t250' $'8301\t10200\t250' $'8500\t10399\t250' $'8500\t10001\t250' $'8500\t10200\t279' $'8500\t10200\t221'; do
    run hold_patrol_probe normal "$position" "$position"
    [ "$status" -eq 0 ]
    assert_contains "$output" 'Camera returned to its HomeView — ending manual hold'
    assert_contains "$output" '__next_goto=0 now=1025 hold_reads=2 home_reads=2'
  done
}

@test "hold release includes exact HomeView threshold boundaries on all axes" {
  local position
  for position in $'8700\t10400\t280' $'8300\t10000\t220'; do
    run hold_patrol_probe normal "$position" "$position"
    [ "$status" -eq 0 ]
    assert_contains "$output" 'Camera returned to its HomeView — ending manual hold'
    assert_contains "$output" '__next_goto=0 now=1025 hold_reads=2 home_reads=2'
  done
}

@test "a position just outside any HomeView threshold keeps the full hold" {
  local position
  for position in $'8701\t10200\t250' $'8299\t10200\t250' $'8500\t10401\t250' $'8500\t9999\t250' $'8500\t10200\t281' $'8500\t10200\t219'; do
    run hold_patrol_probe normal "$position"
    [ "$status" -eq 0 ]
    assert_contains "$output" '__next_goto=0 now=1140 hold_reads=24 home_reads=2'
    assert_contains "$output" 'Manual control hold expired — resuming patrol'
    assert_not_contains "$output" 'ending manual hold'
  done
}

@test "home-dwell hold passes its cached HomeView target through caller scope" {
  run hold_patrol_probe home
  [ "$status" -eq 0 ]
  assert_contains "$output" 'External control detected during home dwell'
  assert_contains "$output" '__hold_start origin=home now=1060 target=8500/10200/250 deadline=1180'
  assert_contains "$output" 'Camera returned to its HomeView — ending manual hold'
  assert_contains "$output" '__next_goto=0 now=1065 hold_reads=2 home_reads=2'
}

@test "top-of-loop hold passes its cached HomeView target" {
  run hold_patrol_probe top
  [ "$status" -eq 0 ]
  assert_contains "$output" '__hold_start origin=top now=1015 target=8500/10200/250 deadline=1135'
  assert_contains "$output" 'Camera returned to its HomeView — ending manual hold'
  assert_contains "$output" '__next_goto=4 now=1025 hold_reads=2 home_reads=2'
}

@test "early HomeView release clears stale expected positions and drift state before classification" {
  run hold_patrol_probe normal
  [ "$status" -eq 0 ]
  assert_contains "$output" 'Camera returned to its HomeView — ending manual hold'
  assert_contains "$output" '__classify now=1025 expected=-1/-1/-1 acquisition=acquiring/0 drift=0/0/0'
  assert_contains "$output" '__next_goto=0 now=1025 hold_reads=2 home_reads=2 expected=-1/-1/-1 acquisition=acquiring/0'
  assert_not_contains "$output" 'Manual control hold expired'
}
