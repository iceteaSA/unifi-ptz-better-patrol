#!/usr/bin/env bats

load installer_config_helper

@test "new config and its copy destination are private despite an executable example" {
  run installer_config_probe new
  [ "$status" -eq 0 ]
  assert_contains "$output" '__created_mode=600'
  assert_contains "$output" '__final_mode=600'
  assert_not_contains "$output" '__temporary_left'
}

@test "normal update restricts an existing config even without credential flags" {
  run installer_config_probe existing
  [ "$status" -eq 0 ]
  assert_contains "$output" '__final_mode=600'
}

@test "credential updates keep every intermediate file private and remove them" {
  run installer_config_probe update
  [ "$status" -eq 0 ]
  assert_contains "$output" '__final_mode=600'
  assert_not_contains "$output" '__temporary_left'
  run installer_temp_modes
  [ "$status" -eq 0 ]
  assert_contains "$output" '__temporary_mode=600'
  assert_not_contains "$output" '__temporary_mode=644'
  assert_not_contains "$output" '__temporary_mode=755'
  assert_not_contains "$output" '__temporary_mode=700'
}

@test "bootstrap restricts the existing config without rewriting it" {
  run installer_config_probe bootstrap
  [ "$status" -eq 0 ]
  [ "$output" = '__final_mode=600' ]
}

@test "service removes proxy environment variables for NVR and webhook requests" {
  run unit_proxy_environment_probe
  [ "$status" -eq 0 ]
  [ "$output" = 'UnsetEnvironment=http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY no_proxy NO_PROXY' ]
}
