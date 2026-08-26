import Darwin
import Foundation

struct VolumeCapacity: Sendable {
    let name: String
    let totalBytes: Int64
    let availableBytes: Int64

    var usedBytes: Int64 {
        max(totalBytes - availableBytes, 0)
    }
}

struct SkippedVolumeInfo: Identifiable, Hashable, Sendable {
    enum Kind: String, Hashable, Sendable {
        case system
        case externalOrDiskImage
        case network
        case other

        var title: String {
            switch self {
            case .system: return L10n.text("volume.kind.system")
            case .externalOrDiskImage: return L10n.text("volume.kind.external")
            case .network: return L10n.text("volume.kind.network")
            case .other: return L10n.text("volume.kind.other")
            }
        }

        var systemImage: String {
            switch self {
            case .system: return "internaldrive"
            case .externalOrDiskImage: return "externaldrive"
            case .network: return "network"
            case .other: return "externaldrive.badge.questionmark"
            }
        }

        static func infer(
            path: String,
            isLocal: Bool?,
            isRemovable: Bool?,
            isEjectable: Bool?
        ) -> Self {
            if path.hasPrefix("/System/Volumes/") {
                return .system
            }
            if isLocal == false {
                return .network
            }
            if path.hasPrefix("/Volumes/")
                || isRemovable == true
                || isEjectable == true {
                return .externalOrDiskImage
            }
            return .other
        }
    }

    let name: String
    let path: String
    let kind: Kind

    var id: String { path }
}

struct ScanIssue: Identifiable, Hashable, Sendable {
    enum Kind: String, Hashable, Sendable {
        case unreadableDirectory
        case metadataUnavailable

        var title: String {
            switch self {
            case .unreadableDirectory: return L10n.text("issue.kind.unreadable_directory")
            case .metadataUnavailable: return L10n.text("issue.kind.metadata_unavailable")
            }
        }

        var systemImage: String {
            switch self {
            case .unreadableDirectory: return "folder.badge.questionmark"
            case .metadataUnavailable: return "doc.badge.ellipsis"
            }
        }
    }

    let kind: Kind
    let path: String
    let errorCode: Int32

    var id: String { "\(kind.rawValue):\(errorCode):\(path)" }

    var errorDescription: String {
        guard errorCode != 0 else { return L10n.text("issue.error.no_posix") }
        let symbol: String
        switch errorCode {
        case EPERM: symbol = "EPERM"
        case EACCES: symbol = "EACCES"
        case ENOENT: symbol = "ENOENT"
        case EIO: symbol = "EIO"
        case ELOOP: symbol = "ELOOP"
        case ENAMETOOLONG: symbol = "ENAMETOOLONG"
        default: symbol = "errno"
        }
        return L10n.text(
            "issue.error.format",
            symbol,
            Int(errorCode).formatted(),
            String(cString: strerror(errorCode))
        )
    }
}

struct ScanDiagnostics: Sendable {
    let unreadableDirectoryCount: Int
    let metadataErrorCount: Int
    let skippedVolumes: [SkippedVolumeInfo]
    let duplicateDirectoryCount: Int
    let duplicateFileCount: Int
    let issues: [ScanIssue]

    init(
        unreadableDirectoryCount: Int,
        metadataErrorCount: Int,
        skippedVolumes: [SkippedVolumeInfo] = [],
        duplicateDirectoryCount: Int,
        duplicateFileCount: Int,
        issues: [ScanIssue] = []
    ) {
        self.unreadableDirectoryCount = unreadableDirectoryCount
        self.metadataErrorCount = metadataErrorCount
        self.skippedVolumes = skippedVolumes.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
        self.duplicateDirectoryCount = duplicateDirectoryCount
        self.duplicateFileCount = duplicateFileCount
        self.issues = issues
    }

    var issueCount: Int {
        unreadableDirectoryCount + metadataErrorCount
    }

    var skippedVolumeCount: Int { skippedVolumes.count }

    var unreadableDirectoryIssues: [ScanIssue] {
        issues.filter { $0.kind == .unreadableDirectory }
    }

    var metadataIssues: [ScanIssue] {
        issues.filter { $0.kind == .metadataUnavailable }
    }

    var hasCoverageWarning: Bool {
        unreadableDirectoryCount > 0 || metadataErrorCount > 0
    }

    var coverageSummary: String? {
        var parts: [String] = []
        if unreadableDirectoryCount > 0 {
            parts.append(L10n.text(
                "diagnostics.unreadable_directories",
                unreadableDirectoryCount.formatted()
            ))
        }
        if metadataErrorCount > 0 {
            parts.append(L10n.text(
                "diagnostics.metadata_errors",
                metadataErrorCount.formatted()
            ))
        }
        return parts.isEmpty ? nil : parts.joined(separator: L10n.text("diagnostics.list_separator"))
    }

    var skippedVolumesSummary: String? {
        guard skippedVolumeCount > 0 else { return nil }
        return L10n.text("diagnostics.skipped_volumes", skippedVolumeCount.formatted())
    }

    var skippedVolumeNamesPreview: String? {
        guard !skippedVolumes.isEmpty else { return nil }
        let names = skippedVolumes.prefix(3)
            .map(\.name)
            .joined(separator: L10n.text("diagnostics.list_separator"))
        return skippedVolumes.count > 3
            ? L10n.text("diagnostics.list_more", names)
            : names
    }
}

struct DiskScanResult: @unchecked Sendable {
    let root: FileNode
    let rootURL: URL
    let volume: VolumeCapacity?
    let isVolumeRoot: Bool
    let elapsedSeconds: TimeInterval
    let diagnostics: ScanDiagnostics
    let largestDirectories: [FileNode]
    let largestFiles: [FileNode]

    var scannedAllocatedBytes: Int64 { root.allocatedBytes }
    var scannedLogicalBytes: Int64 { root.logicalBytes }

    var volumeReconciliationDifference: Int64? {
        guard isVolumeRoot, let volume else { return nil }
        return volume.usedBytes - scannedAllocatedBytes
    }
}
