#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="双手柄映射器"
STAGING_ROOT="$(mktemp -d)"
trap 'rm -rf "$STAGING_ROOT"' EXIT
APP_PATH="$STAGING_ROOT/$APP_NAME.app"
CONTENTS_PATH="$APP_PATH/Contents"
EXECUTABLE_PATH="$CONTENTS_PATH/MacOS/DualPadMapper"
DIST_PATH="$PROJECT_ROOT/dist"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"

mkdir -p "$CONTENTS_PATH/MacOS" "$DIST_PATH"

for ARCH in arm64 x86_64; do
  swiftc "$PROJECT_ROOT/Sources/DualPadMapper/main.swift" \
    -target "$ARCH-apple-macos13.0" \
    -sdk "$SDK_PATH" \
    -o "$STAGING_ROOT/DualPadMapper-$ARCH" \
    -framework AppKit \
    -framework ApplicationServices \
    -framework IOKit
done
lipo -create \
  "$STAGING_ROOT/DualPadMapper-arm64" \
  "$STAGING_ROOT/DualPadMapper-x86_64" \
  -output "$EXECUTABLE_PATH"

COPYFILE_DISABLE=1 cp "$PROJECT_ROOT/Resources/Info.plist" "$CONTENTS_PATH/Info.plist"
chmod +x "$EXECUTABLE_PATH"
xattr -cr "$APP_PATH"
codesign --force --deep --sign - "$APP_PATH"
codesign --verify --deep --strict "$APP_PATH"
lipo "$EXECUTABLE_PATH" -verify_arch arm64 x86_64
"$EXECUTABLE_PATH" --self-test

ARCHIVE_PATH="$DIST_PATH/DualPadMapper-macOS.zip"
if [[ -e "$ARCHIVE_PATH" ]]; then
  mv "$ARCHIVE_PATH" "$DIST_PATH/DualPadMapper-macOS.previous.zip"
fi
STAGED_ARCHIVE="$STAGING_ROOT/DualPadMapper-macOS.zip"
(cd "$STAGING_ROOT" && COPYFILE_DISABLE=1 /usr/bin/zip -qryX "$STAGED_ARCHIVE" "$APP_NAME.app")
mv "$STAGED_ARCHIVE" "$ARCHIVE_PATH"

echo "发布压缩包：$ARCHIVE_PATH"
