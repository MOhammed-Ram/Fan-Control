#!/usr/bin/env bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
cd "$DIR"

BUILD_DIR="$DIR/build"
CACHE_DIR="$BUILD_DIR/cache"
BIN_DIR="$BUILD_DIR/bin"
APP_DIR="$BUILD_DIR/FanControl.app"

mkdir -p "$BUILD_DIR" "$CACHE_DIR" "$BIN_DIR" "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

echo "🔨 [1/5] Compiling CSMCBridge (SMC & HID Sensors)..."
clang -c -O2 \
    -framework Foundation -framework IOKit \
    Sources/Bridge/CSMCBridge.m \
    -o "$BUILD_DIR/CSMCBridge.o"

echo "🔨 [2/5] Compiling fan-control-helper (Privileged Daemon)..."
swiftc -O \
    -module-cache-path "$CACHE_DIR" \
    -import-objc-header Sources/Bridge/CSMCBridge.h \
    Sources/Helper/main.swift \
    "$BUILD_DIR/CSMCBridge.o" \
    -framework Foundation -framework IOKit \
    -o "$BIN_DIR/fan-control-helper"

echo "🔨 [3/5] Compiling fan-curve-ctl (CLI Tool)..."
swiftc -O \
    -module-cache-path "$CACHE_DIR" \
    -import-objc-header Sources/Bridge/CSMCBridge.h \
    Sources/Common/Models.swift \
    Sources/Common/CurveEngine.swift \
    Sources/Common/HelperClient.swift \
    Sources/CLI/main.swift \
    "$BUILD_DIR/CSMCBridge.o" \
    -framework Foundation -framework IOKit \
    -o "$BIN_DIR/fan-curve-ctl"

echo "🔨 [4/5] Compiling FanControl.app (GUI & Menu Bar Application)..."
swiftc -O \
    -module-cache-path "$CACHE_DIR" \
    -import-objc-header Sources/Bridge/CSMCBridge.h \
    Sources/Common/Models.swift \
    Sources/Common/CurveEngine.swift \
    Sources/Common/HelperClient.swift \
    Sources/Common/FanManager.swift \
    Sources/App/Views/SettingsSheetView.swift \
    Sources/App/Views/ProfileSelectorView.swift \
    Sources/App/Views/TelemetryDashboard.swift \
    Sources/App/Views/CurveEditorView.swift \
    Sources/App/Views/ContentView.swift \
    Sources/App/MenuBar/MenuBarPopoverView.swift \
    Sources/App/MenuBar/MenuBarController.swift \
    Sources/App/MainApp.swift \
    "$BUILD_DIR/CSMCBridge.o" \
    -framework Foundation -framework IOKit -framework AppKit -framework SwiftUI \
    -o "$APP_DIR/Contents/MacOS/FanControl"

echo "🔨 [5/5] Packaging App Bundle and Helpers..."
cat << 'EOF' > "$APP_DIR/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>FanControl</string>
    <key>CFBundleIdentifier</key>
    <string>com.macfancontrol.curveapp</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>FanControl</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.1.0</string>
    <key>CFBundleVersion</key>
    <string>2</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSUIElement</key>
    <false/>
</dict>
</plist>
EOF

cp "$DIR/Scripts/install-helper.sh" "$APP_DIR/Contents/Resources/install-helper.sh"
cp "$BIN_DIR/fan-control-helper" "$APP_DIR/Contents/Resources/fan-control-helper" 2>/dev/null || true
chmod +x "$APP_DIR/Contents/Resources/install-helper.sh" 2>/dev/null || true

codesign --force --deep --sign - "$APP_DIR" 2>/dev/null || true
codesign --force --sign - "$BIN_DIR/fan-curve-ctl" 2>/dev/null || true
codesign --force --sign - "$BIN_DIR/fan-control-helper" 2>/dev/null || true

echo "✅ Build complete!"
echo "   GUI & Menu Bar App: $APP_DIR"
echo "   Privileged Helper:  $BIN_DIR/fan-control-helper"
echo "   CLI Utility:        $BIN_DIR/fan-curve-ctl"
