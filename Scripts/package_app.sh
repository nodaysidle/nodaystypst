#!/usr/bin/env bash
set -euo pipefail

ENT_TMP=""
trap 'rm -f "$ENT_TMP"' EXIT

CONFIGURATION=${1:-release}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

APP_NAME=${APP_NAME:-Nodaystypst}
BUNDLE_ID=${BUNDLE_ID:-com.nodays.nodaystypst}
MACOS_MIN_VERSION=${MACOS_MIN_VERSION:-15.0}
MENU_BAR_APP=${MENU_BAR_APP:-0}
APP_ENTITLEMENTS=${APP_ENTITLEMENTS:-$ROOT/Resources/Nodaystypst.entitlements}

source "$ROOT/version.env"
"$ROOT/Scripts/build_icon.sh"
swift build -c "$CONFIGURATION"

BIN_DIR=$(swift build -c "$CONFIGURATION" --show-bin-path)
APP="$ROOT/${APP_NAME}.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $MARKETING_VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion $MACOS_MIN_VERSION" "$APP/Contents/Info.plist"
if [[ "$MENU_BAR_APP" == "1" ]]; then
    /usr/libexec/PlistBuddy -c "Set :LSUIElement true" "$APP/Contents/Info.plist"
else
    /usr/libexec/PlistBuddy -c "Set :LSUIElement false" "$APP/Contents/Info.plist"
fi

if [[ "${NODAYSTYPST_DEBUG_LOG:-0}" == "1" ]]; then
    /usr/libexec/PlistBuddy -c "Add :LSEnvironment dict" "$APP/Contents/Info.plist" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :LSEnvironment:NODAYSTYPST_DEBUG_LOG string 1" "$APP/Contents/Info.plist" 2>/dev/null || true
fi

find "$BIN_DIR" -maxdepth 1 -name '*.bundle' -exec cp -R {} "$APP/Contents/Resources/" \;
xattr -cr "$APP"
codesign --force --deep --sign - --entitlements "$APP_ENTITLEMENTS" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

# --- deterministic entitlement verification (direct-distribution: non-sandboxed) ---
ENT_TMP=$(mktemp /tmp/nodaystypst-entitlements.XXXXXX.plist)
codesign -d --entitlements "$ENT_TMP" --xml "$APP" 2>/dev/null
if /usr/libexec/PlistBuddy -c "Print :com.apple.security.app-sandbox" "$ENT_TMP" &>/dev/null; then
    echo "ERROR: App Sandbox is enabled in bundle entitlements — direct-distribution must be non-sandboxed" >&2
    exit 1
fi
if ! /usr/libexec/PlistBuddy -c "Print :com.apple.security.network.client" "$ENT_TMP" &>/dev/null; then
    echo "ERROR: network.client entitlement is missing" >&2
    exit 1
fi
NET_VALUE=$(/usr/libexec/PlistBuddy -c "Print :com.apple.security.network.client" "$ENT_TMP" 2>/dev/null)
if [[ "$NET_VALUE" != "true" ]]; then
    echo "ERROR: network.client entitlement is not true" >&2
    exit 1
fi
rm -f "$ENT_TMP"
ENT_TMP=""
echo "Entitlement verification: OK (non-sandboxed, network.client=true)"

echo "Created $APP"
