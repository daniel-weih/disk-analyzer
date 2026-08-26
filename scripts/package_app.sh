#!/bin/zsh
set -euo pipefail

PROJECT_DIR=${0:A:h:h}
BUILD_CONFIGURATION=${1:-release}
APP_NAME=DiskAnalyzer
OUTPUT_DIR=${2:-$PROJECT_DIR/dist}
APP_BUNDLE="$OUTPUT_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
SIGN_IDENTITY=${DISK_ANALYZER_SIGN_IDENTITY:--}

cd "$PROJECT_DIR"
swift build -c "$BUILD_CONFIGURATION"
BIN_DIR=$(swift build -c "$BUILD_CONFIGURATION" --show-bin-path)

mkdir -p "$OUTPUT_DIR"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_CONTENTS/MacOS" "$APP_CONTENTS/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP_CONTENTS/MacOS/$APP_NAME"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_CONTENTS/Info.plist"
cp "$PROJECT_DIR/Resources/AppIcon.icns" "$APP_CONTENTS/Resources/AppIcon.icns"

RESOURCE_BUNDLE="$BIN_DIR/DiskAnalyzer_DiskAnalyzer.bundle"
for LANGUAGE in en zh-hans; do
  LOCALIZATION_DIR="$RESOURCE_BUNDLE/$LANGUAGE.lproj"
  if [[ -d "$LOCALIZATION_DIR" ]]; then
    cp -R "$LOCALIZATION_DIR" "$APP_CONTENTS/Resources/"
  fi
done

if [[ "$SIGN_IDENTITY" == "-" ]]; then
  print -u2 "warning: using ad-hoc signing; Full Disk Access must be removed and re-added after the app binary changes"
  print -u2 "warning: set DISK_ANALYZER_SIGN_IDENTITY to a stable Apple Development or Developer ID identity for persistent TCC authorization"
  codesign --force --sign - "$APP_BUNDLE"
else
  codesign --force --options runtime --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
fi
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

echo "$APP_BUNDLE"
