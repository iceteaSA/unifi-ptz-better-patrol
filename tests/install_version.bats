load install_version_helper

@test "version helper combines the version and install commit" {
  printf '1.1.0\n' > "$SCRIPT_DIR/VERSION"
  printf 'ref=main\ncommit=c61700a8f1f16ac621e5896c11eb3c9021643c74\n' > "$SCRIPT_DIR/install-info"
  run get_install_version
  [ "$status" -eq 0 ]
  [ "$output" = "1.1.0 (main@c61700a)" ]
}

@test "version helper reports missing version and metadata as unknown" {
  run get_install_version
  [ "$status" -eq 0 ]
  [ "$output" = "unknown (unknown@unknown)" ]
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
