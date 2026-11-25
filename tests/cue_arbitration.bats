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
  assert_contains "$output" 'Cue: Water Tower person → slot 4 (already there)'
  assert_contains "$output" '__goto=0 now=1012 cue=0 source= idx=0'
  assert_contains "$output" 'Cue hold ended'
}

@test "already-there cue holds without goto and preserves the motor settle clock" {
  run arbitration_probe already
  [ "$status" -eq 0 ]
  assert_contains "$output" 'Cue: Horsetrail Up person (Past pole) → slot 0 (already there)'
  assert_contains "$output" '__hold slot=0 source=Horsetrail Up seen=1 until=1012 last_goto=1000'
  assert_contains "$output" '__status=cued source=Horsetrail Up slot=0'
  assert_contains "$output" '__goto=4 now=1007 cue=0 source= idx=1'
  assert_not_contains "$output" '__goto=0 now=1002'
}

@test "a dropped already-there cue does not suppress the next goto bookkeeping" {
  run arbitration_probe already-drop
  [ "$status" -eq 0 ]
  assert_contains "$output" '(already there)'
  assert_contains "$output" 'Cue dropped'
  local after=${output#*Cue dropped}
  assert_contains "$after" '__goto=0 now=1032 cue=0'
  assert_contains "$after" '→ Slot 0 [HTTP 200]'
}

@test "reacquire sends a goto even for the last commanded slot" {
  run arbitration_probe reacquire-current
  [ "$status" -eq 0 ]
  assert_contains "$output" 'Tracking lost — Cue: Horsetrail Up person (Past pole) → slot 0'
  assert_contains "$output" '__goto=0 now=1007 cue=1 source=Horsetrail Up idx=0'
  assert_not_contains "$output" '(already there)'
}

@test "an expired pre-empting cue clears the previous hold before patrol resumes" {
  run arbitration_probe expiry
  [ "$status" -eq 0 ]
  assert_contains "$output" 'Cue: Water Tower person → slot 2 (pre-empts Horsetrail Up)'
  assert_contains "$output" 'Cue dropped — 20s old'
  assert_contains "$output" 'Cue hold ended'
  assert_contains "$output" '__goto=0 now=1027 cue=0 source= idx=0'
  assert_contains "$output" '__status=patrolling source=null slot=0'
  assert_not_contains "$output" '__goto=2'
}
