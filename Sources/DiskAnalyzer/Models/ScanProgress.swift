import Foundation

struct ScanProgress: Sendable {
    let scannedItems: Int
    let scannedFiles: Int
    let scannedDirectories: Int
    let allocatedBytes: Int64
    let currentPath: String
    let phase: Phase

    enum Phase: Sendable {
        case idle
        case scanning
        case done
        case failed(String)
    }

    static let idle = ScanProgress(
        scannedItems: 0,
        scannedFiles: 0,
        scannedDirectories: 0,
        allocatedBytes: 0,
        currentPath: "",
        phase: .idle
    )
}
