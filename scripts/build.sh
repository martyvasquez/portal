#!/bin/zsh
# Builds Portal.app, signs it, and (with --install) copies it to /Applications and relaunches.
#
#   scripts/build.sh            # build + sign into ./build/Portal.app
#   scripts/build.sh --install  # ...then install to /Applications and relaunch
#
# Signing with a stable certificate matters: macOS ties Accessibility and other
# permissions to the signature, so an ad-hoc signature would reset them every build.
# Override with: SIGN_IDENTITY="Apple Development: …" scripts/build.sh
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Portal"
BUNDLE_ID="com.martyvasquez.portal"
VERSION="0.1.0"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')}"

swift build -c release --arch arm64
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"

APP="build/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
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
    <key>NSAppleEventsUsageDescription</key><string>Portal asks Finder, Ghostty, and Terminal which folder you're in, to open it with your apps and show that folder's snippets.</string>
    <key>NSHumanReadableCopyright</key><string>Personal build</string>
</dict>
</plist>
PLIST

if [[ -n "$IDENTITY" ]]; then
    codesign --force --timestamp=none --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP"
    echo "Signed with: $IDENTITY"
else
    codesign --force --sign - "$APP"
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
