# shellcheck disable=SC1091
source "$BATS_TEST_DIRNAME/test_helper.bash"
source "$BATS_TEST_DIRNAME/../discover.sh"
setup() {
  SCRIPT_DIR="$BATS_TEST_TMPDIR/version"
  mkdir -p "$SCRIPT_DIR"
}
