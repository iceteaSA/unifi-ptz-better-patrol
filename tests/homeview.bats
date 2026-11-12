#!/usr/bin/env bats

load homeview_test_helper

setup() {
  _LOG_LEVEL=3
  HOMEVIEW_READS=0
}

@test "HomeView return during dwell clears target and stops later position reads" {
  run homeview_patrol_probe
  [ "$status" -eq 0 ]
  assert_contains "$output" 'PTZ drift detected'
  assert_contains "$output" 'Camera returned to its HomeView — not manual control'
  assert_contains "$output" '__next_goto=4 now=1018 reads=3 home_reads=1 previous_expected=-1/-1/-1'
  assert_not_contains "$output" 'External control detected'
  assert_not_contains "$output" '__home_read=2'
}

@test "top-of-loop HomeView return clears target before next goto" {
  run homeview_patrol_probe 10
  [ "$status" -eq 0 ]
  assert_contains "$output" 'Camera returned to its HomeView — not manual control'
  assert_contains "$output" '__next_goto=4 now=1010 reads=3 home_reads=1 previous_expected=-1/-1/-1'
  assert_not_contains "$output" 'External control detected'
}

@test "home dwell HomeView return clears baseline without sampling it again" {
  run homeview_home_probe
  [ "$status" -eq 0 ]
  assert_contains "$output" 'Camera returned to its HomeView — not manual control'
  assert_contains "$output" '__home_status=0 ptz_reads=3 expected=-1/-1/-1'
  assert_not_contains "$output" 'External control detected'
}

@test "drift elsewhere still requires two polls and starts a manual hold" {
  run homeview_patrol_probe 24 $'8700\t10412\t710'
  [ "$status" -eq 0 ]
  assert_contains "$output" 'PTZ drift detected'
  assert_contains "$output" 'External control detected — holding patrol for 120s'
  assert_contains "$output" '__external_hold=1 home_reads=2'
  assert_not_contains "$output" 'Camera returned to its HomeView'
}

@test "failed HomeView HTTP read retains the manual hold" {
  HOMEVIEW_CODE=503
  run homeview_patrol_probe 24
  [ "$status" -eq 0 ]
  assert_contains "$output" 'External control detected — holding patrol for 120s'
  assert_contains "$output" '__external_hold=1 home_reads=2'
  assert_not_contains "$output" 'Camera returned to its HomeView'
}

@test "malformed and missing HomeView fields retain the manual hold" {
  local body
  for body in 'not-json' '{}' '{"ptz":{"pan":10880,"tilt":11430}}'; do
    HOMEVIEW_BODY=$body
    run homeview_patrol_probe 24
    [ "$status" -eq 0 ]
    assert_contains "$output" 'External control detected — holding patrol for 120s'
    assert_contains "$output" '__external_hold=1 home_reads=2'
    assert_not_contains "$output" 'Camera returned to its HomeView'
  done
}

@test "HomeView match requires all axes and includes threshold boundaries" {
  run homeview_patrol_probe 18 $'11080\t11630\t30'
  [ "$status" -eq 0 ]
  assert_contains "$output" 'Camera returned to its HomeView — not manual control'
  local live
  for live in $'11081\t11630\t30' $'11080\t11631\t30' $'11080\t11630\t31'; do
    run homeview_patrol_probe 24 "$live"
    [ "$status" -eq 0 ]
    assert_contains "$output" 'External control detected — holding patrol for 120s'
    assert_not_contains "$output" 'Camera returned to its HomeView'
  done
}

@test "HomeView flag resets even when the next position read fails" {
  run homeview_reset_probe
  [ "$status" -eq 0 ]
  assert_contains "$output" '__first_home=1'
  assert_contains "$output" '__failed_position_home=0'
}
