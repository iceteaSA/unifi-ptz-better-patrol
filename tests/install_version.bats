#!/usr/bin/env bats

load install_version_helper

@test "version helper combines the version and install commit" {
  printf '1.1.0\n' > "$SCRIPT_DIR/VERSION"
  printf 'ref=main\ncommit=c61700a8f1f16ac621e5896c11eb3c9021643c74\n' > "$SCRIPT_DIR/install-info"
  run get_install_version
  [ "$status" -eq 0 ]
  [ "$output" = "1.1.0 (main@c61700a)" ]
}

@test "version helper uses the embedded version when the file is missing" {
  run get_install_version
  [ "$status" -eq 0 ]
  [ "$output" = "1.2.0 (unknown@unknown)" ]
}

@test "version helper uses the embedded version when the file is empty" {
  printf '\n' > "$SCRIPT_DIR/VERSION"
  run get_install_version
  [ "$status" -eq 0 ]
  [ "$output" = "1.2.0 (unknown@unknown)" ]
}

@test "embedded version matches the repository VERSION file" {
  local version
  IFS= read -r version < "$BATS_TEST_DIRNAME/../VERSION"
  [ "$PTZ_PATROL_VERSION" = "$version" ]
}

@test "version helper uses unknown for missing commit metadata" {
  printf '1.1.0\n' > "$SCRIPT_DIR/VERSION"
  printf 'ref=main\n' > "$SCRIPT_DIR/install-info"
  run get_install_version
  [ "$status" -eq 0 ]
  [ "$output" = "1.1.0 (main@unknown)" ]
}

@test "version helper uses unknown when only VERSION exists" {
  printf '1.1.0\n' > "$SCRIPT_DIR/VERSION"
  run get_install_version
  [ "$status" -eq 0 ]
  [ "$output" = "1.1.0 (unknown@unknown)" ]
}

@test "version helper strips CRLF from VERSION and install metadata" {
  printf '1.1.0\r\n' > "$SCRIPT_DIR/VERSION"
  printf 'ref=local\r\ncommit=c61700a8f1f16ac621e5896c11eb3c9021643c74\r\ndirty=true\r\n' > "$SCRIPT_DIR/install-info"
  run get_install_version
  [ "$status" -eq 0 ]
  [ "$output" = "1.1.0 (local@c61700a-dirty)" ]
}

@test "version helper validates commit before displaying it" {
  printf '1.1.0\n' > "$SCRIPT_DIR/VERSION"
  printf 'ref=main\ncommit=not-a-sha\n' > "$SCRIPT_DIR/install-info"
  run get_install_version
  [ "$status" -eq 0 ]
  [ "$output" = "1.1.0 (main@unknown)" ]
}

@test "version helper appends dirty marker to a valid local commit" {
  printf '1.1.0\n' > "$SCRIPT_DIR/VERSION"
  printf 'ref=local\ncommit=c61700a8f1f16ac621e5896c11eb3c9021643c74\ndirty=true\n' > "$SCRIPT_DIR/install-info"
  run get_install_version
  [ "$status" -eq 0 ]
  [ "$output" = "1.1.0 (local@c61700a-dirty)" ]
}
