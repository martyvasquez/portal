#!/bin/zsh
# Builds Portal.app, signs it, and (with --install) copies it to /Applications and relaunches.
#
#   scripts/build.sh            # build + sign into ./build/Portal.app
#   scripts/build.sh --install  # ...then install to /Applications and relaunch
#
# Signing with a stable certificate matters: macOS ties Accessibility and other
# permissions to the signature, so an ad-hoc signature would reset them every build
# (and every update). Local builds and CI both sign with the same Developer ID
# certificate, with the hardened runtime so builds can be notarized.
# Override with: SIGN_IDENTITY="Apple Development: …" scripts/build.sh
#
# Installed copies update themselves from GitHub Releases with Sparkle (see
# .github/workflows/release.yml). Build numbers are timestamps, so they always go up,
# whether built here or in CI; CI passes BUILD_NUMBER.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Portal"
BUNDLE_ID="com.martyvasquez.portal"
VERSION="0.1.0"
BUILD_NUMBER="${BUILD_NUMBER:-$(date -u +%Y%m%d%H%M)}"
# Releases are signed with "Developer ID Application: Marty Vasquez (G88C7HMHUJ)", picked by
# hash so a renewed or expired copy with the same name can't be chosen by accident.
# Anyone else's build uses their own Developer ID, else their Apple Development certificate.
RELEASE_IDENTITY="A5214E95171D52F564BB0644CEEDB997F0E3610A"
IDENTITIES="$(security find-identity -v -p codesigning)"
if [[ "$IDENTITIES" == *"$RELEASE_IDENTITY"* ]]; then
    DEFAULT_IDENTITY="$RELEASE_IDENTITY"
else
    DEFAULT_IDENTITY="$(awk -F'"' '/Developer ID Application/ {print $2; exit}' <<< "$IDENTITIES")"
    [[ -n "$DEFAULT_IDENTITY" ]] || DEFAULT_IDENTITY="$(awk -F'"' '/Apple Development/ {print $2; exit}' <<< "$IDENTITIES")"
fi
IDENTITY="${SIGN_IDENTITY-$DEFAULT_IDENTITY}"
FEED_URL="https://github.com/martyvasquez/portal/releases/latest/download/appcast.xml"
SPARKLE_PUBLIC_KEY="KW546Z8FbGbi9sVVMgDSKbkA6yHwmvep/p+j/ah/VBA="

# Universal, so it runs on Intel Macs too.
ARCHS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCHS[@]}"
BIN_DIR="$(swift build -c release "${ARCHS[@]}" --show-bin-path)"

APP="build/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
ditto "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
[[ -f Resources/AppIcon.icns ]] || swift scripts/make-icon.swift .
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAppleEventsUsageDescription</key><string>Portal asks Finder, Ghostty, and Terminal which folder you're in, and your browser which page you're on, to show matching snippets and open things with your apps.</string>
    <key>NSHumanReadableCopyright</key><string>© 2026 Marty Vasquez. MIT License.</string>
    <key>SUFeedURL</key><string>$FEED_URL</string>
    <key>SUPublicEDKey</key><string>$SPARKLE_PUBLIC_KEY</string>
    <key>SUEnableAutomaticChecks</key><true/>
    <key>SUAutomaticallyUpdate</key><true/>
    <key>SUScheduledCheckInterval</key><integer>14400</integer>
    <key>SUVerifyUpdateBeforeExtraction</key><true/>
</dict>
</plist>
PLIST

# Sparkle's helpers first, inside out, then the app. Developer ID builds get the hardened
# runtime and a secure timestamp, which notarization requires.
if [[ "$IDENTITY" == "$RELEASE_IDENTITY" || "$IDENTITY" == *"Developer ID"* ]]; then
    sign() { codesign --force --options runtime --timestamp --sign "$IDENTITY" "$@"; }
else
    sign() { codesign --force --timestamp=none --sign "${IDENTITY:--}" "$@"; }
fi
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
sign "$SPARKLE/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$SPARKLE/XPCServices/Downloader.xpc"
sign "$SPARKLE/Autoupdate"
sign "$SPARKLE/Updater.app"
sign "$APP/Contents/Frameworks/Sparkle.framework"
sign --identifier "$BUNDLE_ID" --entitlements Resources/Portal.entitlements "$APP"
if [[ -n "$IDENTITY" ]]; then
    echo "Signed with: $IDENTITY"
else
    echo "warning: no Apple Development certificate found; ad-hoc signed (permissions will reset on rebuild)"
fi

echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x "$APP_NAME" 2>/dev/null && sleep 0.5 || true
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP" "/Applications/$APP_NAME.app"
    open "/Applications/$APP_NAME.app"
    echo "Installed and launched /Applications/$APP_NAME.app"
fi
