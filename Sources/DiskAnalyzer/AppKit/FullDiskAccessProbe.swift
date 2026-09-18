import Darwin
import Foundation

enum FullDiskAccessProbeResult: Equatable, Sendable {
    case granted
    case denied
    case unavailable

    var isGranted: Bool { self == .granted }
}

enum FullDiskAccessProbe {
    /// macOS does not expose a public API that returns the Full Disk Access
    /// switch state. Protected TCC databases provide a non-destructive,
    /// best-effort probe; the per-user database may not exist after an upgrade.
    static var protectedDatabaseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db")
    }

    static func check() -> FullDiskAccessProbeResult {
        checkCandidates([
            protectedDatabaseURL,
            URL(fileURLWithPath: "/Library/Application Support/com.apple.TCC/TCC.db")
        ]) { url in
            let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC)
            let errorCode = descriptor >= 0 ? 0 : errno
            if descriptor >= 0 { Darwin.close(descriptor) }
            return classify(fileDescriptor: descriptor, errorCode: errorCode)
        }
    }

    /// User-level databases can be absent after an OS upgrade. Try the
    /// system-level protected database too, without reading database contents.
    static func checkCandidates(
        _ urls: [URL],
        probe: (URL) -> FullDiskAccessProbeResult
    ) -> FullDiskAccessProbeResult {
        var sawDenial = false
        for url in urls {
            switch probe(url) {
            case .granted: return .granted
            case .denied: sawDenial = true
            case .unavailable: continue
            }
        }
        return sawDenial ? .denied : .unavailable
    }

    static func classify(
        fileDescriptor: Int32,
        errorCode: Int32
    ) -> FullDiskAccessProbeResult {
        if fileDescriptor >= 0 { return .granted }
        if errorCode == EPERM || errorCode == EACCES { return .denied }
        return .unavailable
    }
}
