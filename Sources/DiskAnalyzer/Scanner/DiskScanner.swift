import Darwin
import Foundation

struct ScanOptions: Sendable {
    var stayOnVolume = true
    var retainedFilesPerDirectory = 40
    var largestItemLimit = 120

    static let `default` = ScanOptions()
}

enum DiskScanError: LocalizedError {
    case pathDoesNotExist(String)
    case rootIsNotDirectory(String)
    case cannotReadMetadata(String)

    var errorDescription: String? {
        switch self {
        case .pathDoesNotExist(let path):
            return L10n.text("scanner.error.path_missing", path)
        case .rootIsNotDirectory(let path):
            return L10n.text("scanner.error.not_directory", path)
        case .cannotReadMetadata(let path):
            return L10n.text("scanner.error.filesystem_info", path)
        }
    }
}

actor DiskScanner {
    private var scanTask: Task<DiskScanResult, Error>?

    func scan(
        from rootURL: URL,
        options: ScanOptions = .default
    ) -> (stream: AsyncStream<ScanProgress>, task: Task<DiskScanResult, Error>) {
        scanTask?.cancel()

        let (stream, continuation) = AsyncStream<ScanProgress>.makeStream()
        let task = Task.detached(priority: .userInitiated) {
            do {
                let result = try Self.performScan(
                    from: rootURL.standardizedFileURL,
                    options: options,
                    continuation: continuation
                )
                continuation.yield(ScanProgress(
                    scannedItems: result.root.fileCount + result.root.directoryCount,
                    scannedFiles: result.root.fileCount,
                    scannedDirectories: result.root.directoryCount,
                    allocatedBytes: result.root.allocatedBytes,
                    currentPath: result.rootURL.path,
                    phase: .done
                ))
                continuation.finish()
                return result
            } catch is CancellationError {
                continuation.yield(.idle)
                continuation.finish()
                throw CancellationError()
            } catch {
                continuation.yield(ScanProgress(
                    scannedItems: 0,
                    scannedFiles: 0,
                    scannedDirectories: 0,
                    allocatedBytes: 0,
                    currentPath: rootURL.path,
                    phase: .failed(error.localizedDescription)
                ))
                continuation.finish()
                throw error
            }
        }

        scanTask = task
        return (stream, task)
    }

    func cancel() {
        scanTask?.cancel()
        scanTask = nil
    }

    private nonisolated static func performScan(
        from rootURL: URL,
        options: ScanOptions,
        continuation: AsyncStream<ScanProgress>.Continuation
    ) throws -> DiskScanResult {
        guard FileManager.default.fileExists(atPath: rootURL.path) else {
            throw DiskScanError.pathDoesNotExist(rootURL.path)
        }
        guard let rootStat = fileStat(at: rootURL) else {
            throw DiskScanError.cannotReadMetadata(rootURL.path)
        }
        guard isDirectory(rootStat) else {
            throw DiskScanError.rootIsNotDirectory(rootURL.path)
        }

        let startedAt = Date.timeIntervalSinceReferenceDate
        let context = ScanContext(
            rootDevice: UInt64(rootStat.st_dev),
            options: options,
            continuation: continuation
        )
        let root = try scanUsingFTS(
            rootURL: rootURL,
            rootStat: rootStat,
            context: context
        )
        context.report(path: rootURL.path, force: true)

        let elapsed = Date.timeIntervalSinceReferenceDate - startedAt
        return DiskScanResult(
            root: root,
            rootURL: rootURL,
            volume: volumeCapacity(for: rootURL),
            isVolumeRoot: isVolumeRoot(rootURL, stat: rootStat),
            elapsedSeconds: elapsed,
            diagnostics: ScanDiagnostics(
                unreadableDirectoryCount: context.unreadableDirectoryCount,
                metadataErrorCount: context.metadataErrorCount,
                skippedVolumes: context.skippedVolumes,
                duplicateDirectoryCount: context.duplicateDirectoryCount,
                duplicateFileCount: context.duplicateFileCount,
                issues: context.issues
            ),
            largestDirectories: context.largestDirectories.values(),
            largestFiles: context.largestFiles.values(),
            scanOptions: options
        )
    }

    private nonisolated static func scanUsingFTS(
        rootURL: URL,
        rootStat: stat,
        context: ScanContext
    ) throws -> FileNode {
        guard let rootPathPointer = strdup(rootURL.path) else {
            throw DiskScanError.cannotReadMetadata(rootURL.path)
        }
        defer { free(rootPathPointer) }

        var paths: [UnsafeMutablePointer<CChar>?] = [rootPathPointer, nil]
        var options = FTS_PHYSICAL | FTS_NOCHDIR
        if context.options.stayOnVolume {
            options |= FTS_XDEV
        }

        guard let handle = paths.withUnsafeMutableBufferPointer({ buffer in
            fts_open(buffer.baseAddress, options, nil)
        }) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { fts_close(handle) }

        var directoryStack: [DirectoryAccumulator] = []
        var skippedDirectoryPaths: Set<String> = []
        var completedRoot: FileNode?
        context.seenDirectories.insert(FileIdentity(rootStat))
        errno = 0

        while let entryPointer = fts_read(handle) {
            try Task.checkCancellation()
            let entry = entryPointer.pointee
            let path = String(cString: entry.fts_path)
            let infoCode = Int32(entry.fts_info)

            switch infoCode {
            case FTS_D:
                guard let statPointer = entry.fts_statp else {
                    context.recordIssue(
                        kind: .metadataUnavailable,
                        path: path,
                        errorCode: entry.fts_errno
                    )
                    context.report(path: path)
                    continue
                }
                let info = statPointer.pointee
                let isTraversalRoot = entry.fts_level == 0

                if !isTraversalRoot {
                    let isRawDataAlias = rootURL.path == "/"
                        && path == "/System/Volumes/Data"
                    let isOtherVolume = context.options.stayOnVolume
                        && UInt64(info.st_dev) != context.rootDevice
                    let identity = FileIdentity(info)
                    let isDuplicate = context.seenDirectories.contains(identity)

                    if isRawDataAlias || isDuplicate {
                        context.duplicateDirectoryCount += 1
                        skippedDirectoryPaths.insert(path)
                        fts_set(handle, entryPointer, FTS_SKIP)
                        context.report(path: path)
                        continue
                    }

                    if isOtherVolume {
                        let skippedVolume = skippedVolumeInfo(
                            for: URL(fileURLWithPath: path, isDirectory: true)
                        )
                        context.skippedVolumes.append(skippedVolume)
                        skippedDirectoryPaths.insert(path)
                        fts_set(handle, entryPointer, FTS_SKIP)
                        directoryStack.last?.specialNodes.append(FileNode(
                            id: "skipped-volume:\(path)",
                            path: path,
                            name: skippedVolume.name,
                            kind: .skippedVolume,
                            logicalBytes: 0,
                            allocatedBytes: 0
                        ))
                        context.report(path: path)
                        continue
                    }

                    context.seenDirectories.insert(identity)
                }

                let accumulator = DirectoryAccumulator(
                    path: path,
                    info: info,
                    retainedFileLimit: context.options.retainedFilesPerDirectory
                )
                directoryStack.append(accumulator)
                context.directoryCount += 1
                context.scannedAllocatedBytes += accumulator.ownAllocatedBytes
                context.report(path: path)

            case FTS_DP:
                if skippedDirectoryPaths.remove(path) != nil {
                    continue
                }
                guard let accumulator = directoryStack.popLast() else {
                    context.metadataErrorCount += 1
                    continue
                }
                guard accumulator.path == path else {
                    throw DiskScanError.cannotReadMetadata(path)
                }

                let node = finalizeDirectory(
                    accumulator,
                    rootURL: rootURL,
                    isRoot: entry.fts_level == 0
                )
                if entry.fts_level == 0 {
                    completedRoot = node
                } else {
                    directoryStack.last?.addDirectory(node)
                    context.largestDirectories.add(node)
                }

            case FTS_DNR:
                guard let statPointer = entry.fts_statp else {
                    context.recordIssue(
                        kind: .metadataUnavailable,
                        path: path,
                        errorCode: entry.fts_errno
                    )
                    context.report(path: path)
                    continue
                }
                let info = statPointer.pointee
                context.recordIssue(
                    kind: .unreadableDirectory,
                    path: path,
                    errorCode: entry.fts_errno
                )
                if directoryStack.last?.path == path,
                   let accumulator = directoryStack.popLast() {
                    accumulator.isUnreadable = true
                    let node = finalizeDirectory(
                        accumulator,
                        rootURL: rootURL,
                        isRoot: entry.fts_level == 0
                    )
                    if entry.fts_level == 0 {
                        completedRoot = node
                    } else {
                        directoryStack.last?.addDirectory(node)
                        context.largestDirectories.add(node)
                    }
                    context.report(path: path)
                    continue
                }

                let identity = FileIdentity(info)
                if context.seenDirectories.contains(identity) {
                    context.duplicateDirectoryCount += 1
                    continue
                }
                context.seenDirectories.insert(identity)

                let accumulator = DirectoryAccumulator(
                    path: path,
                    info: info,
                    retainedFileLimit: context.options.retainedFilesPerDirectory
                )
                accumulator.isUnreadable = true
                context.directoryCount += 1
                context.scannedAllocatedBytes += accumulator.ownAllocatedBytes
                let node = finalizeDirectory(
                    accumulator,
                    rootURL: rootURL,
                    isRoot: entry.fts_level == 0
                )
                if entry.fts_level == 0 {
                    completedRoot = node
                } else {
                    directoryStack.last?.addDirectory(node)
                    context.largestDirectories.add(node)
                }
                context.report(path: path)

            case FTS_F, FTS_DEFAULT, FTS_SL, FTS_SLNONE:
                guard let statPointer = entry.fts_statp else {
                    context.recordIssue(
                        kind: .metadataUnavailable,
                        path: path,
                        errorCode: entry.fts_errno
                    )
                    context.report(path: path)
                    continue
                }
                guard let parent = directoryStack.last else {
                    context.recordIssue(
                        kind: .metadataUnavailable,
                        path: path,
                        errorCode: entry.fts_errno
                    )
                    continue
                }

                let info = statPointer.pointee
                let identity = FileIdentity(info)
                let firstReference = context.seenFiles.insert(identity).inserted
                let logical = max(Int64(info.st_size), 0)
                let childAllocated = firstReference ? allocatedBytes(info) : 0
                if !firstReference {
                    context.duplicateFileCount += 1
                }

                let kind: FileNode.Kind = infoCode == FTS_SL || infoCode == FTS_SLNONE
                    ? .symbolicLink
                    : .file
                let node = FileNode(
                    path: path,
                    name: URL(fileURLWithPath: path).lastPathComponent,
                    kind: kind,
                    logicalBytes: logical,
                    allocatedBytes: childAllocated,
                    fileCount: 1,
                    isSharedReference: !firstReference || info.st_nlink > 1
                )
                parent.addFile(node)
                context.fileCount += 1
                context.scannedAllocatedBytes += childAllocated
                context.largestFiles.add(node)
                context.report(path: path)

            case FTS_DC:
                context.duplicateDirectoryCount += 1
                context.report(path: path)

            case FTS_ERR, FTS_NS:
                context.recordIssue(
                    kind: .metadataUnavailable,
                    path: path,
                    errorCode: entry.fts_errno
                )
                context.report(path: path)

            default:
                // Socket, device and whiteout entries have no meaningful
                // user-cleanable payload. Their directory metadata remains covered.
                context.report(path: path)
            }
        }

        if errno != 0 {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard let completedRoot else {
            throw DiskScanError.cannotReadMetadata(rootURL.path)
        }
        return completedRoot
    }

    private nonisolated static func finalizeDirectory(
        _ accumulator: DirectoryAccumulator,
        rootURL: URL,
        isRoot: Bool
    ) -> FileNode {
        var children = accumulator.directoryNodes
        children.append(contentsOf: accumulator.directFiles.valuesWithAggregate(
            parentPath: accumulator.path
        ))
        children.append(contentsOf: accumulator.specialNodes)
        children.sort(by: defaultNodeOrder)

        let url = URL(fileURLWithPath: accumulator.path, isDirectory: true)
        return FileNode(
            path: accumulator.path,
            name: rootDisplayName(for: isRoot ? rootURL : url, isRoot: isRoot),
            kind: .directory,
            logicalBytes: accumulator.logicalBytes,
            allocatedBytes: accumulator.allocatedBytes,
            ownLogicalBytes: accumulator.ownLogicalBytes,
            ownAllocatedBytes: accumulator.ownAllocatedBytes,
            children: children,
            fileCount: accumulator.fileCount,
            directoryCount: accumulator.directoryCount,
            isUnreadable: accumulator.isUnreadable
        )
    }

    private nonisolated static func rootDisplayName(for url: URL, isRoot: Bool) -> String {
        if isRoot, url.path == "/" {
            return volumeCapacity(for: url)?.name ?? "Macintosh HD"
        }
        return url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
    }

    private nonisolated static func defaultNodeOrder(_ lhs: FileNode, _ rhs: FileNode) -> Bool {
        if lhs.allocatedBytes != rhs.allocatedBytes {
            return lhs.allocatedBytes > rhs.allocatedBytes
        }
        if lhs.logicalBytes != rhs.logicalBytes {
            return lhs.logicalBytes > rhs.logicalBytes
        }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    private nonisolated static func fileStat(at url: URL) -> stat? {
        var info = Darwin.stat()
        let result: Int32 = url.withUnsafeFileSystemRepresentation { pathPointer in
            guard let pathPointer else { return -1 }
            return Darwin.lstat(pathPointer, &info)
        }
        return result == 0 ? info : nil
    }

    private nonisolated static func isDirectory(_ info: stat) -> Bool {
        (info.st_mode & S_IFMT) == S_IFDIR
    }

    private nonisolated static func isSymbolicLink(_ info: stat) -> Bool {
        (info.st_mode & S_IFMT) == S_IFLNK
    }

    private nonisolated static func allocatedBytes(_ info: stat) -> Int64 {
        max(Int64(info.st_blocks) * 512, 0)
    }

    private nonisolated static func volumeCapacity(for url: URL) -> VolumeCapacity? {
        let keys: Set<URLResourceKey> = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey
        ]
        guard let values = try? url.resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity else {
            return nil
        }
        let available = values.volumeAvailableCapacityForImportantUsage
            ?? Int64(values.volumeAvailableCapacity ?? 0)
        return VolumeCapacity(
            name: values.volumeName ?? L10n.text("scanner.default_volume"),
            totalBytes: Int64(total),
            availableBytes: max(available, 0)
        )
    }

    private nonisolated static func skippedVolumeInfo(
        for url: URL
    ) -> SkippedVolumeInfo {
        let keys: Set<URLResourceKey> = [
            .volumeNameKey,
            .volumeIsLocalKey,
            .volumeIsRemovableKey,
            .volumeIsEjectableKey
        ]
        let values = try? url.resourceValues(forKeys: keys)
        let resourceName = values?.volumeName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackName = url.lastPathComponent.isEmpty
            ? url.path
            : url.lastPathComponent
        let name = resourceName.flatMap { $0.isEmpty ? nil : $0 } ?? fallbackName
        let kind = SkippedVolumeInfo.Kind.infer(
            path: url.path,
            isLocal: values?.volumeIsLocal,
            isRemovable: values?.volumeIsRemovable,
            isEjectable: values?.volumeIsEjectable
        )
        return SkippedVolumeInfo(name: name, path: url.path, kind: kind)
    }

    private nonisolated static func isVolumeRoot(_ url: URL, stat info: stat) -> Bool {
        if url.path == "/" { return true }
        let parent = url.deletingLastPathComponent()
        guard parent.path != url.path, let parentInfo = fileStat(at: parent) else {
            return true
        }
        return parentInfo.st_dev != info.st_dev
    }
}

private struct FileIdentity: Hashable {
    let device: UInt64
    let inode: UInt64

    init(_ info: stat) {
        device = UInt64(info.st_dev)
        inode = UInt64(info.st_ino)
    }
}

private final class DirectoryAccumulator {
    let path: String
    let ownLogicalBytes: Int64
    let ownAllocatedBytes: Int64
    let directFiles: BoundedNodeCollector

    var logicalBytes: Int64
    var allocatedBytes: Int64
    var fileCount = 0
    var directoryCount = 1
    var directoryNodes: [FileNode] = []
    var specialNodes: [FileNode] = []
    var isUnreadable = false

    init(path: String, info: stat, retainedFileLimit: Int) {
        self.path = path
        self.ownLogicalBytes = max(Int64(info.st_size), 0)
        self.ownAllocatedBytes = max(Int64(info.st_blocks) * 512, 0)
        self.logicalBytes = ownLogicalBytes
        self.allocatedBytes = ownAllocatedBytes
        self.directFiles = BoundedNodeCollector(
            limit: retainedFileLimit,
            minimumRetainedBytes: 128 * 1_024,
            alwaysRetainCount: min(retainedFileLimit, 4)
        )
    }

    func addFile(_ node: FileNode) {
        directFiles.add(node)
        logicalBytes += node.logicalBytes
        allocatedBytes += node.allocatedBytes
        fileCount += 1
    }

    func addDirectory(_ node: FileNode) {
        directoryNodes.append(node)
        logicalBytes += node.logicalBytes
        allocatedBytes += node.allocatedBytes
        fileCount += node.fileCount
        directoryCount += node.directoryCount
    }
}

private final class ScanContext {
    let rootDevice: UInt64
    let options: ScanOptions
    let continuation: AsyncStream<ScanProgress>.Continuation
    let largestDirectories: BoundedNodeCollector
    let largestFiles: BoundedNodeCollector

    var seenDirectories: Set<FileIdentity> = []
    var seenFiles: Set<FileIdentity> = []
    var fileCount = 0
    var directoryCount = 0
    var scannedAllocatedBytes: Int64 = 0
    var unreadableDirectoryCount = 0
    var metadataErrorCount = 0
    var skippedVolumes: [SkippedVolumeInfo] = []
    var duplicateDirectoryCount = 0
    var duplicateFileCount = 0
    var issues: [ScanIssue] = []

    private var lastReportedItemCount = 0
    private var lastReportedAt = Date.timeIntervalSinceReferenceDate

    init(
        rootDevice: UInt64,
        options: ScanOptions,
        continuation: AsyncStream<ScanProgress>.Continuation
    ) {
        self.rootDevice = rootDevice
        self.options = options
        self.continuation = continuation
        self.largestDirectories = BoundedNodeCollector(limit: options.largestItemLimit)
        self.largestFiles = BoundedNodeCollector(limit: options.largestItemLimit)
    }

    func recordIssue(kind: ScanIssue.Kind, path: String, errorCode: Int32) {
        issues.append(ScanIssue(kind: kind, path: path, errorCode: errorCode))
        switch kind {
        case .unreadableDirectory:
            unreadableDirectoryCount += 1
        case .metadataUnavailable:
            metadataErrorCount += 1
        }
    }

    func report(path: String, force: Bool = false) {
        let itemCount = fileCount + directoryCount
        let now = Date.timeIntervalSinceReferenceDate
        guard force || itemCount - lastReportedItemCount >= 500 || now - lastReportedAt >= 0.15 else {
            return
        }
        lastReportedItemCount = itemCount
        lastReportedAt = now
        continuation.yield(ScanProgress(
            scannedItems: itemCount,
            scannedFiles: fileCount,
            scannedDirectories: directoryCount,
            allocatedBytes: scannedAllocatedBytes,
            currentPath: path,
            phase: .scanning
        ))
    }
}

private final class BoundedNodeCollector {
    private let limit: Int
    private let minimumRetainedBytes: Int64
    private let alwaysRetainCount: Int
    private var buffer: [FileNode] = []
    private var totalLogicalBytes: Int64 = 0
    private var totalAllocatedBytes: Int64 = 0
    private var totalItemCount = 0

    init(
        limit: Int,
        minimumRetainedBytes: Int64 = 0,
        alwaysRetainCount: Int? = nil
    ) {
        self.limit = max(limit, 1)
        self.minimumRetainedBytes = max(minimumRetainedBytes, 0)
        self.alwaysRetainCount = min(max(alwaysRetainCount ?? limit, 0), self.limit)
    }

    func add(_ node: FileNode) {
        totalLogicalBytes += node.logicalBytes
        totalAllocatedBytes += node.allocatedBytes
        totalItemCount += 1
        buffer.append(node)
        if buffer.count > limit * 4 {
            trim(forceThreshold: true)
        }
    }

    func values() -> [FileNode] {
        trim(forceThreshold: false)
        return buffer.sorted(by: nodeOrder)
    }

    func valuesWithAggregate(parentPath: String) -> [FileNode] {
        trim(forceThreshold: true)
        var nodes = buffer.sorted(by: nodeOrder)
        let omittedCount = totalItemCount - nodes.count
        guard omittedCount > 0 else { return nodes }

        let retainedLogical = nodes.reduce(Int64(0)) { $0 + $1.logicalBytes }
        let retainedAllocated = nodes.reduce(Int64(0)) { $0 + $1.allocatedBytes }
        nodes.append(FileNode(
            id: "aggregate:\(parentPath)",
            path: nil,
            name: L10n.text("scanner.other_files", omittedCount.formatted()),
            kind: .otherFiles,
            logicalBytes: max(totalLogicalBytes - retainedLogical, 0),
            allocatedBytes: max(totalAllocatedBytes - retainedAllocated, 0),
            fileCount: omittedCount,
            omittedItemCount: omittedCount
        ))
        return nodes
    }

    private func trim(forceThreshold: Bool) {
        guard forceThreshold || buffer.count > limit * 2 else { return }

        // Keep the union of both rankings. A sparse file can be huge logically
        // but tiny on disk, while a compressed or cloned file can rank very
        // differently between the two metrics.
        let byAllocated = Array(buffer.sorted {
            if $0.allocatedBytes != $1.allocatedBytes {
                return $0.allocatedBytes > $1.allocatedBytes
            }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }.prefix(limit))
        let byLogical = Array(buffer.sorted {
            if $0.logicalBytes != $1.logicalBytes {
                return $0.logicalBytes > $1.logicalBytes
            }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }.prefix(limit))

        var retained: [String: FileNode] = [:]
        for (index, node) in byAllocated.enumerated()
        where index < alwaysRetainCount || node.allocatedBytes >= minimumRetainedBytes {
            retained[node.id] = node
        }
        for (index, node) in byLogical.enumerated()
        where index < alwaysRetainCount || node.logicalBytes >= minimumRetainedBytes {
            retained[node.id] = node
        }
        buffer = Array(retained.values)
    }

    private func nodeOrder(_ lhs: FileNode, _ rhs: FileNode) -> Bool {
        let lhsScore = max(lhs.allocatedBytes, lhs.logicalBytes)
        let rhsScore = max(rhs.allocatedBytes, rhs.logicalBytes)
        if lhsScore != rhsScore { return lhsScore > rhsScore }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}
