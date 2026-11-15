#!/usr/bin/env bats

load cue_test_helper

@test "pending cue expires across a schedule pause and resumes the next path step" {
  run cue_integration_probe '{"dynamic_auto_tracking":true,"dwell_seconds":6,"ptz_settle_seconds":0,"cues":[{"camera_id":"fixed1","slot":2}]}' integration-expiry-schedule 2
  [ "$status" -eq 0 ]
  assert_contains "$output" 'Cue dropped — 60s old'
  assert_contains "$output" '__goto=4 now=1062 idx=1'
  assert_not_contains "$output" '__goto=2'
}

@test "pending cue expires across a manual hold without a late cue goto" {
  run cue_integration_probe '{"dwell_seconds":6,"ptz_settle_seconds":0,"cues":[{"camera_id":"fixed1","slot":2}]}' integration-expiry-manual 2
  [ "$status" -eq 0 ]
  assert_contains "$output" 'Manual control hold expired'
  assert_contains "$output" 'Cue dropped — 20s old'
  assert_contains "$output" '__goto=4 now=1022 idx=1'
  assert_not_contains "$output" '__goto=2'
}

@test "pending cue survives a five-second top activity hold" {
  run cue_integration_probe '{"dynamic_auto_tracking":true,"dwell_seconds":6,"ptz_settle_seconds":0,"cues":[{"camera_id":"fixed1","slot":2,"hold_seconds":5}]}' integration-expiry-short 3
  [ "$status" -eq 0 ]
  assert_contains "$output" '__goto=2 now=1007 idx=1'
  assert_contains "$output" '__goto=4 now=1012 idx=1'
  assert_not_contains "$output" 'Cue dropped'
}

@test "expired cue after a top activity hold does not dynamically skip the next step" {
  run cue_integration_probe '{"dynamic_auto_tracking":true,"dwell_seconds":6,"ptz_settle_seconds":0,"cues":[{"camera_id":"fixed1","slot":2}]}' integration-expiry-activity 2
  [ "$status" -eq 0 ]
  assert_contains "$output" 'Cue dropped — 20s old'
  assert_contains "$output" '__goto=4 now=1022 idx=1'
  assert_not_contains "$output" '__goto=2'
}

@test "pending cue expires while the PTZ is unreadable" {
  run cue_integration_probe '{"dwell_seconds":6,"ptz_settle_seconds":0,"cues":[{"camera_id":"fixed1","slot":2}]}' integration-expiry-unreadable 2
  [ "$status" -eq 0 ]
  assert_contains "$output" 'Cue dropped — 20s old'
  assert_contains "$output" '__goto=4 now=1022 idx=1'
  assert_not_contains "$output" '__goto=2'
}

@test "events HTTP failure warns once and nonempty success recovers once" {
  run cue_failure_sequence_probe http
  [ "$status" -eq 0 ]
  assert_contains "$output" 'Cue poll failed (HTTP 503, curl rc 0) — cues paused until the events request succeeds'
  assert_contains "$output" '__failure1 warnings=1 failed=1'
  assert_contains "$output" '__failure2 warnings=1 failed=1'
  assert_contains "$output" '__success1 failed=0'
  assert_contains "$output" '__success2 failed=0'
  local without=${output//Cue poll recovered/}
  [ "$(( ${#output} - ${#without} ))" -eq 18 ]
}

@test "unparseable events warn once and empty success recovers only once" {
  local mode without
  for mode in parse parse-empty parse-object; do
    run cue_failure_sequence_probe "$mode"
    [ "$status" -eq 0 ]
    assert_contains "$output" 'Cue poll failed (HTTP 200, curl rc 0)'
    assert_contains "$output" '__failure1 warnings=1 failed=1'
    assert_contains "$output" '__failure2 warnings=1 failed=1'
    assert_contains "$output" '__success1 failed=0'
    assert_contains "$output" '__success2 failed=0'
    without=${output//Cue poll recovered/}
    [ "$(( ${#output} - ${#without} ))" -eq 18 ]
  done
}

@test "events curl failure reports its rc once and recovers on empty success" {
  run cue_failure_sequence_probe curl
  [ "$status" -eq 0 ]
  assert_contains "$output" 'Cue poll failed (HTTP 000, curl rc 28)'
  assert_contains "$output" '__failure1 warnings=1 failed=1'
  assert_contains "$output" '__failure2 warnings=1 failed=1'
  assert_contains "$output" '__success1 failed=0'
  assert_contains "$output" '__success2 failed=0'
  local without=${output//Cue poll recovered/}
  [ "$(( ${#output} - ${#without} ))" -eq 18 ]
}

@test "future-start events cannot cue and are not marked seen" {
  run cue_poll_probe future
  [ "$status" -eq 0 ]
  assert_contains "$output" '__first=-1 rc=1 until=0 seen=0'
}

@test "post-fetch clock excludes events that expired during the request" {
  run cue_poll_probe fetch-stale
  [ "$status" -eq 0 ]
  assert_contains "$output" '__first=-1 rc=1 until=0 seen=0'
}

@test "post-fetch clock sets the match time and cooldown from the fresh clock" {
  run cue_poll_probe fetch-valid
  [ "$status" -eq 0 ]
  assert_contains "$output" '__first=0 rc=0 until=1005'
  assert_contains "$output" '__matched_at=1005'
}

@test "scientific-notation start is ignored without Bash arithmetic errors" {
  run cue_poll_probe scientific
  [ "$status" -eq 0 ]
  assert_contains "$output" '__first=-1 rc=1 until=0 seen=0'
  assert_not_contains "$output" 'value too great for base'
  assert_not_contains "$output" 'syntax error'
}

@test "unexpected cue goto codes consume the cue without a phantom dwell or cued state" {
  local code
  for code in 500 000 302; do
    CUE_GOTO_CODE=$code
    run cue_integration_probe '{"dwell_seconds":6,"ptz_settle_seconds":0,"cues":[{"camera_id":"fixed1","slot":2,"hold_seconds":5}]}' integration-unexpected 3
    [ "$status" -eq 0 ]
    assert_contains "$output" "Unexpected HTTP $code on goto slot 2"
    assert_contains "$output" '__goto=4 now=1002 idx=1'
    assert_not_contains "$output" '__status=cued'
  done
}
