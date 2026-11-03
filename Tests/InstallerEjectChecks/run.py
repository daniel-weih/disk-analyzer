from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import time


def run(arguments):
    result = subprocess.run([str(arg) for arg in arguments], capture_output=True)
    if result.returncode:
        raise RuntimeError(f"Command failed: {arguments!r}\n{result.stderr.decode(errors='replace')}")
    return result


def image_is_attached(image):
    information = plistlib.loads(run(["/usr/bin/hdiutil", "info", "-plist"]).stdout)
    return any(Path(entry["image-path"]).resolve() == image.resolve()
               for entry in information.get("images", []) if "image-path" in entry)


def wait_until(condition, timeout):
    deadline = time.monotonic() + timeout
    while not condition() and time.monotonic() < deadline:
        time.sleep(0.05)
    assert condition(), "Timed out waiting for the installer or disk image"


root = Path(sys.argv[1])
stage = root / "eject-stage"
image = root / "eject-fixture.dmg"
if image_is_attached(image):
    raise RuntimeError("A previous fixture image is still attached; leave it intact until it can be detached")
shutil.rmtree(stage, ignore_errors=True)
image.unlink(missing_ok=True)
shutil.rmtree(root / "installed", ignore_errors=True)
probe = root / "InstallerEjectChecks"
installer = stage / "Install DiskAnalyzer.app"
for app, executable, identifier in [
    (installer, "Install DiskAnalyzer", "org.opensource.diskanalyzer.installer"),
    (stage / "DiskAnalyzer.app", "DiskAnalyzer", "org.opensource.diskanalyzer"),
]:
    macos = app / "Contents/MacOS"
    macos.mkdir(parents=True)
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": identifier,
        "CFBundlePackageType": "APPL",
        "CFBundleExecutable": executable,
        "CFBundleVersion": "1",
    }))
    shutil.copyfile(probe if app == installer else "/usr/bin/true", macos / executable)
    (macos / executable).chmod(0o755)

run(["/usr/bin/hdiutil", "create", "-quiet", "-srcfolder", stage, "-format", "UDZO", image])
destination = root / "installed/DiskAnalyzer.app"
destination.parent.mkdir()

for index, mode in enumerate(["install", "repeat", "launch-failure", "wrong-identity", "install-failure"]):
    print("Checking real DMG ejection:", mode, flush=True)
    # Spaces, quotes, and a mount suffix must stay literal process arguments.
    mount = root / ("mount ' test " + str(index))
    mount.mkdir(exist_ok=True)
    mounted = False
    child = None
    try:
        run(["/usr/bin/hdiutil", "attach", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mount, image])
        mounted = True
        payload = mount / "DiskAnalyzer.app"
        ready = root / (mode + ".ready")
        release = root / (mode + ".release")
        ready.unlink(missing_ok=True)
        release.unlink(missing_ok=True)
        executable = mount / "Install DiskAnalyzer.app/Contents/MacOS/Install DiskAnalyzer"
        child = subprocess.Popen([str(executable), str(destination), mode, str(ready), str(release)],
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, cwd="/")
        wait_until(lambda: ready.exists() or child.poll() is not None, 15)
        assert ready.exists(), child.communicate(timeout=2)
        time.sleep(0.2)
        assert payload.exists(), "Image was ejected while the installer was still running"
        release.touch()
        stdout, stderr = child.communicate(timeout=5)
        assert child.returncode == 0, (stdout, stderr)
        if mode in ["install", "repeat"]:
            wait_until(lambda: not payload.exists(), 10)
            # The volume disappears before hdiutil finishes detaching its device.
            # Wait for that operation to finish before attaching the same image again.
            wait_until(lambda: not image_is_attached(image), 10)
            mounted = False
        else:
            time.sleep(1)
            assert payload.exists(), "Failed install/launch or changed identity must keep the image mounted"
    finally:
        if child is not None and child.poll() is None:
            child.kill()
            child.communicate()
        if mounted:
            run(["/usr/bin/hdiutil", "detach", mount])
print("All 5 real DMG ejection checks passed", flush=True)
