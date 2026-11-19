#!/usr/bin/env bats

load tracking_end_helper

@test "tracking to clear logs its position before the next goto" {
  run tracking_end_probe '{"max_smart_wait":0}' tracking clear
  [ "$status" -eq 0 ]
  assert_contains "$output" '[Overwatch] info: Tracking ended at pan 8500 tilt 10200 zoom 250'
  assert_contains "$output" '__goto=0 now=1005 position_reads=1 end_logs=1'
  local trace
  trace=$(< "$BATS_TEST_TMPDIR/activity-reads")
  assert_contains "$trace" $'state 1005 clear\nposition 1005\ngoto 1005'
}

@test "tracking to motion logs immediately and does not log again at clear" {
  run tracking_end_probe '{"max_smart_wait":0}' tracking motion clear
  [ "$status" -eq 0 ]
  assert_contains "$output" 'Tracking ended at pan 8500 tilt 10200 zoom 250'
  assert_contains "$output" '__goto=0 now=1010 position_reads=1 end_logs=1'
  local trace
  trace=$(< "$BATS_TEST_TMPDIR/activity-reads")
  assert_contains "$trace" $'state 1005 motion\nposition 1005\nsleep 1005\nstate 1010 clear\ngoto 1010'
}

@test "holds without tracking make zero tracking-end position reads" {
  local reason
  for reason in motion smart unknown; do
    run tracking_end_probe '{"max_smart_wait":0}' "$reason" "$reason" clear
    [ "$status" -eq 0 ]
    assert_contains "$output" '__goto=0 now=1010 position_reads=0 end_logs=0'
    assert_not_contains "$output" 'Tracking ended'
  done
}

@test "smart detection without tracking types ends the tracking episode" {
  run tracking_end_probe '{"max_smart_wait":0}' tracking smart clear
  [ "$status" -eq 0 ]
  assert_contains "$output" '__goto=0 now=1010 position_reads=1 end_logs=1'
  local trace
  trace=$(< "$BATS_TEST_TMPDIR/activity-reads")
  assert_contains "$trace" $'state 1005 smart\nposition 1005\nsleep 1005'
}

@test "invalid tracking-end positions log unreadable instead of coordinates" {
  local body
  for body in $'-1\t-1\t-1' '' $'8500\tbroken\t250' $'8500\t10200' 'not-a-position'; do
    END_POSITION_BODY=$body
    run tracking_end_probe '{"max_smart_wait":0}' tracking clear
    [ "$status" -eq 0 ]
    assert_contains "$output" '[Overwatch] info: Tracking ended (position unreadable)'
    assert_not_contains "$output" 'Tracking ended at pan'
    assert_contains "$output" 'position_reads=1 end_logs=1'
  done
}

@test "failed position transfer rejects even valid-looking tracking-end coordinates" {
  END_POSITION_RC=28
  run tracking_end_probe '{"max_smart_wait":0}' tracking clear
  [ "$status" -eq 0 ]
  assert_contains "$output" 'Tracking ended (position unreadable)'
  assert_not_contains "$output" 'Tracking ended at pan'
  assert_contains "$output" 'position_reads=1 end_logs=1'
}

@test "two tracking episodes each log their own immediate endpoint" {
  END_SECOND_POSITION_BODY=$'1234\t5678\t90'
  run tracking_end_probe '{"max_smart_wait":0}' tracking motion tracking clear
  [ "$status" -eq 0 ]
  assert_contains "$output" '__goto=0 now=1015 position_reads=2 end_logs=2'
  assert_contains "$output" 'Tracking ended at pan 8500 tilt 10200 zoom 250'
  assert_contains "$output" 'Tracking ended at pan 1234 tilt 5678 zoom 90'
  local trace
  trace=$(< "$BATS_TEST_TMPDIR/activity-reads")
  assert_contains "$trace" $'state 1005 motion\nposition 1005\nsleep 1005'
  assert_contains "$trace" $'state 1015 clear\nposition 1015\ngoto 1015'
}

@test "smart cap while tracking remains active makes no endpoint read" {
  run tracking_end_probe '{"max_smart_wait":5}' tracking tracking clear
  [ "$status" -eq 0 ]
  assert_contains "$output" 'Max smart wait (5s) hit while tracking active'
  assert_contains "$output" '__goto=0 now=1005 position_reads=0 end_logs=0'
  assert_not_contains "$output" 'Tracking ended'
}

@test "tracking to unknown logs one endpoint but keeps the unknown hold" {
  run tracking_end_probe '{"max_smart_wait":0}' tracking unknown unknown clear
  [ "$status" -eq 0 ]
  assert_contains "$output" '__goto=0 now=1015 position_reads=1 end_logs=1'
  assert_contains "$output" 'Activity hold ended after 15s (tracking 5s, smart 0s, motion 0s, unknown 10s)'
  local trace
  trace=$(< "$BATS_TEST_TMPDIR/activity-reads")
  assert_contains "$trace" $'state 1005 unknown\nposition 1005\nsleep 1005'
}
