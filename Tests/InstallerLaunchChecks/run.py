from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import uuid


build = Path(sys.argv[1])
# Launch Services and Finder can outlive an app's termination callback. Keep
# these two small bundles at stable, ignored paths rather than delete a directory
# that the desktop may still be resolving by file ID. Each run replaces them.
root = Path(sys.argv[2])
identifier = "org.opensource.diskanalyzer.launch-check." + uuid.uuid4().hex
applications = []
for version, parent in enumerate(["old", "installed"], start=1):
    app = root / parent / "Probe.app"
    applications.append(app)
    macos = app / "Contents/MacOS"
    macos.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(build / "InstallerLaunchProbe", macos / "Probe")
    (macos / "Probe").chmod(0o755)
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": identifier,
        "CFBundleName": "DiskAnalyzer Installer Launch Check",
        "CFBundleExecutable": "Probe",
        "CFBundlePackageType": "APPL",
        "CFBundleVersion": str(version),
        "LSUIElement": True,
    }))
    subprocess.run(["/usr/bin/codesign", "--force", "--deep", "--sign", "-", str(app)],
                   check=True, capture_output=True)
try:
    subprocess.run([str(build / "InstallerLaunchChecks"), str(root)], check=True, timeout=25)
finally:
    # Remove only the fixture registrations while their bundles still exist.
    # Temporary test apps must not accumulate as stale Launch Services entries.
    lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    for app in applications:
        subprocess.run([lsregister, "-u", str(app)], check=True, capture_output=True)
