import Foundation

final class FileNode: Identifiable, @unchecked Sendable {
    enum Kind: String, Sendable {
        case directory
        case file
        case symbolicLink
        case otherFiles
        case skippedVolume
    }

    let id: String
    let path: String?
    let name: String
    let kind: Kind
    let logicalBytes: Int64
    let allocatedBytes: Int64
    let children: [FileNode]
    let fileCount: Int
    let directoryCount: Int
    let omittedItemCount: Int
    let isUnreadable: Bool
    let isSharedReference: Bool

    var url: URL? {
        path.map { URL(fileURLWithPath: $0) }
    }

    var isDirectory: Bool {
        kind == .directory
    }

    var canRevealInFinder: Bool {
        url != nil && kind != .otherFiles && kind != .skippedVolume
    }

    var canMoveToTrash: Bool {
        guard canRevealInFinder, let path else { return false }
        let protectedPaths: Set<String> = [
            "/", "/Applications", "/Library", "/System", "/Users",
            "/Volumes", "/bin", "/cores", "/dev", "/etc", "/opt",
            "/private", "/sbin", "/tmp", "/usr", "/var"
        ]
        if protectedPaths.contains(path) { return false }
        if path.hasPrefix("/System/") { return false }
        return true
    }

    func bytes(for metric: SizeMetric) -> Int64 {
        switch metric {
        case .allocated: return allocatedBytes
        case .logical: return logicalBytes
        }
    }

    func formattedSize(for metric: SizeMetric) -> String {
        SizeFormatter.shared.string(fromByteCount: bytes(for: metric))
    }

    init(
        id: String? = nil,
        path: String?,
        name: String,
        kind: Kind,
        logicalBytes: Int64,
        allocatedBytes: Int64,
        children: [FileNode] = [],
        fileCount: Int = 0,
        directoryCount: Int = 0,
        omittedItemCount: Int = 0,
        isUnreadable: Bool = false,
        isSharedReference: Bool = false
    ) {
        self.id = id ?? path ?? "virtual:\(name):\(UUID().uuidString)"
        self.path = path
        self.name = name
        self.kind = kind
        self.logicalBytes = logicalBytes
        self.allocatedBytes = allocatedBytes
        self.children = children
        self.fileCount = fileCount
        self.directoryCount = directoryCount
        self.omittedItemCount = omittedItemCount
        self.isUnreadable = isUnreadable
        self.isSharedReference = isSharedReference
    }
}

extension FileNode: Hashable {
    static func == (lhs: FileNode, rhs: FileNode) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
