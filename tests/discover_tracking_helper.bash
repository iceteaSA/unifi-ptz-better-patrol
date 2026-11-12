# shellcheck disable=SC1091
source "$BATS_TEST_DIRNAME/../discover.sh"
assert_contains() { [[ "$1" == *"$2"* ]]; }
