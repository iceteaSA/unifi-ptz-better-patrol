#!/usr/bin/env bats

load own_smart_event_helper

@test "open own event holds once per episode and checks the exact PTZ query each poll" {
  run own_check_probe open
  [ "$status" -eq 0 ]
  assert_contains "$output" 'Goto target not acquired — own smart event (person) open; holding instead of re-issuing'
  assert_contains "$output" '/events?start=970000&end=1000000&types=smartDetectZone&cameras=cam1'
  assert_contains "$output" '__own_done now=1012 requests=7 jq=6 since=0 capped=0 failed=0'
  local without=${output//holding instead of re-issuing/}
  [ "$(( ${#output} - ${#without} ))" -eq 29 ]
}

@test "face-only event holds even when every zone status is none" {
  run own_check_probe face
  [ "$status" -eq 0 ]
  assert_contains "$output" 'own smart event (face) open; holding instead of re-issuing'
  assert_contains "$output" '__own_done now=1012 requests=7 jq=6'
}

@test "own event ended in the last ten seconds holds until it ages out" {
  run own_check_probe recent
  [ "$status" -eq 0 ]
  assert_contains "$output" 'own smart event (person) open; holding instead of re-issuing'
  assert_contains "$output" '__own_done now=1006 requests=4 jq=4 since=0'
}

@test "empty old and other-camera events do not hold" {
  local mode expected
  for mode in none stale other; do
    expected=1
    [[ "$mode" != none ]] || expected=0
    run own_check_probe "$mode"
    [ "$status" -eq 0 ]
    assert_contains "$output" "__own_done now=1000 requests=1 jq=$expected since=0 capped=0 failed=0"
    assert_not_contains "$output" 'holding instead of re-issuing'
  done
}

@test "own event HTTP errors warn once and keep retry behaviour" {
  run own_check_probe error
  [ "$status" -eq 0 ]
  assert_contains "$output" 'Own smart event check failed (HTTP 503, curl rc 0) — keeping goto retry behaviour'
  assert_contains "$output" '__own_done now=1000 requests=2 jq=0 since=0 capped=0 failed=1'
  local without=${output//Own smart event check failed/}
  [ "$(( ${#output} - ${#without} ))" -eq 28 ]
}

@test "own event parser rejects empty input and multiple array documents" {
  local mode
  for mode in malformed documents; do
    run own_check_probe "$mode"
    [ "$status" -eq 0 ]
    assert_contains "$output" 'Own smart event check failed'
    assert_contains "$output" '__own_done now=1000 requests=1 jq=1 since=0 capped=0 failed=1'
  done
}

@test "own event hold cap survives another failed acquisition in the same episode" {
  run own_check_probe capped
  [ "$status" -eq 0 ]
  assert_contains "$output" 'Max smart wait (4s) hit on own smart event — resuming goto retries'
  assert_contains "$output" '__own_done now=1004 requests=4 jq=4 since=1000 capped=1 failed=0'
  local without=${output//resuming goto retries/}
  [ "$(( ${#output} - ${#without} ))" -eq 21 ]
}

@test "dwell failed goto holds activity without goto or advance until its cap" {
  run own_patrol_probe dwell
  [ "$status" -eq 0 ]
  assert_contains "$output" '__status=holding_activity source=null slot=0'
  assert_contains "$output" 'Max smart wait (6s) hit on own smart event'
  assert_contains "$output" '__goto=0 now=1008 own_requests=4 retries=1'
  assert_not_contains "$output" '__goto=4'
}

@test "top-loop failed goto also holds until the own event clears" {
  run own_patrol_probe top
  [ "$status" -eq 0 ]
  assert_contains "$output" '__own_request now=1006'
  assert_contains "$output" '__status=holding_activity source=null slot=0'
  assert_contains "$output" '__goto=0 now=1016 own_requests=3 retries=1'
  assert_not_contains "$output" '__goto=4'
}

@test "no own event and own request errors re-issue the goto as before" {
  local mode
  for mode in none error; do
    run own_patrol_probe "$mode"
    [ "$status" -eq 0 ]
    assert_contains "$output" '__goto=0 now=1002 own_requests=1 retries=1'
    assert_not_contains "$output" 'holding instead of re-issuing'
    if [[ "$mode" == error ]]; then assert_contains "$output" 'Own smart event check failed'; fi
  done
}

@test "uncapped own event hold keeps webhook heartbeats until the event clears" {
  run own_patrol_probe unlimited
  [ "$status" -eq 0 ]
  assert_contains "$output" '__goto=0 now=1072 own_requests=36 retries=1'
  assert_not_contains "$output" 'Max smart wait'
  local needle='__status=holding_activity source=null slot=0' without
  without=${output//"$needle"/}
  [ "$(( ${#output} - ${#without} ))" -eq "$(( 3 * ${#needle} ))" ]
}
