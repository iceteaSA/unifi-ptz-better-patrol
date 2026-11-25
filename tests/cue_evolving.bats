#!/usr/bin/env bats

load cue_test_helper

@test "same event can add person to animal types and fire its first cue" {
  run cue_evolving_probe types
  [ "$status" -eq 0 ]
  assert_contains "$output" '__evolving_first=-1 seen=0'
  assert_contains "$output" '__evolving_second=0 seen=1'
  assert_contains "$output" 'Cue: One person → slot 4'
}

@test "third poll of a fired evolving event cannot fire a second cue" {
  run cue_evolving_probe types
  [ "$status" -eq 0 ]
  assert_contains "$output" '__evolving_second=0 seen=1'
  assert_contains "$output" '__evolving_third=-1 seen=1'
  local line='Cue: One person → slot 4'
  local without=${output//Cue: One person → slot 4/}
  [ "$(( ${#output} - ${#without} ))" -eq "${#line}" ]
}

@test "same event seen during cooldown fires once cooldown ends inside the window" {
  run cue_evolving_probe cooldown
  [ "$status" -eq 0 ]
  assert_contains "$output" '__evolving_first=-1 seen=0'
  assert_contains "$output" '__evolving_second=0 seen=1'
  assert_contains "$output" 'Cue: One person → slot 4'
  assert_contains "$output" '__evolving_third=-1 seen=1'
}

@test "same event accepted at the current slot stays seen after the PTZ moves" {
  run cue_evolving_probe current
  [ "$status" -eq 0 ]
  assert_contains "$output" '__evolving_first=0 seen=1'
  assert_contains "$output" '__evolving_second=-1 seen=1'
  assert_contains "$output" 'Cue: One person → slot 4 (already there)'
}

@test "seen fired-event ids are pruned when their start leaves the 120-second window" {
  run cue_evolving_probe types
  [ "$status" -eq 0 ]
  assert_contains "$output" '__evolving_second=0 seen=1'
  assert_contains "$output" '__evolving_pruned=0'
}
