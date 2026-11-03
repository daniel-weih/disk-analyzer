import Darwin
import Foundation

enum InstallerDiskImageEjector {
    struct Target: Equatable {
        let mountPoint: URL
        let volumeUUID: String
    }

    static func prepare(installerURL: URL, destination: URL) -> Target? {
        guard let values = try? installerURL.resourceValues(forKeys: [.volumeURLKey]),
              let volume = values.allValues[.volumeURLKey] as? URL,
              let information = try? diskInformation(at: volume) else { return nil }
        return target(installerURL: installerURL, destination: destination, information: information)
    }

    static func target(installerURL: URL, destination: URL, information: Data) -> Target? {
        guard installerURL.isFileURL, destination.isFileURL,
              let info = (try? PropertyListSerialization.propertyList(from: information, format: nil)) as? [String: Any],
              info["BusProtocol"] as? String == "Disk Image",
              info["Ejectable"] as? Bool == true,
              info["SystemImage"] as? Bool != true,
              let path = info["MountPoint"] as? String, path.hasPrefix("/"), path != "/",
              let uuid = info["VolumeUUID"] as? String, UUID(uuidString: uuid) != nil else { return nil }
        let mount = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let source = installerURL.standardizedFileURL.resolvingSymlinksInPath()
        let installed = destination.standardizedFileURL.resolvingSymlinksInPath()
        guard source.path.hasPrefix(mount.path + "/"),
              installed.path != mount.path, !installed.path.hasPrefix(mount.path + "/") else { return nil }
        return Target(mountPoint: mount, volumeUUID: uuid)
    }

    /// The shell runs from the system disk and outlives the installer. Waiting
    /// for its exit releases the executable on the image before unmounting it.
    static func schedule(_ target: Target) throws {
        let worker = Process()
        worker.executableURL = URL(fileURLWithPath: "/bin/sh")
        worker.currentDirectoryURL = URL(fileURLWithPath: "/")
        worker.arguments = ["-c", workerScript, "disk-analyzer-eject",
                            target.mountPoint.path, target.volumeUUID, String(getpid())]
        worker.standardInput = FileHandle.nullDevice
        worker.standardOutput = FileHandle.nullDevice
        worker.standardError = FileHandle.nullDevice
        try worker.run()
    }

    private static func diskInformation(at volume: URL) throws -> Data {
        let fm = FileManager.default
        let outputURL = fm.temporaryDirectory.appendingPathComponent("disk-analyzer-disk-info-\(UUID().uuidString)")
        guard fm.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw InstallationError(message: "Could not inspect the installer disk image")
        }
        defer { try? fm.removeItem(at: outputURL) }
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["info", "-plist", volume.path]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning {
            process.terminate()
            let terminationDeadline = Date().addingTimeInterval(1)
            while process.isRunning, Date() < terminationDeadline { Thread.sleep(forTimeInterval: 0.02) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw InstallationError(message: "Disk image inspection timed out")
        }
        guard process.terminationStatus == 0 else {
            throw InstallationError(message: "Could not inspect the installer disk image")
        }
        return try Data(contentsOf: outputURL)
    }

    private static let workerScript = """
    attempt=0
    while kill -0 "$3" 2>/dev/null; do
        [ "$attempt" -lt 150 ] || exit 0
        attempt=$((attempt + 1))
        /bin/sleep 0.1
    done
    attempt=0
    while [ "$attempt" -lt 5 ]; do
        current_uuid=$(/usr/sbin/diskutil info -plist "$1" 2>/dev/null | /usr/bin/plutil -extract VolumeUUID raw -o - - 2>/dev/null) || exit 0
        [ "$current_uuid" = "$2" ] || exit 0
        /usr/bin/hdiutil detach "$1" >/dev/null 2>&1 && exit 0
        attempt=$((attempt + 1))
        /bin/sleep 1
    done
    """
}
