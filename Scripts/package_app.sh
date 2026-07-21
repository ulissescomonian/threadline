#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
CONFIGURATION="${CONFIGURATION:-release}"
BUILD_DIR="$ROOT_DIR/.build/$CONFIGURATION"
APP_DIR="$ROOT_DIR/.build/Threadline.app"
AGENT_DIR="$APP_DIR/Contents/Library/LoginItems/ThreadlineAgent.app"
IDENTITY="${CODESIGN_IDENTITY:--}"

if [[ "${ENABLE_CLOUDKIT_ENTITLEMENTS:-0}" == "1" && "$IDENTITY" == "-" ]]; then
    print -u2 "CloudKit entitlements require a provisioned Apple signing identity; ad-hoc signing is not supported."
    exit 2
fi

cd "$ROOT_DIR"
swift build -c "$CONFIGURATION"
zsh "$ROOT_DIR/Scripts/make_icon.sh"

# Compile-time source paths can reveal a maintainer's workstation layout.
# Refuse to package either executable if the current workspace path leaked in.
for executable in "$BUILD_DIR/Threadline" "$BUILD_DIR/ThreadlineAgent"; do
    if LC_ALL=C strings "$executable" | grep -F "$ROOT_DIR" >/dev/null; then
        print -u2 "Refusing to package: absolute workspace path leaked into ${executable:t}."
        exit 3
    fi
done

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
mkdir -p "$AGENT_DIR/Contents/MacOS"

cp "$BUILD_DIR/Threadline" "$APP_DIR/Contents/MacOS/Threadline"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$ROOT_DIR/.build/Threadline.icns" "$APP_DIR/Contents/Resources/Threadline.icns"
ditto "$ROOT_DIR/Sources/Threadline/Resources/ProviderIcons" \
    "$APP_DIR/Contents/Resources/ProviderIcons"

cp "$BUILD_DIR/ThreadlineAgent" "$AGENT_DIR/Contents/MacOS/ThreadlineAgent"
cp "$ROOT_DIR/Resources/Agent-Info.plist" "$AGENT_DIR/Contents/Info.plist"

if [[ "${ENABLE_CLOUDKIT_ENTITLEMENTS:-0}" == "1" ]]; then
    codesign --force --options runtime --timestamp=none \
        --entitlements "$ROOT_DIR/Resources/ThreadlineAgent.entitlements" \
        --sign "$IDENTITY" "$AGENT_DIR"
    codesign --force --options runtime --timestamp=none \
        --entitlements "$ROOT_DIR/Resources/Threadline.entitlements" \
        --sign "$IDENTITY" "$APP_DIR"
else
    codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$AGENT_DIR"
    codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$APP_DIR"
fi

codesign --verify --deep --strict "$APP_DIR"
if [[ "${ENABLE_CLOUDKIT_ENTITLEMENTS:-0}" == "1" ]]; then
    codesign -d --entitlements :- "$APP_DIR" 2>&1 | grep -q "iCloud.com.ulisses.threadline"
    codesign -d --entitlements :- "$AGENT_DIR" 2>&1 | grep -q "iCloud.com.ulisses.threadline"
    codesign -d --entitlements :- "$APP_DIR" 2>&1 | grep -q "com.ulisses.threadline.shared"
    codesign -d --entitlements :- "$AGENT_DIR" 2>&1 | grep -q "com.ulisses.threadline.shared"
fi
echo "$APP_DIR"
