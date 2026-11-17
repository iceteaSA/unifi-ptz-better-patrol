#!/usr/bin/env bats

load activity_hold_helper

@test "tracking holds outlast motion cap with unlimited or larger smart cap" {
  local cap reason
  for cap in 0 30; do
    for reason in tracking smart-tracking; do
      run activity_hold_probe "{\"max_tracking_wait\":5,\"max_smart_wait\":$cap}" "$reason" "$reason" "$reason" "$reason" clear
      [ "$status" -eq 0 ]
      assert_contains "$output" 'Tracking/motion active — holding (tracking)'
      assert_contains "$output" 'Activity hold ended after 20s (tracking 20s, smart 0s, motion 0s)'
      assert_contains "$output" '__goto=0 now=1020'
      assert_not_contains "$output" 'hit on motion only'
      assert_not_contains "$output" 'Max smart wait'
    done
  done
}

@test "motion boolean and lastMotion tail hit only the continuous motion cap" {
  local reason
  for reason in motion tail; do
    run activity_hold_probe '{"max_tracking_wait":10,"max_smart_wait":5}' "$reason" "$reason" "$reason" clear
    [ "$status" -eq 0 ]
    assert_contains "$output" 'Tracking/motion active — holding (motion)'
    assert_contains "$output" 'Max wait (10s) hit on motion only — advancing anyway'
    assert_contains "$output" 'Activity hold ended after 10s (tracking 0s, smart 0s, motion 10s)'
    assert_contains "$output" '__goto=0 now=1010'
  done
}

@test "smart polls reset motion seconds before a new full motion-only stretch" {
  run activity_hold_probe '{"max_tracking_wait":10,"max_smart_wait":0}' motion smart motion motion motion clear
  [ "$status" -eq 0 ]
  assert_contains "$output" 'Max wait (10s) hit on motion only — advancing anyway'
  assert_contains "$output" 'Activity hold ended after 20s (tracking 0s, smart 5s, motion 15s)'
  assert_contains "$output" '__goto=0 now=1020'
}

@test "smart cap uses total hold time while latest smart or tracking is active" {
  local reason
  for reason in smart tracking; do
    run activity_hold_probe '{"max_tracking_wait":50,"max_smart_wait":15}' motion "$reason" "$reason" "$reason" clear
    [ "$status" -eq 0 ]
    assert_contains "$output" "Max smart wait (15s) hit while $reason active — advancing anyway"
    assert_contains "$output" '__goto=0 now=1015'
  done
}

@test "zero smart cap allows smart detection to clear without any cap" {
  run activity_hold_probe '{"max_tracking_wait":5,"max_smart_wait":0}' smart smart smart smart clear
  [ "$status" -eq 0 ]
  assert_contains "$output" 'Tracking/motion active — holding (smart)'
  assert_contains "$output" 'Activity hold ended after 20s (tracking 0s, smart 20s, motion 0s)'
  assert_contains "$output" '__goto=0 now=1020'
  assert_not_contains "$output" 'advancing anyway'
}

@test "unknown activity remains uncapped and keeps the five-minute unreadable warning" {
  local -a sequence=()
  local i
  for (( i=0; i<62; i++ )); do sequence+=(unknown); done
  run activity_hold_probe '{"max_tracking_wait":5,"max_smart_wait":5}' "${sequence[@]}" clear
  [ "$status" -eq 0 ]
  assert_contains "$output" 'Tracking/motion active — holding (unknown)'
  assert_contains "$output" 'Camera unreadable for 5m — holding position (no activity check succeeded)'
  assert_contains "$output" 'Activity hold ended after 310s (tracking 0s, smart 0s, motion 0s, unknown 310s)'
  assert_contains "$output" '__goto=0 now=1310'
  assert_not_contains "$output" 'advancing anyway'
}

@test "unknown polls pause motion seconds rather than reset or add to them" {
  run activity_hold_probe '{"max_tracking_wait":10,"max_smart_wait":0}' motion unknown motion motion clear
  [ "$status" -eq 0 ]
  assert_contains "$output" 'Max wait (10s) hit on motion only — advancing anyway'
  assert_contains "$output" 'Activity hold ended after 15s (tracking 0s, smart 0s, motion 10s, unknown 5s)'
  assert_contains "$output" '__goto=0 now=1015'
}

@test "hold summary assigns every interval to the preceding poll reason" {
  run activity_hold_probe '{"max_tracking_wait":100,"max_smart_wait":0}' tracking smart motion unknown tracking clear
  [ "$status" -eq 0 ]
  assert_contains "$output" 'Activity hold ended after 25s (tracking 10s, smart 5s, motion 5s, unknown 5s)'
  assert_not_contains "$output" 'Clear after'
}

@test "failed hold fetches stay uncapped until a known reason returns" {
  run activity_hold_probe '{"max_tracking_wait":5,"max_smart_wait":5}' motion failed failed motion clear
  [ "$status" -eq 0 ]
  assert_contains "$output" 'Failed to fetch camera state — assuming active (fail-safe)'
  assert_contains "$output" 'Max wait (5s) hit on motion only — advancing anyway'
  assert_contains "$output" 'Activity hold ended after 15s (tracking 0s, smart 0s, motion 5s, unknown 10s)'
  assert_contains "$output" '__goto=0 now=1015'
}

@test "activity clear at the smart cap boundary ends without a false cap warning" {
  run activity_hold_probe '{"max_tracking_wait":5,"max_smart_wait":10}' tracking tracking clear
  [ "$status" -eq 0 ]
  assert_contains "$output" 'Activity hold ended after 10s (tracking 10s, smart 0s, motion 0s)'
  assert_not_contains "$output" 'advancing anyway'
}

@test "invalid max_smart_wait warns and uses 1800 while missing or null use the default" {
  local value
  for value in -1 1.5 false true '"30"' '"invalid"' '[]' '{}'; do
    run activity_hold_probe "{\"max_tracking_wait\":5,\"max_smart_wait\":$value}" tracking tracking clear
    [ "$status" -eq 0 ]
    assert_contains "$output" 'Invalid max_smart_wait — using 1800'
    assert_contains "$output" 'max_smart_wait=1800s'
    assert_contains "$output" '__goto=0 now=1010 max_smart_wait=1800'
  done
  for value in null 0 15; do
    run activity_hold_probe "{\"max_smart_wait\":$value}" clear
    [ "$status" -eq 0 ]
    assert_not_contains "$output" 'Invalid max_smart_wait'
  done
  run activity_hold_probe '{}' clear
  [ "$status" -eq 0 ]
  assert_contains "$output" '__goto=0 now=1000 max_smart_wait=1800'
  assert_not_contains "$output" 'Invalid max_smart_wait'
}
