#!/usr/bin/env bats

load cue_reacquire_helper

@test "per-entry seen allows a second zone entry on the same event only once" {
  run reacquire_poll_probe entries
  [ "$status" -eq 0 ]
  assert_contains "$output" '__match=0 rc=0 type=person at=1000 until=1000 seen=1 jq=1'
  assert_contains "$output" 'Cue: Horsetrail Up person (Past pole) → slot 4'
  assert_contains "$output" '__repeat=-1 seen=1'
  assert_contains "$output" '__next_entry=1 seen=2'
  assert_contains "$output" 'Cue: Horsetrail Up person (Near side) → slot 2'
  assert_contains "$output" '__retained=2'
  assert_contains "$output" '__pruned=0'
}

@test "reacquire accepts old enter or moving zones with one jq and a 120 second query" {
  local mode
  for mode in enter moving; do
    run reacquire_poll_probe "$mode"
    [ "$status" -eq 0 ]
    assert_contains "$output" 'start=880000&end=1000000'
    assert_contains "$output" '__match=0 rc=0 type=person at=1000 until=1010 seen=1 jq=1'
    assert_contains "$output" 'Tracking lost — Cue: Horsetrail Up person (Past pole) → slot 4'
  done
}

@test "old leave zones cannot reacquire even with a null end" {
  run reacquire_poll_probe leave
  [ "$status" -eq 0 ]
  assert_contains "$output" '__match=-1 rc=1 type= at=0 until=0 seen=0 jq=1'
  assert_not_contains "$output" 'Tracking lost — Cue:'
}

@test "normal cue polls still reject old enter events" {
  run reacquire_poll_probe normal-old
  [ "$status" -eq 0 ]
  assert_contains "$output" 'start=985000&end=1000000'
  assert_contains "$output" '__match=-1 rc=1 type= at=0 until=0 seen=0 jq=1'
}

@test "reacquire accepts recent leave under the normal rule" {
  run reacquire_poll_probe recent-leave
  [ "$status" -eq 0 ]
  assert_contains "$output" '__match=0 rc=0 type=person at=1000 until=1010 seen=1 jq=1'
  assert_contains "$output" 'Tracking lost — Cue: Horsetrail Up person (Past pole) → slot 4'
}

@test "current presence beats leave then config order breaks current presence ties" {
  run reacquire_poll_probe priority
  [ "$status" -eq 0 ]
  assert_contains "$output" '__match=1 rc=0 type=person at=1000 until=0 seen=1 jq=1'
  assert_contains "$output" 'Tracking lost — Cue: Horsetrail Up person (Near side) → slot 2'
  run reacquire_poll_probe order
  [ "$status" -eq 0 ]
  assert_contains "$output" '__match=0 rc=0 type=person at=1000 until=1010 seen=1 jq=1'
  assert_contains "$output" 'Tracking lost — Cue: Horsetrail Up person (Past pole) → slot 4'
}

@test "unfiltered reacquire requires any current zone and keeps the old log shape" {
  run reacquire_poll_probe unfiltered
  [ "$status" -eq 0 ]
  assert_contains "$output" 'Tracking lost — Cue: Horsetrail Up person → slot 4'
  assert_contains "$output" '__match=0 rc=0 type=person at=1000 until=1120 seen=1 jq=1'
  run reacquire_poll_probe unfiltered-leave
  [ "$status" -eq 0 ]
  assert_contains "$output" '__match=-1 rc=1 type= at=0 until=0 seen=0 jq=1'
}

@test "unknown zone names use the configured id in the cue log" {
  run reacquire_poll_probe id
  [ "$status" -eq 0 ]
  assert_contains "$output" 'Tracking lost — Cue: fixed1 person (2) → slot 4'
  assert_contains "$output" '__match=0 rc=0 type=person at=1000 until=1120 seen=1 jq=1'
}

@test "a camera zone without a name still resolves its id" {
  run reacquire_poll_probe id-unnamed
  [ "$status" -eq 0 ]
  assert_contains "$output" 'Tracking lost — Cue: Horsetrail Up person (2) → slot 4'
  assert_contains "$output" '__match=0 rc=0 type=person at=1000 until=1120 seen=1 jq=1'
}

@test "reacquire respects cooldown current slot types and window limits" {
  local mode
  for mode in cooldown current types stale future; do
    run reacquire_poll_probe "$mode"
    [ "$status" -eq 0 ]
    if [[ "$mode" == cooldown ]]; then
      assert_contains "$output" '__match=-1 rc=1 type= at=0 until=1001 seen=0 jq=1'
    else
      assert_contains "$output" '__match=-1 rc=1 type= at=0 until=0 seen=0 jq=1'
    fi
    assert_not_contains "$output" 'Tracking lost — Cue:'
  done
}

@test "reacquire retains the exactly one array document check" {
  run reacquire_poll_probe documents
  [ "$status" -eq 0 ]
  assert_contains "$output" 'Cue poll failed'
  assert_contains "$output" '__match=-1 rc=1 type= at=0 until=0 seen=0 jq=1'
}

@test "lost track interrupts motion hold through the existing cued and resume path" {
  run reacquire_hold_probe resume tracking motion clear
  [ "$status" -eq 0 ]
  assert_contains "$output" '__events now=1005 known=1 smart=0 tracking=0'
  assert_contains "$output" 'Tracking lost — Cue: Horsetrail Up person (Past pole) → slot 4'
  assert_contains "$output" '__goto=4 now=1005 cue=1 source=Horsetrail Up events=1 seen=1'
  assert_contains "$output" '__status=cued source=Horsetrail Up slot=4'
  assert_contains "$output" 'Cue hold ended'
  assert_contains "$output" '__goto=0 now=1012 cue=0 source= events=1 seen=1'
}

@test "reacquire also checks the poll that clears the activity hold" {
  run reacquire_hold_probe clear tracking clear
  [ "$status" -eq 0 ]
  assert_contains "$output" '__goto=4 now=1005 cue=1 source=Horsetrail Up events=1 seen=1'
  assert_contains "$output" 'Tracking lost — Cue: Horsetrail Up person (Past pole) → slot 4'
}

@test "tracking polls block reacquire until a clear poll" {
  run reacquire_hold_probe gated tracking tracking clear
  [ "$status" -eq 0 ]
  assert_not_contains "$output" '__events now=1005'
  assert_contains "$output" '__events now=1010 known=1 smart=0 tracking=0'
  assert_contains "$output" '__goto=4 now=1010 cue=1 source=Horsetrail Up events=1 seen=1'
  assert_contains "$output" 'Tracking lost — Cue: Horsetrail Up person (Past pole) → slot 4'
}

@test "smart polls block reacquire until a clear poll" {
  run reacquire_hold_probe gated tracking smart clear
  [ "$status" -eq 0 ]
  assert_not_contains "$output" '__events now=1005'
  assert_contains "$output" '__events now=1010 known=1 smart=0 tracking=0'
  assert_contains "$output" '__goto=4 now=1010 cue=1 source=Horsetrail Up events=1 seen=1'
  assert_contains "$output" 'Tracking lost — Cue: Horsetrail Up person (Past pole) → slot 4'
}

@test "unreadable polls block reacquire until a clear poll" {
  run reacquire_hold_probe gated tracking unknown clear
  [ "$status" -eq 0 ]
  assert_not_contains "$output" '__events now=1005'
  assert_contains "$output" '__events now=1010 known=1 smart=0 tracking=0'
  assert_contains "$output" '__goto=4 now=1010 cue=1 source=Horsetrail Up events=1 seen=1'
  assert_contains "$output" 'Tracking lost — Cue: Horsetrail Up person (Past pole) → slot 4'
}

@test "a hold with tracking only in a later poll can reacquire" {
  run reacquire_hold_probe later motion tracking clear
  [ "$status" -eq 0 ]
  assert_contains "$output" '__goto=4 now=1010 cue=1 source=Horsetrail Up events=1 seen=1'
  assert_contains "$output" 'Tracking lost — Cue: Horsetrail Up person (Past pole) → slot 4'
}

@test "a hold that never tracked makes no reacquire request" {
  run reacquire_hold_probe never smart motion clear
  [ "$status" -eq 0 ]
  assert_contains "$output" '__goto=0 now=1010 cue=0 source= events=0 seen=0'
  assert_not_contains "$output" '__events'
  assert_not_contains "$output" 'Tracking lost — Cue:'
}

@test "no cues means no extra request after tracking" {
  run reacquire_hold_probe no-cues tracking motion clear
  [ "$status" -eq 0 ]
  assert_contains "$output" '__goto=0 now=1010 cue=0 source= events=0 seen=0'
  assert_not_contains "$output" '__events'
}

@test "old leave events keep a lost-track hold until its activity clears" {
  run reacquire_hold_probe leave tracking motion clear
  [ "$status" -eq 0 ]
  assert_contains "$output" '__goto=0 now=1010 cue=0 source= events=2 seen=0'
  assert_not_contains "$output" 'Tracking lost — Cue:'
}
