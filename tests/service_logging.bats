#!/usr/bin/env bats

load test_helper

@test "service bounds runaway logging without a daily silence window" {
  local line interval="" burst=""
  while IFS= read -r line; do
    case "$line" in
      LogRateLimitIntervalSec=*) interval=${line#*=} ;;
      LogRateLimitBurst=*) burst=${line#*=} ;;
    esac
  done < "$BATS_TEST_DIRNAME/../ptz-patrol.service"
  [ "$interval" = 30s ]
  [ "$burst" = 2000 ]
}
