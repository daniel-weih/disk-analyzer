#!/bin/zsh

set -euo pipefail

RUN_SYSTEM_CHECKS=0
if [[ "${1:-}" == --integration && $# -eq 1 ]]; then
    RUN_SYSTEM_CHECKS=1
elif (( $# > 0 )); then
    echo "Usage: $0 [--integration]" >&2
    exit 2
fi

ROOT_DIR="${0:A:h:h}"
if (( RUN_SYSTEM_CHECKS )); then
    # Finder may keep file-ID references after the launched apps have exited.
    # Reuse this ignored workspace instead of deleting its parent underneath it.
    OUTPUT_DIR="$ROOT_DIR/.build/installer-integration-checks"
    mkdir -p "$OUTPUT_DIR"
else
    OUTPUT_DIR="$(mktemp -d /tmp/disk-analyzer-installer-checks.XXXXXX)"
    trap 'rm -rf "$OUTPUT_DIR"' EXIT
fi
swiftc -swift-version 5 -parse-as-library \
    -module-cache-path "$OUTPUT_DIR/module-cache" \
    "$ROOT_DIR/Packaging/Installer/AppInstaller.swift" \
    "$ROOT_DIR/Packaging/Installer/InstalledApplication.swift" \
    "$ROOT_DIR/Packaging/Installer/InstallerLaunchHandoff.swift" \
    "$ROOT_DIR/Packaging/Installer/InstallerDiskImageEjector.swift" \
    "$ROOT_DIR/Tests/InstallerChecks/main.swift" \
    -o "$OUTPUT_DIR/InstallerChecks"
"$OUTPUT_DIR/InstallerChecks" "$OUTPUT_DIR/fixtures"

# Ordinary code checks must not launch desktop apps or mount/eject real images.
if (( ! RUN_SYSTEM_CHECKS )); then
    exit 0
fi

swiftc -swift-version 5 -parse-as-library \
    -module-cache-path "$OUTPUT_DIR/module-cache" \
    "$ROOT_DIR/Packaging/Installer/AppInstaller.swift" \
    "$ROOT_DIR/Packaging/Installer/InstallerLaunchHandoff.swift" \
    "$ROOT_DIR/Packaging/Installer/InstallerDiskImageEjector.swift" \
    "$ROOT_DIR/Tests/InstallerEjectChecks/main.swift" \
    -o "$OUTPUT_DIR/InstallerEjectChecks"
python3 "$ROOT_DIR/Tests/InstallerEjectChecks/run.py" "$OUTPUT_DIR"

swiftc -swift-version 5 -parse-as-library \
    -module-cache-path "$OUTPUT_DIR/module-cache" \
    "$ROOT_DIR/Tests/InstallerLaunchChecks/ProbeApp.swift" \
    -o "$OUTPUT_DIR/InstallerLaunchProbe"
swiftc -swift-version 5 -parse-as-library \
    -module-cache-path "$OUTPUT_DIR/module-cache" \
    "$ROOT_DIR/Packaging/Installer/AppInstaller.swift" \
    "$ROOT_DIR/Packaging/Installer/InstalledApplication.swift" \
    "$ROOT_DIR/Packaging/Installer/InstallerLaunchHandoff.swift" \
    "$ROOT_DIR/Tests/InstallerLaunchChecks/main.swift" \
    -o "$OUTPUT_DIR/InstallerLaunchChecks"
python3 "$ROOT_DIR/Tests/InstallerLaunchChecks/run.py" \
    "$OUTPUT_DIR" "$ROOT_DIR/.build/installer-launch-fixtures"
