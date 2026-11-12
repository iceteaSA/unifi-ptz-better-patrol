source "$BATS_TEST_DIRNAME/../discover.sh"
assert_contains() { [[ "$1" == *"$2"* ]]; }
assert_not_contains() { [[ "$1" != *"$2"* ]]; }
setup() {
  SCRIPT_DIR="$BATS_TEST_TMPDIR/version"
  mkdir -p "$SCRIPT_DIR"
}
