#!/usr/bin/env bash
set -e

if [ "$EUID" -ne 0 ]; then
    echo "❌ Please run as root: sudo ./Scripts/install-helper.sh"
    exit 1
fi

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Robust binary resolution
if [ -f "$SCRIPT_DIR/fan-control-helper" ]; then
    BIN_SRC="$SCRIPT_DIR/fan-control-helper"
elif [ -f "$SCRIPT_DIR/../build/bin/fan-control-helper" ]; then
    BIN_SRC="$SCRIPT_DIR/../build/bin/fan-control-helper"
elif [ -f "$SCRIPT_DIR/bin/fan-control-helper" ]; then
    BIN_SRC="$SCRIPT_DIR/bin/fan-control-helper"
elif [ -f "/Applications/FanControl.app/Contents/Resources/fan-control-helper" ]; then
    BIN_SRC="/Applications/FanControl.app/Contents/Resources/fan-control-helper"
else
    echo "❌ Error: Could not locate fan-control-helper binary."
    exit 1
fi

INSTALL_DIR="/Library/PrivilegedHelperTools"
INSTALL_BIN="$INSTALL_DIR/com.fancontrol.helper"
PLIST_PATH="/Library/LaunchDaemons/com.fancontrol.helper.plist"

mkdir -p "$INSTALL_DIR"
cp -f "$BIN_SRC" "$INSTALL_BIN"
chmod 755 "$INSTALL_BIN"
chown root:wheel "$INSTALL_BIN"

cat << EOF > "$PLIST_PATH"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.fancontrol.helper</string>
    <key>ProgramArguments</key>
    <array>
        <string>$INSTALL_BIN</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/var/log/fancontrol_helper.log</string>
    <key>StandardErrorPath</key>
    <string>/var/log/fancontrol_helper.err</string>
</dict>
</plist>
EOF

chmod 644 "$PLIST_PATH"
chown root:wheel "$PLIST_PATH"

# Unload any prior instance cleanly
launchctl unload "$PLIST_PATH" 2>/dev/null || true
killall com.fancontrol.helper 2>/dev/null || true
killall fan-control-helper 2>/dev/null || true

# Load and start daemon
launchctl load -w "$PLIST_PATH"

echo "✅ Helper successfully installed and loaded into launchd."
