#!/bin/bash
set -e

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

SERVICE_NAME="ptz-patrol"
INSTALL_DIR="/data/ptz-patrol"
ONBOOT_SCRIPT="/data/on_boot.d/10-ptz-patrol.sh"

# Stop and disable service
echo "Stopping service..."
systemctl stop "$SERVICE_NAME.service" 2>/dev/null || true
systemctl disable "$SERVICE_NAME.service" 2>/dev/null || true

# Remove system files
echo "Removing system files..."
rm -f "/etc/systemd/system/$SERVICE_NAME.service" || echo "Warning: Could not remove service file"
rm -f "$ONBOOT_SCRIPT" || echo "Warning: Could not remove on_boot.d hook"

# Remove data files
echo "Removing data files..."
if [ -d "$INSTALL_DIR" ]; then
    rm -rf "$INSTALL_DIR" || {
        echo "Warning: Could not remove data directory"
        echo "You may need to manually remove $INSTALL_DIR"
    }
else
    echo "Data directory not found, skipping"
fi

# Reload systemd
systemctl daemon-reload

echo "Uninstallation complete. All components removed."

# probe: unquoted expansion must fail shellcheck
probe_fn() { local x; x=$1; echo $x; }
