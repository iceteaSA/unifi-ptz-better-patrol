#!/usr/bin/env bats

load test_helper

setup() {
  ENV_COMMAND=$(command -v env)
  NON_BASH_SHELL=$(command -v dash || true)
  if [[ -z "$NON_BASH_SHELL" ]] || ! "$ENV_COMMAND" -u BASH_VERSION "$NON_BASH_SHELL" -c '[ -z "${BASH_VERSION:-}" ]'; then
    NON_BASH_SHELL=$(command -v sh || true)
    if [[ -z "$NON_BASH_SHELL" ]] || ! "$ENV_COMMAND" -u BASH_VERSION "$NON_BASH_SHELL" -c '[ -z "${BASH_VERSION:-}" ]'; then
      skip 'No non-Bash sh is installed (dash and sh are unavailable or Bash)'
    fi
  fi
  mkdir -p "$BATS_TEST_TMPDIR/nonbash/bin" "$BATS_TEST_TMPDIR/nonbash/run"
  cp "$BATS_TEST_DIRNAME/fixtures/nonroot-id" "$BATS_TEST_TMPDIR/nonbash/bin/id"
  chmod +x "$BATS_TEST_TMPDIR/nonbash/bin/id"
}

installer_wrong_shell_probe() {
  local script=$1 sandbox="$BATS_TEST_TMPDIR/nonbash"
  cp "$BATS_TEST_DIRNAME/../$script" "$sandbox/$script"
  (
    cd "$sandbox/run" || return 1
    "$ENV_COMMAND" -u BASH_VERSION PATH="$sandbox/bin" "$NON_BASH_SHELL" "$sandbox/$script"
  )
}

@test "install refuses a non-Bash shell before creating any file" {
  run installer_wrong_shell_probe install.sh
  [ "$status" -eq 1 ]
  [ "$output" = "install.sh needs bash: run 'sudo bash install.sh'" ]
  shopt -s nullglob dotglob
  local sandbox="$BATS_TEST_TMPDIR/nonbash"
  local -a entries=("$sandbox/"* "$sandbox/bin/"* "$sandbox/run/"*)
  [ "${#entries[@]}" -eq 4 ]
}

@test "uninstall refuses a non-Bash shell before creating any file" {
  run installer_wrong_shell_probe uninstall.sh
  [ "$status" -eq 1 ]
  [ "$output" = "uninstall.sh needs bash: run 'sudo bash uninstall.sh'" ]
  shopt -s nullglob dotglob
  local sandbox="$BATS_TEST_TMPDIR/nonbash"
  local -a entries=("$sandbox/"* "$sandbox/bin/"* "$sandbox/run/"*)
  [ "${#entries[@]}" -eq 4 ]
}
