#!/usr/bin/env bats

load cue_arbitration_helper

@test "a different cue pre-empts a hold and retains the original resume step" {
  run arbitration_probe preempt
  [ "$status" -eq 0 ]
  assert_contains "$output" '__events now=1007 cue=1 known=1 tracking=0'
  assert_contains "$output" 'Cue: Water Tower person → slot 2 (pre-empts Horsetrail Up)'
  assert_contains "$output" '__goto=2 now=1007 cue=1 source=Water Tower idx=0'
  assert_contains "$output" '__status=cued source=Water Tower slot=2'
  assert_contains "$output" '__goto=0 now=1012 cue=0 source= idx=0'
  assert_not_contains "$output" '__status=patrolling source=null slot=4'
}

@test "tracking and unreadable state block cue pre-emption" {
  local mode
  for mode in tracking unreadable; do
    run arbitration_probe "$mode"
    [ "$status" -eq 0 ]
    assert_contains "$output" '__gate_end'
    assert_not_contains "$output" '__events now=1007'
    assert_not_contains "$output" 'Cue: Water Tower'
    assert_not_contains "$output" '__goto=2'
  done
}

@test "a same-slot cue does not send another goto during a hold" {
  run arbitration_probe same
  [ "$status" -eq 0 ]
  assert_not_contains "$output" '__goto=4 now=1007'
  assert_contains "$output" 'Cue hold ended'
}
