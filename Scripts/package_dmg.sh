#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
DEFAULT_APP_PATH="$ROOT_DIR/.build/Threadline.app"
DEFAULT_OUTPUT_DIR="$ROOT_DIR/dist"
EXPECTED_APP_IDENTIFIER="com.ulisses.threadline"
EXPECTED_HELPER_IDENTIFIER="com.ulisses.threadline.agent"
HELPER_RELATIVE_PATH="Contents/Library/LoginItems/ThreadlineAgent.app"

fail() {
    print -u2 -- "package_dmg: $*"
    exit 1
}

for tool in ditto hdiutil lipo shasum codesign; do
    command -v "$tool" >/dev/null 2>&1 || fail "required tool is unavailable: $tool"
done
[[ -x /usr/libexec/PlistBuddy ]] || fail "required tool is unavailable: /usr/libexec/PlistBuddy"

APP_PATH="${APP_PATH:-$DEFAULT_APP_PATH}"
OUTPUT_DIR="${OUTPUT_DIR:-$DEFAULT_OUTPUT_DIR}"
OVERWRITE="${OVERWRITE:-0}"
[[ "$OVERWRITE" == "0" || "$OVERWRITE" == "1" ]] \
    || fail "OVERWRITE must be 0 or 1"

if [[ "$APP_PATH" != /* ]]; then
    APP_PATH="$ROOT_DIR/$APP_PATH"
fi
[[ -d "$APP_PATH" ]] || fail "application bundle not found: $APP_PATH"
APP_PATH="$(cd "$APP_PATH" && pwd -P)"

INFO_PLIST="$APP_PATH/Contents/Info.plist"
[[ -f "$INFO_PLIST" ]] || fail "application Info.plist not found: $INFO_PLIST"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
EXECUTABLE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$INFO_PLIST")"
PACKAGE_TYPE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundlePackageType' "$INFO_PLIST")"
APP_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST")"

[[ "$PACKAGE_TYPE" == "APPL" ]] || fail "input is not an application bundle: $APP_PATH"
[[ "$APP_IDENTIFIER" == "$EXPECTED_APP_IDENTIFIER" ]] \
    || fail "unexpected application bundle identifier: $APP_IDENTIFIER"
[[ "$VERSION" == [A-Za-z0-9]* && "$VERSION" != *[^A-Za-z0-9._-]* ]] \
    || fail "unsupported application version: $VERSION"
[[ -n "$EXECUTABLE_NAME" && "$EXECUTABLE_NAME" != */* ]] \
    || fail "invalid CFBundleExecutable value"

EXECUTABLE_PATH="$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME"
[[ -f "$EXECUTABLE_PATH" && -x "$EXECUTABLE_PATH" ]] \
    || fail "application executable not found or not executable: $EXECUTABLE_PATH"

MAIN_ARCHS=("${(@f)$(lipo -archs "$EXECUTABLE_PATH" | tr ' ' '\n' | sed '/^$/d' | sort -u)}")
(( ${#MAIN_ARCHS[@]} > 0 )) || fail "could not determine application architecture"
for arch in "${MAIN_ARCHS[@]}"; do
    [[ "$arch" == [A-Za-z0-9_]* && "$arch" != *[^A-Za-z0-9_-]* ]] \
        || fail "unsupported architecture name: $arch"
done
if (( ${#MAIN_ARCHS[@]} == 1 )); then
    ARCH_LABEL="${MAIN_ARCHS[1]}"
else
    ARCH_LABEL="universal"
fi

codesign --verify --deep --strict "$APP_PATH" \
    || fail "application signature verification failed"

HELPER_PATH="$APP_PATH/$HELPER_RELATIVE_PATH"
HELPER_INFO_PLIST="$HELPER_PATH/Contents/Info.plist"
[[ -d "$HELPER_PATH" ]] || fail "embedded login helper not found: $HELPER_PATH"
[[ -f "$HELPER_INFO_PLIST" ]] || fail "embedded login helper Info.plist not found: $HELPER_INFO_PLIST"
HELPER_PACKAGE_TYPE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundlePackageType' "$HELPER_INFO_PLIST")"
HELPER_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$HELPER_INFO_PLIST")"
HELPER_EXECUTABLE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$HELPER_INFO_PLIST")"
[[ "$HELPER_PACKAGE_TYPE" == "APPL" ]] \
    || fail "embedded login helper is not an application bundle: $HELPER_PATH"
[[ "$HELPER_IDENTIFIER" == "$EXPECTED_HELPER_IDENTIFIER" ]] \
    || fail "unexpected login helper bundle identifier: $HELPER_IDENTIFIER"
[[ -n "$HELPER_EXECUTABLE_NAME" && "$HELPER_EXECUTABLE_NAME" != */* ]] \
    || fail "invalid embedded login helper CFBundleExecutable value"

HELPER_EXECUTABLE_PATH="$HELPER_PATH/Contents/MacOS/$HELPER_EXECUTABLE_NAME"
[[ -f "$HELPER_EXECUTABLE_PATH" && -x "$HELPER_EXECUTABLE_PATH" ]] \
    || fail "embedded login helper executable not found or not executable: $HELPER_EXECUTABLE_PATH"
HELPER_ARCHS=("${(@f)$(lipo -archs "$HELPER_EXECUTABLE_PATH" | tr ' ' '\n' | sed '/^$/d' | sort -u)}")
(( ${#HELPER_ARCHS[@]} > 0 )) || fail "could not determine embedded login helper architecture"
for arch in "${MAIN_ARCHS[@]}"; do
    (( ${HELPER_ARCHS[(Ie)$arch]} > 0 )) \
        || fail "embedded login helper does not support application architecture: $arch"
done
codesign --verify --deep --strict "$HELPER_PATH" \
    || fail "embedded login helper signature verification failed"

if [[ "$OUTPUT_DIR" != /* ]]; then
    OUTPUT_DIR="$ROOT_DIR/$OUTPUT_DIR"
fi
[[ -n "$OUTPUT_DIR" && "$OUTPUT_DIR" != "/" ]] || fail "unsafe output directory"
mkdir -p -- "$OUTPUT_DIR"
[[ -d "$OUTPUT_DIR" ]] || fail "output path is not a directory: $OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd -P)"
[[ "$OUTPUT_DIR" != "/" ]] || fail "unsafe output directory"

DMG_NAME="Threadline-$VERSION-$ARCH_LABEL.dmg"
CHECKSUM_NAME="$DMG_NAME.sha256"
TARGET_DMG="$OUTPUT_DIR/$DMG_NAME"
TARGET_CHECKSUM="$OUTPUT_DIR/$CHECKSUM_NAME"

validate_output_targets() {
    local target
    for target in "$TARGET_DMG" "$TARGET_CHECKSUM"; do
        [[ "${target:h}" == "$OUTPUT_DIR" ]] || fail "refusing unsafe output target: $target"
        if [[ -e "$target" || -L "$target" ]]; then
            [[ -f "$target" && ! -L "$target" ]] \
                || fail "refusing to overwrite non-regular output target: $target"
            [[ "$OVERWRITE" == "1" ]] \
                || fail "output already exists: $target (set OVERWRITE=1 to replace verified regular files)"
        fi
    done
}

validate_output_targets

TEMP_DIR="$(mktemp -d "$OUTPUT_DIR/.threadline-dmg.XXXXXX")"
[[ -n "$TEMP_DIR" && -d "$TEMP_DIR" && "$TEMP_DIR" != "/" ]] \
    || fail "could not create a safe temporary directory"

cleanup() {
    if [[ -n "${TEMP_DIR:-}" && -d "$TEMP_DIR" && "$TEMP_DIR" != "/" ]]; then
        rm -rf -- "$TEMP_DIR"
    fi
}
on_interrupt() {
    cleanup
    trap - EXIT
    exit 130
}
on_terminate() {
    cleanup
    trap - EXIT
    exit 143
}
trap cleanup EXIT
trap on_interrupt INT
trap on_terminate TERM

STAGING_DIR="$TEMP_DIR/staging"
TEMP_DMG="$TEMP_DIR/$DMG_NAME"
TEMP_CHECKSUM="$TEMP_DIR/$CHECKSUM_NAME"
mkdir -p -- "$STAGING_DIR"

ditto --noqtn "$APP_PATH" "$STAGING_DIR/Threadline.app"
ln -s /Applications "$STAGING_DIR/Applications"

hdiutil create \
    -volname "Threadline $VERSION" \
    -srcfolder "$STAGING_DIR" \
    -format UDZO \
    -ov \
    "$TEMP_DMG" >/dev/null
hdiutil verify "$TEMP_DMG" >/dev/null

DIGEST="$(shasum -a 256 "$TEMP_DMG" | awk '{print $1}')"
[[ "$DIGEST" != *[^0-9a-f]* && ${#DIGEST} == 64 ]] \
    || fail "could not calculate a valid SHA-256 checksum"
printf '%s  %s\n' "$DIGEST" "$DMG_NAME" > "$TEMP_CHECKSUM"

validate_output_targets
mv -f -- "$TEMP_DMG" "$TARGET_DMG"
mv -f -- "$TEMP_CHECKSUM" "$TARGET_CHECKSUM"

hdiutil verify "$TARGET_DMG" >/dev/null
(
    cd "$OUTPUT_DIR"
    shasum -a 256 -c "$CHECKSUM_NAME" >/dev/null
)

print -- "$TARGET_DMG"
print -- "$TARGET_CHECKSUM"
