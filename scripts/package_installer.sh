#!/bin/zsh

set -euo pipefail

ROOT_DIR="${0:A:h:h}"
APP_DIR="$1"
shift
SIGN_IDENTITY=${DISK_ANALYZER_SIGN_IDENTITY:--}
SDK_PATH="${SDKROOT:-$(xcrun --show-sdk-path)}"
while (( $# )); do
    case "$1" in
        --sdk) SDK_PATH="$2"; shift 2 ;;
        --sdk=*) SDK_PATH="${1#--sdk=}"; shift ;;
        *) shift ;;
    esac
done
CACHE_DIR="$(mktemp -d /tmp/disk-analyzer-installer-build.XXXXXX)"
trap 'rm -rf "$CACHE_DIR"' EXIT

mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources/zh_CN.lproj" \
    "$APP_DIR/Contents/Resources/en.lproj"
swiftc -O -swift-version 5 -parse-as-library \
    -sdk "$SDK_PATH" -target "$(uname -m)-apple-macosx13.0" \
    -module-cache-path "$CACHE_DIR" \
    "$ROOT_DIR/Packaging/Installer/AppInstaller.swift" \
    "$ROOT_DIR/Packaging/Installer/InstalledApplication.swift" \
    "$ROOT_DIR/Packaging/Installer/InstallerLaunchHandoff.swift" \
    "$ROOT_DIR/Packaging/Installer/InstallerDiskImageEjector.swift" \
    "$ROOT_DIR/Packaging/Installer/InstallerMain.swift" \
    -o "$APP_DIR/Contents/MacOS/Install DiskAnalyzer"
strip -S "$APP_DIR/Contents/MacOS/Install DiskAnalyzer"
install -m 644 "$ROOT_DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
python3 - "$ROOT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as stream:
    app = plistlib.load(stream)
info = {
    "CFBundleDevelopmentRegion": "en",
    "CFBundleDisplayName": "Install or Update DiskAnalyzer",
    "CFBundleName": "Install DiskAnalyzer",
    "CFBundleExecutable": "Install DiskAnalyzer",
    "CFBundleIdentifier": "org.opensource.diskanalyzer.installer",
    "CFBundleIconFile": "AppIcon.icns",
    "CFBundleInfoDictionaryVersion": "6.0",
    "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": app["CFBundleShortVersionString"],
    "CFBundleVersion": app["CFBundleVersion"],
    "LSMinimumSystemVersion": "13.0",
    "LSUIElement": True,
    "NSHighResolutionCapable": True,
    "NSPrincipalClass": "NSApplication",
}
with open(sys.argv[2], "wb") as stream:
    plistlib.dump(info, stream)
PY
printf '%s\n' '"CFBundleDisplayName" = "安装或更新 DiskAnalyzer";' \
    > "$APP_DIR/Contents/Resources/zh_CN.lproj/InfoPlist.strings"
printf '%s\n' '"CFBundleDisplayName" = "Install or Update DiskAnalyzer";' \
    > "$APP_DIR/Contents/Resources/en.lproj/InfoPlist.strings"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    codesign --force --sign - "$APP_DIR"
else
    codesign --force --options runtime --sign "$SIGN_IDENTITY" "$APP_DIR"
fi
codesign --verify --deep --strict "$APP_DIR"
