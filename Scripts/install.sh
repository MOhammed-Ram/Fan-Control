#!/usr/bin/env bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
cd "$DIR"

echo "════════════════════════════════════════════════════════════"
echo "        FanControl Installer for macOS (Apple Silicon)     "
echo "════════════════════════════════════════════════════════════"

# 1. Build application bundle and helpers
echo "🔨 [1/4] Building latest FanControl.app and daemons..."
./Scripts/build.sh

# 2. Install to /Applications
APP_SRC="$DIR/build/FanControl.app"
APP_DEST="/Applications/FanControl.app"

echo "📦 [2/4] Installing FanControl.app to /Applications..."
killall FanControl 2>/dev/null || true
sleep 0.5

if [ -w "/Applications" ]; then
    rm -rf "$APP_DEST"
    cp -R "$APP_SRC" "$APP_DEST"
else
    echo "🔐 Admin authorization required to install to /Applications..."
    sudo rm -rf "$APP_DEST"
    sudo cp -R "$APP_SRC" "$APP_DEST"
fi

# 3. Install Privileged Helper
echo "🛡️  [3/4] Installing Privileged Helper Daemon..."
if [ "$EUID" -eq 0 ]; then
    bash "$DIR/Scripts/install-helper.sh"
else
    sudo bash "$DIR/Scripts/install-helper.sh"
fi

# 4. Launch App in Background
echo "🚀 [4/4] Launching FanControl in background..."
open "$APP_DEST" --args --background

echo "════════════════════════════════════════════════════════════"
echo "✅ FanControl installation complete!"
echo "   • Application:       /Applications/FanControl.app"
echo "   • Privileged Daemon: /Library/PrivilegedHelperTools/com.fancontrol.helper"
echo "   • Status:            Running in background (Top Menu Bar)"
echo "════════════════════════════════════════════════════════════"
