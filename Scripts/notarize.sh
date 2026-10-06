#!/usr/bin/env bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
cd "$DIR"

BUILD_DIR="$DIR/build"
APP_DIR="$BUILD_DIR/FanControl.app"
ZIP_PATH="$BUILD_DIR/FanControl.zip"
ENTITLEMENTS="$DIR/Sources/App/Resources/FanControl.entitlements"

echo "🔐 Fan Control Notarization Script"
echo "=================================="

SIGNING_IDENTITY="$1"
KEYCHAIN_PROFILE="$2"

if [ -z "$SIGNING_IDENTITY" ]; then
    echo "Usage:"
    echo "  ./Scripts/notarize.sh \"Developer ID Application: Your Name (TEAM_ID)\" <keychain_profile_name>"
    echo ""
    echo "Example using stored notarytool credentials:"
    echo "  1. Store credentials once:"
    echo "     xcrun notarytool store-credentials \"notary-profile\" --apple-id \"your@apple.id\" --team-id \"TEAM_ID\" --password \"app-specific-pw\""
    echo "  2. Run:"
    echo "     ./Scripts/notarize.sh \"Developer ID Application: Your Name (TEAM_ID)\" \"notary-profile\""
    exit 1
fi

echo "1️⃣  Building and signing with Hardened Runtime..."
./Scripts/build.sh

echo "2️⃣  Signing Helper Tool..."
codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP_DIR/Contents/Resources/fan-control-helper"

echo "3️⃣  Signing App Bundle with Entitlements..."
codesign --force --deep --options runtime --timestamp --entitlements "$ENTITLEMENTS" --sign "$SIGNING_IDENTITY" "$APP_DIR"

echo "4️⃣  Packaging for Notarization..."
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP_PATH"

if [ -n "$KEYCHAIN_PROFILE" ]; then
    echo "5️⃣  Submitting to Apple Notary Service..."
    xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$KEYCHAIN_PROFILE" --wait

    echo "6️⃣  Stapling Notarization Ticket to App..."
    xcrun stapler staple "$APP_DIR"
    echo "✅ Stapling complete! Gatekeeper will trust this app instantly on any Mac."
else
    echo "ℹ️  Signed with Hardened Runtime. Ready for submission via notarytool."
fi
