#!/bin/zsh
set -euo pipefail

PROJECT_DIR=${0:A:h:h}
CAPTURE_ROOT=$(mktemp -d /tmp/disk-analyzer-readme.XXXXXX)

cleanup_capture() {
    rm -rf "$CAPTURE_ROOT"
}
trap cleanup_capture EXIT

mkdir -p "$CAPTURE_ROOT/en" "$CAPTURE_ROOT/zh-Hans"

DISK_ANALYZER_LANGUAGE=en \
DISK_ANALYZER_CAPTURE_UI="$CAPTURE_ROOT/en" \
    "$PROJECT_DIR/scripts/test.sh"

DISK_ANALYZER_LANGUAGE=zh-Hans \
DISK_ANALYZER_CAPTURE_UI="$CAPTURE_ROOT/zh-Hans" \
    "$PROJECT_DIR/scripts/test.sh"

cp "$CAPTURE_ROOT/en/disk-analyzer-home.png" \
    "$PROJECT_DIR/docs/images/ui/disk-analyzer-home.png"
cp "$CAPTURE_ROOT/en/disk-analyzer-overview.png" \
    "$PROJECT_DIR/docs/images/ui/disk-analyzer-overview.png"
cp "$CAPTURE_ROOT/zh-Hans/disk-analyzer-home.png" \
    "$PROJECT_DIR/docs/images/ui/disk-analyzer-home.zh-CN.png"
cp "$CAPTURE_ROOT/zh-Hans/disk-analyzer-overview.png" \
    "$PROJECT_DIR/docs/images/ui/disk-analyzer-overview.zh-CN.png"

echo "Updated bilingual README screenshots in docs/images/ui."
