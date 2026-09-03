import Darwin
import Foundation

enum LargeFileThreshold {
    static let defaultMegabytes = 100
    static let minimumMegabytes = 1
    static let maximumMegabytes = Int(Int64.max / 1_000_000)

    static func clampedMegabytes(_ value: Int) -> Int {
        min(max(value, minimumMegabytes), maximumMegabytes)
    }

    static func bytes(forMegabytes value: Int) -> Int64 {
        Int64(clampedMegabytes(value)) * 1_000_000
    }
}

struct LargeFileMatch: Identifiable, Equatable, Sendable {
    let url: URL
    let logicalBytes: Int64
    let allocatedBytes: Int64

    var id: String { url.path }
}

struct LargeFileScanDiagnostics: Equatable, Sendable {
    var unreadableDirectoryCount = 0
    var metadataErrorCount = 0
    var skippedVolumeCount = 0
    var duplicateDirectoryCount = 0

    var hasCoverageWarning: Bool {
        unreadableDirectoryCount > 0 || metadataErrorCount > 0
    }
}

struct LargeFileScanResult: Equatable, Sendable {
    let rootURL: URL
    let thresholdBytes: Int64
    let files: [LargeFileMatch]
    let scannedFileCount: Int
    let scannedDirectoryCount: Int
    let elapsedSeconds: Double
    let diagnostics: LargeFileScanDiagnostics
}

struct LargeFileScanProgress: Sendable {
    enum Phase: Sendable {
        case scanning
        case done
    }

    let scannedFileCount: Int
    let scannedDirectoryCount: Int
    let matchCount: Int
    let currentPath: String
    let phase: Phase
}

actor LargeFileScanner {
    private var scanTask: Task<LargeFileScanResult, Error>?

    func scan(
        from rootURL: URL,
        thresholdBytes: Int64,
        stayOnVolume: Bool = true
    ) -> (
        stream: AsyncStream<LargeFileScanProgress>,
        task: Task<LargeFileScanResult, Error>
    ) {
        scanTask?.cancel()

        let (stream, continuation) = AsyncStream<LargeFileScanProgress>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let task = Task.detached(priority: .userInitiated) {
            do {
                let result = try Self.performScan(
                    from: rootURL.standardizedFileURL,
                    thresholdBytes: max(thresholdBytes, 0),
                    stayOnVolume: stayOnVolume,
                    continuation: continuation
                )
                continuation.yield(LargeFileScanProgress(
                    scannedFileCount: result.scannedFileCount,
                    scannedDirectoryCount: result.scannedDirectoryCount,
                    matchCount: result.files.count,
                    currentPath: result.rootURL.path,
                    phase: .done
                ))
                continuation.finish()
                return result
            } catch {
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
        thresholdBytes: Int64,
        stayOnVolume: Bool,
        continuation: AsyncStream<LargeFileScanProgress>.Continuation
    ) throws -> LargeFileScanResult {
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
        let context = LargeFileScanContext(
            rootDevice: stableDeviceID(rootStat),
            continuation: continuation
        )
        context.seenDirectories.insert(LargeFileIdentity(rootStat))

        guard let rootPathPointer = strdup(rootURL.path) else {
            throw DiskScanError.cannotReadMetadata(rootURL.path)
        }
        defer { free(rootPathPointer) }

        var paths: [UnsafeMutablePointer<CChar>?] = [rootPathPointer, nil]
        var traversalOptions = FTS_PHYSICAL | FTS_NOCHDIR
        if stayOnVolume {
            traversalOptions |= FTS_XDEV
        }

        guard let handle = paths.withUnsafeMutableBufferPointer({ buffer in
            fts_open(buffer.baseAddress, traversalOptions, nil)
        }) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { fts_close(handle) }

        while true {
            try Task.checkCancellation()
            errno = 0
            guard let entryPointer = fts_read(handle) else {
                if errno != 0 {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                break
            }

            let entry = entryPointer.pointee
            let path = String(cString: entry.fts_path)
            let infoCode = Int32(entry.fts_info)

            switch infoCode {
            case FTS_D:
                guard let statPointer = entry.fts_statp else {
                    context.metadataErrorCount += 1
                    fts_set(handle, entryPointer, FTS_SKIP)
                    context.report(path: path)
                    continue
                }

                let info = statPointer.pointee
                let isTraversalRoot = entry.fts_level == 0
                if !isTraversalRoot {
                    let isRawDataAlias = rootURL.path == "/"
                        && path == "/System/Volumes/Data"
                    let isOtherVolume = stayOnVolume
                        && stableDeviceID(info) != context.rootDevice
                    let identity = LargeFileIdentity(info)
                    let isDuplicate = context.seenDirectories.contains(identity)

                    if isRawDataAlias || isDuplicate {
                        context.duplicateDirectoryCount += 1
                        fts_set(handle, entryPointer, FTS_SKIP)
                        context.report(path: path)
                        continue
                    }

                    if isOtherVolume {
                        context.skippedVolumeCount += 1
                        fts_set(handle, entryPointer, FTS_SKIP)
                        context.report(path: path)
                        continue
                    }

                    context.seenDirectories.insert(identity)
                }

                context.scannedDirectoryCount += 1
                context.report(path: path)

            case FTS_DNR:
                context.unreadableDirectoryCount += 1
                context.report(path: path)

            case FTS_F:
                guard let statPointer = entry.fts_statp else {
                    context.metadataErrorCount += 1
                    context.report(path: path)
                    continue
                }

                let info = statPointer.pointee
                let logicalBytes = max(Int64(info.st_size), 0)
                context.scannedFileCount += 1
                if logicalBytes > thresholdBytes {
                    context.files.append(LargeFileMatch(
                        url: URL(fileURLWithPath: path),
                        logicalBytes: logicalBytes,
                        allocatedBytes: allocatedBytes(info)
                    ))
                }
                context.report(path: path)

            case FTS_ERR, FTS_NS:
                context.metadataErrorCount += 1
                context.report(path: path)

            default:
                // Physical traversal deliberately ignores symbolic links,
                // sockets, devices and other non-regular directory entries.
                context.report(path: path)
            }
        }

        context.report(path: rootURL.path, force: true)
        context.files.sort { lhs, rhs in
            if lhs.logicalBytes != rhs.logicalBytes {
                return lhs.logicalBytes > rhs.logicalBytes
            }
            return lhs.url.path.localizedStandardCompare(rhs.url.path) == .orderedAscending
        }

        return LargeFileScanResult(
            rootURL: rootURL,
            thresholdBytes: thresholdBytes,
            files: context.files,
            scannedFileCount: context.scannedFileCount,
            scannedDirectoryCount: context.scannedDirectoryCount,
            elapsedSeconds: Date.timeIntervalSinceReferenceDate - startedAt,
            diagnostics: LargeFileScanDiagnostics(
                unreadableDirectoryCount: context.unreadableDirectoryCount,
                metadataErrorCount: context.metadataErrorCount,
                skippedVolumeCount: context.skippedVolumeCount,
                duplicateDirectoryCount: context.duplicateDirectoryCount
            )
        )
    }

    private nonisolated static func fileStat(at url: URL) -> stat? {
        var info = Darwin.stat()
        let result: Int32 = url.withUnsafeFileSystemRepresentation { pointer in
            guard let pointer else { return -1 }
            return Darwin.lstat(pointer, &info)
        }
        return result == 0 ? info : nil
    }

    private nonisolated static func isDirectory(_ info: stat) -> Bool {
        (info.st_mode & S_IFMT) == S_IFDIR
    }

    private nonisolated static func stableDeviceID(_ info: stat) -> UInt64 {
        UInt64(UInt32(bitPattern: info.st_dev))
    }

    private nonisolated static func allocatedBytes(_ info: stat) -> Int64 {
        max(Int64(info.st_blocks) * 512, 0)
    }
}

private struct LargeFileIdentity: Hashable {
    let device: UInt64
    let inode: UInt64

    init(_ info: stat) {
        device = UInt64(UInt32(bitPattern: info.st_dev))
        inode = UInt64(info.st_ino)
    }
}

private final class LargeFileScanContext {
    let rootDevice: UInt64
    let continuation: AsyncStream<LargeFileScanProgress>.Continuation

    var files: [LargeFileMatch] = []
    var seenDirectories: Set<LargeFileIdentity> = []
    var scannedFileCount = 0
    var scannedDirectoryCount = 0
    var unreadableDirectoryCount = 0
    var metadataErrorCount = 0
    var skippedVolumeCount = 0
    var duplicateDirectoryCount = 0

    private var lastReportedItemCount = 0
    private var lastReportedAt = Date.timeIntervalSinceReferenceDate

    init(
        rootDevice: UInt64,
        continuation: AsyncStream<LargeFileScanProgress>.Continuation
    ) {
        self.rootDevice = rootDevice
        self.continuation = continuation
    }

    func report(path: String, force: Bool = false) {
        let itemCount = scannedFileCount + scannedDirectoryCount
        let now = Date.timeIntervalSinceReferenceDate
        let itemDelta = itemCount - lastReportedItemCount
        let elapsed = now - lastReportedAt
        let batchIsReady = itemDelta >= 500 && elapsed >= 0.15
        let heartbeatIsDue = elapsed >= 1
        guard force || batchIsReady || heartbeatIsDue else { return }

        lastReportedItemCount = itemCount
        lastReportedAt = now
        continuation.yield(LargeFileScanProgress(
            scannedFileCount: scannedFileCount,
            scannedDirectoryCount: scannedDirectoryCount,
            matchCount: files.count,
            currentPath: path,
            phase: .scanning
        ))
    }
}
