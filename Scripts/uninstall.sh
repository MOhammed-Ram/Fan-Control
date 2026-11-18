#!/usr/bin/env bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
cd "$DIR"

echo "════════════════════════════════════════════════════════════"
echo "        FanControl Uninstaller                              "
echo "════════════════════════════════════════════════════════════"

echo "🛑 Stopping FanControl..."
killall FanControl 2>/dev/null || true

# 1. Reset fans to auto hardware default
echo "🔄 Resetting fans to macOS hardware default..."
if [ -f "$DIR/build/bin/fan-curve-ctl" ]; then
    "$DIR/build/bin/fan-curve-ctl" auto 2>/dev/null || true
fi

# 2. Uninstall helper daemon
echo "🗑️  Removing Privileged Helper Daemon..."
if [ "$EUID" -eq 0 ]; then
    bash "$DIR/Scripts/uninstall-helper.sh"
else
    sudo bash "$DIR/Scripts/uninstall-helper.sh"
fi

# 3. Remove user LaunchAgent
echo "🗑️  Removing user LaunchAgent..."
AGENT_PLIST="$HOME/Library/LaunchAgents/com.macfancontrol.curveapp.plist"
if [ -f "$AGENT_PLIST" ]; then
    launchctl unload "$AGENT_PLIST" 2>/dev/null || true
    rm -f "$AGENT_PLIST"
fi

# 4. Remove /Applications/FanControl.app
echo "🗑️  Removing /Applications/FanControl.app..."
if [ -d "/Applications/FanControl.app" ]; then
    if [ -w "/Applications" ]; then
        rm -rf "/Applications/FanControl.app"
    else
        sudo rm -rf "/Applications/FanControl.app"
    fi
fi

echo "════════════════════════════════════════════════════════════"
echo "✅ FanControl cleanly uninstalled."
echo "════════════════════════════════════════════════════════════"
