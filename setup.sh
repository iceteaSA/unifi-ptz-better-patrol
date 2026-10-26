#!/bin/bash
# Interactive configuration; never prints or passes the key in process arguments.
set -euo pipefail
umask 077
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.json"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

if [[ -f "$CONFIG_FILE" ]]; then
    read -r -p 'Keep existing configuration? [Y/n]: ' answer
    if [[ "$answer" != [nN] ]]; then
        bash "$SCRIPT_DIR/discover.sh"
        exit
    fi
fi
echo '1) Site Manager API key (cloud)'
echo '2) Local administrator (LAN)'
read -r -p 'Authentication [1]: ' mode
case "${mode:-1}" in
  1) ;;
  2)
    read -r -p 'NVR URL (for example https://127.0.0.1): ' address
    [[ "$address" =~ ^https://[^[:space:]]+$ ]] || { echo 'An HTTPS URL is required'; exit 1; }
    read -r -p 'Local administrator username: ' username
    read -r -s -p 'Local administrator password: ' password
    printf '\n'
    [[ -n "$username" && -n "$password" ]] || { echo 'Credentials cannot be empty'; exit 1; }
    printf '%s' "$address" > "$work/address"
    printf '%s' "$username" > "$work/username"
    printf '%s' "$password" > "$work/password"
    unset password
    jq --rawfile address "$work/address" --rawfile username "$work/username" --rawfile password "$work/password" '
      .auth_mode = "local" | .nvr_address = $address | .username = $username | .password = $password
      | del(.api_key, .console_id) | .defaults.dynamic_auto_tracking = true | .camera_overrides = {}
    ' "$SCRIPT_DIR/config.json.example" > "$work/config.json"
    ;;
  *) echo 'Invalid authentication choice'; exit 1 ;;
esac
if [[ "${mode:-1}" == 1 ]]; then
read -r -s -p 'Site Manager API key: ' key
printf '\n'
[[ "$key" =~ ^[A-Za-z0-9._-]+$ ]] || { echo 'Invalid key format'; exit 1; }
printf '%s' "$key" > "$work/key"
printf 'X-API-Key: %s\n' "$key" > "$work/header"
unset key
# Follow all pages before presenting numbered hosts.
printf '[]' > "$work/hosts"
next=''
while :; do
    args=()
    [[ -z "$next" ]] || args=(--data-urlencode "nextToken=$next")
    curl --fail --silent --show-error --proto '=https' --connect-timeout 10 --max-time 30 \
        --header "@$work/header" --get "${args[@]}" \
        https://api.ui.com/v1/hosts -o "$work/page"
    jq -e '.data | type == "array"' "$work/page" >/dev/null || { echo 'Unexpected hosts response'; exit 1; }
    jq -s '.[0] + .[1].data' "$work/hosts" "$work/page" > "$work/merged"
    mv "$work/merged" "$work/hosts"
    token=$(jq -r '.nextToken // empty' "$work/page")
    [[ -n "$token" ]] || break
    [[ "$token" != "$next" ]] || { echo 'Repeated pagination token'; exit 1; }
    next=$token
 done
count=$(jq length "$work/hosts")
(( count > 0 )) || { echo 'No hosts accessible with this key. Check its organization.'; exit 1; }
jq -r 'to_entries[] | "\(.key + 1)) \(.value.reportedState.name // .value.name // .value.id)  [\(.value.id)]"' "$work/hosts"
while :; do
    read -r -p "Choose host [1-$count]: " choice
    [[ "$choice" =~ ^[1-9][0-9]*$ ]] && (( choice <= count )) && break
    echo 'Enter a listed number.'
done
jq -r --argjson n "$choice" '.[$n - 1].id' "$work/hosts" > "$work/console"
jq --rawfile key "$work/key" --rawfile console "$work/console" '
    .auth_mode = "cloud" | .api_key = $key | .console_id = ($console | rtrimstr("\n"))
    | .defaults.dynamic_auto_tracking = true
    | .camera_overrides = {} | del(.username, .password)
' "$SCRIPT_DIR/config.json.example" > "$work/config.json"
fi
# Probe with a temporary configuration before replacing a working one.
CONFIG_FILE="$work/config.json" bash "$SCRIPT_DIR/discover.sh"
CONFIG_FILE="$work/config.json" bash -c '
    source "$1/discover.sh"
    api_init
    api_auth
    discover_ptz_cameras
' bash "$SCRIPT_DIR" > "$work/cameras"
jq -e 'length > 0 and all(.[]; .preset_count >= 2)' "$work/cameras" >/dev/null || {
    echo 'Each detected PTZ camera needs at least two saved presets. Configuration not changed.'; exit 1;
}
echo 'Defaults: all detected PTZ cameras and presets, 30s dwell, 15s motion hold, 120s manual hold, person tracking enabled.'
read -r -p 'Save this configuration? [Y/n]: ' answer
[[ "$answer" != [nN] ]] || exit 1
[[ ! -f "$CONFIG_FILE" ]] || cp -p "$CONFIG_FILE" "$CONFIG_FILE.backup.$(date +%Y%m%d%H%M%S)"
install -m 600 "$work/config.json" "$SCRIPT_DIR/config.json.new"
mv "$SCRIPT_DIR/config.json.new" "$CONFIG_FILE"
echo 'Configuration saved.'
