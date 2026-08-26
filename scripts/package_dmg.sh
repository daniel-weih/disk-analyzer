#!/bin/zsh
set -euo pipefail

PROJECT_DIR=${0:A:h:h}
DIST_DIR="$PROJECT_DIR/dist"
STAGE_DIR="$DIST_DIR/.stage"
LEGACY_APP_BUNDLE="$DIST_DIR/DiskAnalyzer.app"
DMG_PATH="$DIST_DIR/DiskAnalyzer-2.2.0-arm64.dmg"

rm -rf "$STAGE_DIR"
rm -rf "$LEGACY_APP_BUNDLE"
mkdir -p "$STAGE_DIR"

cleanup() {
  rm -rf "$STAGE_DIR"
}
trap cleanup EXIT

"$PROJECT_DIR/scripts/package_app.sh" release "$STAGE_DIR"
ln -s /Applications "$STAGE_DIR/Applications"

rm -f "$DMG_PATH"
hdiutil create \
  -volname "DiskAnalyzer" \
  -srcfolder "$STAGE_DIR" \
  -format UDZO \
  -ov \
  "$DMG_PATH"

hdiutil verify "$DMG_PATH"
shasum -a 256 "$DMG_PATH"
echo "$DMG_PATH"
