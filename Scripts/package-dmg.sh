#!/usr/bin/env bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
cd "$DIR"

BUILD_DIR="$DIR/build"
APP_DIR="$BUILD_DIR/FanControl.app"
DMG_DIR="$BUILD_DIR/dmg_staging"
OUTPUT_DMG="$BUILD_DIR/FanControl-Installer.dmg"

echo "📦 Building FanControl.app first..."
./Scripts/build.sh

echo "📦 Creating DMG staging folder..."
rm -rf "$DMG_DIR" "$OUTPUT_DMG"
mkdir -p "$DMG_DIR"

cp -R "$APP_DIR" "$DMG_DIR/"
ln -s /Applications "$DMG_DIR/Applications"

echo "📦 Packaging distribution archive with ditto..."
OUTPUT_ZIP="$BUILD_DIR/FanControl.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$OUTPUT_ZIP"
echo "✅ Universal ZIP archive created: $OUTPUT_ZIP"

echo "💿 Attempting DMG creation..."
if hdiutil create -volname "FanControl" -srcfolder "$DMG_DIR" -ov -format UDZO "$OUTPUT_DMG" 2>/dev/null; then
    echo "✅ DMG Installer created successfully: $OUTPUT_DMG"
else
    echo "ℹ️  DMG creation skipped (requires unsandboxed environment). Using $OUTPUT_ZIP for distribution."
fi

rm -rf "$DMG_DIR"
