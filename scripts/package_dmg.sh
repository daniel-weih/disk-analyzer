#!/bin/zsh
set -euo pipefail

PROJECT_DIR=${0:A:h:h}
DIST_DIR="$PROJECT_DIR/dist"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PROJECT_DIR/Resources/Info.plist")
DMG_NAME="DiskAnalyzer-$VERSION-$(uname -m).dmg"
DMG_PATH="$DIST_DIR/$DMG_NAME"
WORK_DIR="$(mktemp -d /tmp/disk-analyzer-package.XXXXXX)"
STAGE_DIR="$WORK_DIR/stage"
MOUNT_DIR="$WORK_DIR/mount"
MOUNTED=0
PUBLISH_DIR=""

detach_image() {
  local attempt
  for attempt in 1 2 3; do
    if hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1; then
      MOUNTED=0
      return 0
    fi
    if (( attempt < 3 )); then sleep 1; fi
  done
  return 1
}

cleanup() {
  if [[ -n "$PUBLISH_DIR" ]]; then rm -rf -- "$PUBLISH_DIR"; fi
  if (( MOUNTED )) && ! detach_image; then
    print -u2 "Could not detach $MOUNT_DIR; temporary files retained at $WORK_DIR"
    return
  fi
  rm -rf -- "$WORK_DIR"
}
trap cleanup EXIT

if [[ -L "$DIST_DIR" || -d "$DMG_PATH" ]]; then
  print -u2 "Refusing unsafe output path: $DMG_PATH"
  exit 1
fi
mkdir -p "$DIST_DIR" "$STAGE_DIR" "$MOUNT_DIR"

"$PROJECT_DIR/scripts/package_app.sh" release "$STAGE_DIR"
"$PROJECT_DIR/scripts/package_installer.sh" "$STAGE_DIR/Install DiskAnalyzer.app"
ln -s /Applications "$STAGE_DIR/Applications"

hdiutil create -volname "DiskAnalyzer" -srcfolder "$STAGE_DIR" \
  -fs HFS+ -format UDZO "$WORK_DIR/$DMG_NAME"
hdiutil verify "$WORK_DIR/$DMG_NAME"
hdiutil attach -readonly -nobrowse -noautoopen \
  -mountpoint "$MOUNT_DIR" "$WORK_DIR/$DMG_NAME" >/dev/null
MOUNTED=1
codesign --verify --deep --strict "$MOUNT_DIR/DiskAnalyzer.app"
codesign --verify --deep --strict "$MOUNT_DIR/Install DiskAnalyzer.app"
"$MOUNT_DIR/Install DiskAnalyzer.app/Contents/MacOS/Install DiskAnalyzer" --verify-only
[[ "$(readlink "$MOUNT_DIR/Applications")" == /Applications ]]
detach_image

# Publish only after validating the mounted payload. Keep the previous DMG if
# building or verification fails, even when /tmp is on a different volume.
PUBLISH_DIR="$(mktemp -d "$DIST_DIR/.disk-analyzer-publish.XXXXXX")"
ditto "$WORK_DIR/$DMG_NAME" "$PUBLISH_DIR/$DMG_NAME"
python3 - "$PUBLISH_DIR/$DMG_NAME" "$DMG_PATH" <<'PY'
import os
import sys
os.replace(sys.argv[1], sys.argv[2])
PY
rmdir "$PUBLISH_DIR"
PUBLISH_DIR=""
shasum -a 256 "$DMG_PATH"
echo "$DMG_PATH"
