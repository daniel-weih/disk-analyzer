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
    /// switch state. The per-user TCC database is present on supported macOS
    /// versions and is itself protected by TCC, so opening it read-only gives
    /// us a small, non-destructive best-effort probe.
    static var protectedDatabaseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db")
    }

    static func check() -> FullDiskAccessProbeResult {
        let descriptor = Darwin.open(
            protectedDatabaseURL.path,
            O_RDONLY | O_CLOEXEC
        )
        let errorCode = descriptor >= 0 ? 0 : errno
        if descriptor >= 0 {
            Darwin.close(descriptor)
        }
        return classify(fileDescriptor: descriptor, errorCode: errorCode)
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
