#!/bin/zsh
set -euo pipefail

PROJECT_DIR=${0:A:h:h}
DEVELOPER_FRAMEWORKS=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
DEVELOPER_LIBRARIES=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
MODULE_CACHE=/tmp/disk-analyzer-clang-cache

cd "$PROJECT_DIR"

CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" swift test \
  --enable-swift-testing \
  --disable-xctest \
  -Xswiftc -F \
  -Xswiftc "$DEVELOPER_FRAMEWORKS" \
  -Xlinker -F \
  -Xlinker "$DEVELOPER_FRAMEWORKS" \
  -Xlinker -rpath \
  -Xlinker "$DEVELOPER_FRAMEWORKS" \
  -Xlinker -rpath \
  -Xlinker "$DEVELOPER_LIBRARIES"
