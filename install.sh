#!/bin/bash
set -e

# Repository information
REPO_OWNER="iceteaSA"
REPO_NAME="unifi-ptz-better-patrol"
BRANCH="${PTZ_PATROL_BRANCH:-main}"
BASE_URL="https://raw.githubusercontent.com/$REPO_OWNER/$REPO_NAME/$BRANCH"

if [[ "$BRANCH" != "main" ]]; then
    echo "WARNING: Installing unverified code from branch '$BRANCH' fetched directly from GitHub."
fi

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

# --- Parse optional arguments ---
ARG_NVR=""
ARG_USER=""
ARG_PASS=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --bootstrap) break ;;  # handled separately below
        --nvr)       ARG_NVR="$2"; shift 2 ;;
        --username)  ARG_USER="$2"; shift 2 ;;
        --password)  ARG_PASS="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: install.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --nvr ADDRESS      NVR address (e.g. https://10.0.0.1)"
            echo "  --username USER    Local admin username"
            echo "  --password PASS    Local admin password"
            echo "  --bootstrap        Re-install deps/service after firmware update"
            echo "  --help             Show this help"
            echo ""
            echo "Environment:"
            echo "  PTZ_PATROL_BRANCH  Install from a specific branch (default: main)"
            echo ""
            echo "Examples:"
            echo "  sudo bash install.sh --nvr https://10.0.0.1 --username patrol --password secret"
            echo "  PTZ_PATROL_BRANCH=dev sudo bash install.sh"
            exit 0
            ;;
        *)
            echo "Unknown option: $1 (use --help for usage)"
            exit 1
            ;;
    esac
done

echo "Installing from branch: $BRANCH"

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

    # Try to use local file first
    if [ -f "$SCRIPT_DIR/$filename" ]; then
        echo "Using local file: $filename"
        # Skip copy if source and destination are the same file
        if [ "$(realpath "$SCRIPT_DIR/$filename")" != "$(realpath "$destination" 2>/dev/null)" ]; then
            cp "$SCRIPT_DIR/$filename" "$destination"
        fi
    else
        echo "Downloading $filename from repository..."
        if ! curl -fsSL "$BASE_URL/$filename" -o "$destination"; then
            echo "Error: Failed to download $filename"
            exit 1
        fi
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

# Install script files
for f in api.sh discover.sh patrol.sh ptz-patrol.sh; do
    get_file "$f" "$INSTALL_DIR/$f"
    chmod +x "$INSTALL_DIR/$f"
done

# Install uninstall script
get_file "uninstall.sh" "$INSTALL_DIR/uninstall.sh"
chmod +x "$INSTALL_DIR/uninstall.sh"

# Install config
if [ ! -f "$INSTALL_DIR/config.json" ]; then
    get_file "config.json.example" "$INSTALL_DIR/config.json"
    if [ -z "$ARG_NVR" ] && [ -z "$ARG_USER" ] && [ -z "$ARG_PASS" ]; then
        echo "Config created — edit $INSTALL_DIR/config.json with your credentials"
    fi
else
    echo "Config already exists, not overwriting"
fi

# Apply credential args (works on both new and existing configs)
if [ -n "$ARG_NVR" ] || [ -n "$ARG_USER" ] || [ -n "$ARG_PASS" ]; then
    if ! command -v jq &>/dev/null; then
        echo "Error: jq is required to set config values"
        exit 1
    fi
    local_cfg="$INSTALL_DIR/config.json"
    tmp_cfg="$INSTALL_DIR/config.json.tmp"
    cp "$local_cfg" "$tmp_cfg"
    if ! jq . "$tmp_cfg" >/dev/null 2>&1; then
        echo "Error: $local_cfg is not valid JSON — cannot apply credential flags"
        rm -f "$tmp_cfg"
        exit 1
    fi
    if [ -n "$ARG_NVR" ]; then
        jq --arg v "$ARG_NVR" '.nvr_address = $v' "$tmp_cfg" > "$tmp_cfg.out" && mv "$tmp_cfg.out" "$tmp_cfg"
    fi
    if [ -n "$ARG_USER" ]; then
        jq --arg v "$ARG_USER" '.username = $v' "$tmp_cfg" > "$tmp_cfg.out" && mv "$tmp_cfg.out" "$tmp_cfg"
    fi
    if [ -n "$ARG_PASS" ]; then
        jq --arg v "$ARG_PASS" '.password = $v' "$tmp_cfg" > "$tmp_cfg.out" && mv "$tmp_cfg.out" "$tmp_cfg"
    fi
    mv "$tmp_cfg" "$local_cfg"
    echo "Config updated with provided credentials"
fi

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

# Install on_boot.d hook for firmware update survival
mkdir -p "$ONBOOT_DIR"
cat > "$ONBOOT_SCRIPT" <<'BOOT'
#!/bin/bash
# Re-bootstrap after firmware update wipes /etc and apt packages
/data/ptz-patrol/install.sh --bootstrap
systemctl restart ptz-patrol 2>/dev/null || true
BOOT
chmod +x "$ONBOOT_SCRIPT"
echo "on_boot.d hook installed"

# Smart service management
if systemctl is-active --quiet "$SERVICE_NAME.service"; then
    echo "Service already running — performing hot update"
    if ! systemctl restart "$SERVICE_NAME.service"; then
        echo "Error: Failed to restart service"
        echo "Check service status with: systemctl status $SERVICE_NAME.service"
        exit 1
    fi
    echo "Service successfully updated and restarted"
else
    echo "Performing fresh installation"
    if ! systemctl enable --now "$SERVICE_NAME.service"; then
        echo "Error: Failed to enable and start service"
        echo "Check service status with: systemctl status $SERVICE_NAME.service"
        exit 1
    fi
    echo "Service successfully enabled and started"
fi

echo ""
echo "Installation successful!"
echo "Configuration: nano $INSTALL_DIR/config.json"
echo "Discovery:     bash $INSTALL_DIR/discover.sh"
echo "Status check:  journalctl -u $SERVICE_NAME.service -f"
