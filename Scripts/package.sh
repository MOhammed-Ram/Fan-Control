#!/usr/bin/env bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
cd "$DIR"

BUILD_DIR="$DIR/build"
APP_DIR="$BUILD_DIR/FanControl.app"
HELPER_BIN="$BUILD_DIR/bin/fan-control-helper"
DIST_DIR="$BUILD_DIR/dist"

export COPYFILE_DISABLE=1

echo "════════════════════════════════════════════════════════════"
echo "        FanControl Distribution Package Builder             "
echo "════════════════════════════════════════════════════════════"

# 1. Build binaries and app bundle
echo "🔨 [1/5] Building latest FanControl binaries & app..."
./Scripts/build.sh

mkdir -p "$DIST_DIR"

# 2. Build .pkg installer (One-click complete installer)
echo "📦 [2/5] Creating native macOS Installer Package (.pkg)..."
PKG_STAGING="$BUILD_DIR/pkg_staging"
rm -rf "$PKG_STAGING"
mkdir -p "$PKG_STAGING/root/Applications"
mkdir -p "$PKG_STAGING/root/Library/PrivilegedHelperTools"
mkdir -p "$PKG_STAGING/root/Library/LaunchDaemons"
mkdir -p "$PKG_STAGING/scripts"

cp -R "$APP_DIR" "$PKG_STAGING/root/Applications/"
cp -f "$HELPER_BIN" "$PKG_STAGING/root/Library/PrivilegedHelperTools/com.fancontrol.helper"

cat << 'EOF' > "$PKG_STAGING/root/Library/LaunchDaemons/com.fancontrol.helper.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.fancontrol.helper</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Library/PrivilegedHelperTools/com.fancontrol.helper</string>
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

cat << 'EOF' > "$PKG_STAGING/scripts/postinstall"
#!/usr/bin/env bash
set -e

# Terminate previous app instance if running so upgrade replaces it cleanly
killall FanControl 2>/dev/null || true

# Remove any AppleDouble resource fork files in system directories
rm -f /Library/PrivilegedHelperTools/._com.fancontrol.helper 2>/dev/null || true
rm -f /Library/LaunchDaemons/._com.fancontrol.helper.plist 2>/dev/null || true

# Secure permissions on helper tool
chown root:wheel /Library/PrivilegedHelperTools/com.fancontrol.helper 2>/dev/null || true
chmod 755 /Library/PrivilegedHelperTools/com.fancontrol.helper 2>/dev/null || true

# Secure permissions on launch daemon plist
chown root:wheel /Library/LaunchDaemons/com.fancontrol.helper.plist 2>/dev/null || true
chmod 644 /Library/LaunchDaemons/com.fancontrol.helper.plist 2>/dev/null || true

# Unload previous instance if running
launchctl unload /Library/LaunchDaemons/com.fancontrol.helper.plist 2>/dev/null || true
killall com.fancontrol.helper 2>/dev/null || true
killall fan-control-helper 2>/dev/null || true

# Load launch daemon
launchctl load -w /Library/LaunchDaemons/com.fancontrol.helper.plist 2>/dev/null || true

# Relaunch updated app in background as active console user
CONSOLE_USER=$(stat -f "%Su" /dev/console 2>/dev/null || true)
if [ -n "$CONSOLE_USER" ] && [ "$CONSOLE_USER" != "root" ] && [ "$CONSOLE_USER" != "loginwindow" ]; then
    su - "$CONSOLE_USER" -c "open -a /Applications/FanControl.app --args --background" 2>/dev/null || true
fi

exit 0
EOF
chmod +x "$PKG_STAGING/scripts/postinstall"

xattr -cr "$PKG_STAGING" 2>/dev/null || true
dot_clean "$PKG_STAGING" 2>/dev/null || true
find "$PKG_STAGING" -name "._*" -delete 2>/dev/null || true

OUTPUT_PKG="$DIST_DIR/FanControl-Installer.pkg"
pkgbuild --root "$PKG_STAGING/root" \
         --scripts "$PKG_STAGING/scripts" \
         --filter "/\._" \
         --identifier "com.macfancontrol.curveapp" \
         --version "1.6.0" \
         --install-location "/" \
         "$OUTPUT_PKG"

rm -rf "$PKG_STAGING"
echo "✅ PKG Installer created: $OUTPUT_PKG"

# 3. Create .dmg Disk Image
echo "💿 [3/5] Creating shareable Disk Image (.dmg)..."
DMG_STAGING="$BUILD_DIR/dmg_staging"
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"

cp -R "$APP_DIR" "$DMG_STAGING/"
cp "$OUTPUT_PKG" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"

cat << 'EOF' > "$DMG_STAGING/README.txt"
════════════════════════════════════════════════════════════
    Fan Control for macOS (Apple Silicon M1/M2/M3/M4)
════════════════════════════════════════════════════════════

How to install:

Option 1 (Recommended - Complete Automatic Setup):
  Double-click "FanControl-Installer.pkg" and follow the installer wizard.
  This automatically installs FanControl.app to /Applications and sets up
  the privileged hardware helper daemon so fan curves work immediately.

Option 2 (Drag & Drop):
  Drag "FanControl.app" into the "Applications" folder shortcut.
  When opening the app for the first time, go to Preferences (Gear Icon)
  and click "Install / Activate Helper Tool" to enable hardware fan control.

Features:
  • Real-time SoC Die Temperature Monitoring (P-Cores, E-Cores, GPU, Heatsink)
  • Dynamic Curve Editor with live RPM tracking & multi-point spline
  • Background Execution: Runs silently in the top Menu Bar
  • Thermal Overheat Safety Guards with automatic 100% ramp emergency failsafe
  • Acoustic Slew Rate Limiting for quiet, whisper-smooth fan acceleration

Enjoy!
EOF

dot_clean "$DMG_STAGING" 2>/dev/null || true

RAW_DMG="$BUILD_DIR/FanControl_raw.dmg"
FINAL_DMG="$DIST_DIR/FanControl.dmg"

rm -f "$RAW_DMG" "$FINAL_DMG"
hdiutil makehybrid -hfs -hfs-volume-name "FanControl" -o "$RAW_DMG" "$DMG_STAGING"
hdiutil convert "$RAW_DMG" -format UDZO -o "$FINAL_DMG"
rm -f "$RAW_DMG"
rm -rf "$DMG_STAGING"
echo "✅ DMG Installer created: $FINAL_DMG"

# 4. Create .zip Archive
echo "📦 [4/5] Creating portable ZIP archive..."
OUTPUT_ZIP="$DIST_DIR/FanControl.zip"
rm -f "$OUTPUT_ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$OUTPUT_ZIP"
echo "✅ ZIP Archive created: $OUTPUT_ZIP"

# 5. Summary
echo "════════════════════════════════════════════════════════════"
echo "🎉 Distribution files ready in build/dist/:"
echo "   1. Disk Image (.dmg):        $FINAL_DMG"
echo "   2. Installer Package (.pkg): $OUTPUT_PKG"
echo "   3. Portable Zip (.zip):      $OUTPUT_ZIP"
echo "════════════════════════════════════════════════════════════"
