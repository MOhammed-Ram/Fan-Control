#!/usr/bin/env bash
set -e

if [ "$EUID" -ne 0 ]; then
    echo "❌ Please run as root: sudo ./Scripts/uninstall-helper.sh"
    exit 1
fi

PLIST_PATH="/Library/LaunchDaemons/com.fancontrol.helper.plist"
INSTALL_BIN="/Library/PrivilegedHelperTools/com.fancontrol.helper"

launchctl unload "$PLIST_PATH" 2>/dev/null || true
rm -f "$PLIST_PATH"
rm -f "$INSTALL_BIN"
rm -f /var/run/fancontrol_helper.sock /tmp/fancontrol_helper.sock

echo "✅ Helper daemon cleanly uninstalled."
