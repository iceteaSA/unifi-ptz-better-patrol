#!/usr/bin/env bash

# shellcheck source=/dev/null
source "$BATS_TEST_DIRNAME/test_helper.bash"

INSTALL_TEST_DIR=""

installer_code_between() {
  local start=$1 end=$2 line reading=0
  while IFS= read -r line; do
    if [[ "$line" == "$start" ]]; then
      reading=1
      continue
    fi
    (( reading )) || continue
    [[ "$line" != "$end" ]] || break
    printf '%s\n' "$line"
  done < "$BATS_TEST_DIRNAME/../install.sh"
}

get_file() {
  cp "$BATS_TEST_TMPDIR/example" "$2"
  printf '__created_mode=%s\n' "$(stat -c %a "$2")"
}

installer_record_temp_modes() {
  local file
  for file in "$INSTALL_TEST_DIR"/config.json.*; do
    [[ -e "$file" ]] || continue
    printf '__temporary_mode=%s\n' "$(stat -c %a "$file")" >> "$BATS_TEST_TMPDIR/modes"
  done
}

jq() {
  installer_record_temp_modes
  command jq "$@"
}

mv() {
  installer_record_temp_modes
  command mv "$@"
}

installer_config_probe() (
  set -e
  local mode=$1
  local -x INSTALL_DIR="$BATS_TEST_TMPDIR/install"
  local -x ARG_NVR="" ARG_USER="" ARG_PASS=""
  INSTALL_TEST_DIR=$INSTALL_DIR
  mkdir -p "$INSTALL_DIR"
  printf '{"fixture":true}\n' > "$BATS_TEST_TMPDIR/example"
  chmod 0755 "$BATS_TEST_TMPDIR/example"
  if [[ "$mode" != "new" ]]; then
    cp "$BATS_TEST_TMPDIR/example" "$INSTALL_DIR/config.json"
    chmod 0644 "$INSTALL_DIR/config.json"
  fi
  if [[ "$mode" == "update" ]]; then
    ARG_NVR=https://example.invalid
    ARG_USER=fixture
    ARG_PASS=fixture
  fi
  local early config
  early=$(installer_code_between '# Config credentials must stay private during updates and bootstrap.' '# Install dependencies')
  eval "$early"
  if [[ "$mode" != "bootstrap" ]]; then
    config=$(installer_code_between '# Install config' '# Install systemd service')
    eval "$config"
  fi
  printf '__final_mode=%s\n' "$(stat -c %a "$INSTALL_DIR/config.json")"
  local file
  for file in "$INSTALL_DIR"/config.json.*; do
    [[ ! -e "$file" ]] || { printf '__temporary_left=1\n'; return 1; }
  done
)

installer_temp_modes() {
  local line
  while IFS= read -r line; do printf '%s\n' "$line"; done < "$BATS_TEST_TMPDIR/modes"
}

unit_proxy_environment_probe() {
  local line
  while IFS= read -r line; do
    [[ "$line" != UnsetEnvironment=* ]] || printf '%s\n' "$line"
  done < "$BATS_TEST_DIRNAME/../ptz-patrol.service"
}
