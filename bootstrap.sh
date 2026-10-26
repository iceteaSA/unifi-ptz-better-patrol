#!/bin/bash
# Download a complete checkout into a private staging directory, then run the wizard.
set -euo pipefail
umask 077
repo=${PTZ_PATROL_REPO:-iceteaSA/unifi-ptz-better-patrol}
ref=${PTZ_PATROL_REF:-main}
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo 'Invalid repository'; exit 1; }
[[ "$ref" =~ ^[A-Za-z0-9_./-]+$ && "$ref" != *..* ]] || { echo 'Invalid ref'; exit 1; }
[[ -r /dev/tty ]] || { echo 'Interactive terminal required'; exit 1; }
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
base="https://raw.githubusercontent.com/$repo/$ref"
for file in install.sh setup.sh api.sh discover.sh patrol.sh ptz-patrol.sh uninstall.sh config.json.example ptz-patrol.service; do
    curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
        --connect-timeout 10 --max-time 60 "$base/$file" -o "$stage/$file"
done
# A pipe supplies script bytes, so prompts must read the controlling terminal.
bash "$stage/install.sh" </dev/tty
