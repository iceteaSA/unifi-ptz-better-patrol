#!/bin/bash
set -e
umask 077

# Check for root privileges
if [ "$(id -u)" -ne 0 ]; then
    echo "Error: This script must be run as root (sudo)"
    exit 1
fi

# Check for systemd availability
if ! command -v systemctl >/dev/null 2>&1; then
    echo "Error: systemd is required but not found"
    exit 1
fi

# Check for curl availability
if ! command -v curl >/dev/null 2>&1; then
    echo "Error: curl is required but not found"
    exit 1
fi

INSTALL_DIR="/data/ptz-patrol"
SERVICE_NAME="ptz-patrol"
ONBOOT_DIR="/data/on_boot.d"
ONBOOT_SCRIPT="$ONBOOT_DIR/10-ptz-patrol.sh"

case "${1:-}" in
    ""|--bootstrap) ;;
    *) echo 'Usage: bash install.sh [--bootstrap]'; exit 1 ;;
esac

echo "Installing bundled cloud adaptation"

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Create install directory
mkdir -p "$INSTALL_DIR" || {
    echo "Error: Failed to create directory $INSTALL_DIR"
    exit 1
}

# Check if directory is writable
if [ ! -w "$INSTALL_DIR" ]; then
    echo "Error: Directory $INSTALL_DIR is not writable"
    exit 1
fi

# Install dependencies
install_deps() {
    local missing=()
    command -v jq   &>/dev/null || missing+=(jq)
    command -v curl &>/dev/null || missing+=(curl)

    if (( ${#missing[@]} > 0 )); then
        echo "Installing dependencies: ${missing[*]}"
        apt-get update -qq
        apt-get install -y -qq "${missing[@]}"
    else
        echo "Dependencies satisfied"
    fi
}

# Function to get a file from local directory or download from GitHub
get_file() {
    local filename="$1"
    local destination="$2"

    # Never download upstream files over this adapted build.
    if [[ ! -f "$SCRIPT_DIR/$filename" ]]; then
        echo "Missing bundled file: $filename"
        exit 1
    fi
    if [[ "$(realpath "$SCRIPT_DIR/$filename")" != "$(realpath -m "$destination")" ]]; then
        cp "$SCRIPT_DIR/$filename" "$destination"
    fi
}

# Bootstrap mode: re-install deps and service after firmware update
if [[ "${1:-}" == "--bootstrap" ]]; then
    echo "=== Bootstrap ==="
    install_deps
    if [ ! -f "/etc/systemd/system/$SERVICE_NAME.service" ]; then
        get_file "ptz-patrol.service" "/etc/systemd/system/$SERVICE_NAME.service"
        systemctl daemon-reload
        systemctl enable "$SERVICE_NAME"
    fi
    exit 0
fi

echo "=== PTZ Patrol Installer ==="
install_deps

# Configure and validate before replacing installed runtime files.
if [[ "$SCRIPT_DIR" != "$INSTALL_DIR" && -f "$INSTALL_DIR/config.json" ]]; then
    cp -p "$INSTALL_DIR/config.json" "$SCRIPT_DIR/config.json"
fi
bash "$SCRIPT_DIR/setup.sh"
if systemctl is-active --quiet "$SERVICE_NAME.service"; then
    systemctl stop "$SERVICE_NAME.service"
fi

# Install script files
for f in install.sh setup.sh config.json.example ptz-patrol.service api.sh discover.sh patrol.sh ptz-patrol.sh; do
    get_file "$f" "$INSTALL_DIR/$f"
    chmod +x "$INSTALL_DIR/$f"
done

# Install uninstall script
get_file "uninstall.sh" "$INSTALL_DIR/uninstall.sh"
chmod +x "$INSTALL_DIR/uninstall.sh"

get_file "config.json" "$INSTALL_DIR/config.json"
# Install systemd service
SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME.service"
get_file "ptz-patrol.service" "$SERVICE_FILE"

# Verify service file was created
if [ ! -f "$SERVICE_FILE" ]; then
    echo "Error: Failed to create service file"
    exit 1
fi

# Reload systemd
echo "Reloading systemd configuration..."
systemctl daemon-reload || {
    echo "Error: Failed to reload systemd configuration"
    exit 1
}

chmod 600 "$INSTALL_DIR/config.json"
echo 'Starting patrol changes camera tracking and return-home settings.'
read -r -p 'Start patrol now and enable it at boot? [Y/n]: ' answer
if [[ "$answer" != [nN] ]]; then
    mkdir -p "$ONBOOT_DIR"
    cat > "$ONBOOT_SCRIPT" <<'BOOT'
#!/bin/bash
/data/ptz-patrol/install.sh --bootstrap && systemctl restart ptz-patrol
BOOT
    chmod 700 "$ONBOOT_SCRIPT"
    systemctl enable --now "$SERVICE_NAME.service"
    systemctl --no-pager status "$SERVICE_NAME.service"
else
    systemctl disable "$SERVICE_NAME.service" 2>/dev/null || true
    rm -f "$ONBOOT_SCRIPT"
    echo 'Installed, patrol stopped. Start later with systemctl enable --now ptz-patrol.service'
fi
