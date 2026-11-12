# shellcheck disable=SC1091
source "$BATS_TEST_DIRNAME/../discover.sh"
setup() {
  export cameras='[{"id":"a1","name":"Shared","is_ptz":true},{"id":"b2","name":"Shared","is_ptz":true},{"id":"c3","name":"Other","is_ptz":true}]'
}
