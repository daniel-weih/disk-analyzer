#!/bin/zsh
set -euo pipefail

PROJECT_DIR=${0:A:h:h}
BUILD_CONFIGURATION=${1:-release}
APP_NAME=DiskAnalyzer
OUTPUT_DIR=${2:-$PROJECT_DIR/dist}
APP_BUNDLE="$OUTPUT_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
SIGN_IDENTITY=${DISK_ANALYZER_SIGN_IDENTITY:--}
SDK_PATH=${SDKROOT:-$(xcrun --show-sdk-path)}

cd "$PROJECT_DIR"
swift build -c "$BUILD_CONFIGURATION" --sdk "$SDK_PATH"
BIN_DIR=$(swift build -c "$BUILD_CONFIGURATION" --sdk "$SDK_PATH" --show-bin-path)

mkdir -p "$OUTPUT_DIR"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_CONTENTS/MacOS" "$APP_CONTENTS/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP_CONTENTS/MacOS/$APP_NAME"
# Remove compiler/linker debug paths from the distributable before signing.
strip -S "$APP_CONTENTS/MacOS/$APP_NAME"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_CONTENTS/Info.plist"
cp "$PROJECT_DIR/Resources/AppIcon.icns" "$APP_CONTENTS/Resources/AppIcon.icns"

RESOURCE_BUNDLE="$BIN_DIR/DiskAnalyzer_DiskAnalyzer.bundle"
RESOURCE_ROOT="$RESOURCE_BUNDLE"
if [[ -d "$RESOURCE_BUNDLE/Contents/Resources" ]]; then
  RESOURCE_ROOT="$RESOURCE_BUNDLE/Contents/Resources"
fi
for LANGUAGE in en zh-hans; do
  LOCALIZATION_DIR="$RESOURCE_ROOT/$LANGUAGE.lproj"
  if [[ "$LANGUAGE" == "zh-hans" && -d "$RESOURCE_ROOT/zh-Hans.lproj" ]]; then
    LOCALIZATION_DIR="$RESOURCE_ROOT/zh-Hans.lproj"
  fi
  if [[ ! -f "$LOCALIZATION_DIR/Localizable.strings" ]]; then
    print -u2 "error: missing localization: $LOCALIZATION_DIR/Localizable.strings"
    exit 1
  fi
  cp -R "$LOCALIZATION_DIR" "$APP_CONTENTS/Resources/$LANGUAGE.lproj"
  plutil -lint "$APP_CONTENTS/Resources/$LANGUAGE.lproj/Localizable.strings"
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
