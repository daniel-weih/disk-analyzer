import AVFoundation
import CryptoKit
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

enum VideoComparisonMethod: String, CaseIterable, Identifiable, Sendable {
    case exact
    case similar
    var id: String { rawValue }
    var title: String { L10n.text("videos.method.\(rawValue)") }
}

struct VideoScanConfiguration: Equatable, Sendable {
    static let defaultSimilarityPercent = 80
    var method: VideoComparisonMethod = .exact
    var similarityPercent = Self.defaultSimilarityPercent

    var normalized: Self {
        Self(method: method, similarityPercent: min(max(similarityPercent, 70), 100))
    }
    var maximumDistance: Double {
        VisionFeatureSimilarityScale.distance(forSimilarityPercent: normalized.similarityPercent)
    }
}

struct VideoPreviewFrame: Equatable, Sendable {
    let seconds: Double
    let jpeg: Data
}

struct DuplicateVideoItem: Identifiable, Equatable, Sendable {
    let url: URL
    let logicalBytes: Int64
    var duration: Double?
    var pixelWidth: Int?
    var pixelHeight: Int?
    var audioTrackCount: Int?
    var previews: [VideoPreviewFrame] = []
    var id: String { url.path }
}

struct DuplicateVideoMember: Identifiable, Equatable, Sendable {
    var item: DuplicateVideoItem
    let maximumFrameDistance: Double?
    let isReference: Bool
    var id: String { item.id }
}

struct DuplicateVideoGroup: Identifiable, Equatable, Sendable {
    var members: [DuplicateVideoMember]
    var id: String { members.first?.id ?? "empty-video-group" }
    var totalBytes: Int64 { members.reduce(0) { $0 + $1.item.logicalBytes } }
}

struct VideoScanDiagnostics: Equatable, Sendable {
    var unreadableDirectoryCount = 0
    var metadataErrorCount = 0
    var skippedVolumeCount = 0
    var linkedFileCount = 0
    var readErrorCount = 0
    var changedFileCount = 0
    var previewErrorCount = 0
    var hasCoverageWarning: Bool {
        unreadableDirectoryCount + metadataErrorCount + readErrorCount + changedFileCount > 0
    }
}

struct VideoScanResult: Equatable, Sendable {
    let rootURL: URL
    let configuration: VideoScanConfiguration
    let groups: [DuplicateVideoGroup]
    let scannedFileCount: Int
    let candidateVideoCount: Int
    let analyzedVideoCount: Int
    let elapsedSeconds: Double
    let diagnostics: VideoScanDiagnostics
    var groupedVideoCount: Int { groups.reduce(0) { $0 + $1.members.count } }
}

struct VideoScanProgress: Sendable {
    enum Phase: String, Sendable { case discovering, hashing, analyzing, comparing, previews, done }
    let phase: Phase
    let scannedFileCount: Int
    let candidateVideoCount: Int
    let completedCount: Int
    let totalCount: Int
    let currentPath: String
}

actor VideoDuplicateScanner {
    private var scanTask: Task<VideoScanResult, Error>?

    func scan(from rootURL: URL, configuration: VideoScanConfiguration = .init()) -> (
        stream: AsyncStream<VideoScanProgress>, task: Task<VideoScanResult, Error>
    ) {
        scanTask?.cancel()
        let (stream, continuation) = AsyncStream<VideoScanProgress>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let task = Task.detached(priority: .userInitiated) {
            defer { continuation.finish() }
            return try await VideoScanWorker(
                rootURL: rootURL.standardizedFileURL,
                configuration: configuration.normalized,
                continuation: continuation
            ).run()
        }
        scanTask = task
        return (stream, task)
    }

    func cancel() {
        scanTask?.cancel()
        scanTask = nil
    }
}

/// Captured before reading, checked against the opened descriptor and again
/// after reading. Replaced, truncated or edited files cannot become matches.
private struct VideoFileStamp: Equatable {
    let device: dev_t
    let inode: ino_t
    let size: off_t
    let modified: timespec
    let changed: timespec

    init(_ info: stat) {
        device = info.st_dev
        inode = info.st_ino
        size = info.st_size
        modified = info.st_mtimespec
        changed = info.st_ctimespec
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.device == rhs.device && lhs.inode == rhs.inode && lhs.size == rhs.size
            && lhs.modified.tv_sec == rhs.modified.tv_sec
            && lhs.modified.tv_nsec == rhs.modified.tv_nsec
            && lhs.changed.tv_sec == rhs.changed.tv_sec
            && lhs.changed.tv_nsec == rhs.changed.tv_nsec
    }
}

private struct VideoFileIdentity: Hashable {
    let device: dev_t
    let inode: ino_t
    init(_ info: stat) { device = info.st_dev; inode = info.st_ino }
}

private struct VideoCandidate {
    let url: URL
    let stamp: VideoFileStamp
    var item: DuplicateVideoItem { DuplicateVideoItem(url: url, logicalBytes: stamp.size) }

    func validate() throws {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              VideoFileStamp(info) == stamp else { throw VideoReadError.changed }
    }

    func openForReading() throws -> FileHandle {
        // O_NONBLOCK prevents a replaced FIFO from blocking before fstat.
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try validate(handle)
        return handle
    }

    func validate(_ handle: FileHandle) throws {
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              VideoFileStamp(info) == stamp else { throw VideoReadError.changed }
        try validate()
    }
}

private enum VideoReadError: LocalizedError {
    case changed, undecodable, invalidFeature
    var errorDescription: String? {
        switch self {
        case .changed: return L10n.text("videos.error.changed")
        case .undecodable: return L10n.text("videos.error.undecodable")
        case .invalidFeature: return L10n.text("videos.error.feature")
        }
    }
}

private struct VideoFingerprint {
    let candidate: VideoCandidate
    let item: DuplicateVideoItem
    let frames: [VNFeaturePrintObservation]
}

/// Confined to one detached scan task; no file contents or fingerprints persist.
private final class VideoScanWorker {
    let rootURL: URL
    let configuration: VideoScanConfiguration
    let continuation: AsyncStream<VideoScanProgress>.Continuation
    var diagnostics = VideoScanDiagnostics()
    var candidates: [VideoCandidate] = []
    var scannedFileCount = 0
    var analyzedVideoCount = 0
    var phase: VideoScanProgress.Phase = .discovering
    var completedCount = 0
    var totalCount = 0
    var lastReport = Date.distantPast
    var changedPaths: Set<String> = []

    init(rootURL: URL, configuration: VideoScanConfiguration,
         continuation: AsyncStream<VideoScanProgress>.Continuation) {
        self.rootURL = rootURL
        self.configuration = configuration
        self.continuation = continuation
    }

    func run() async throws -> VideoScanResult {
        let started = Date()
        try discover()
        var groups = configuration.method == .exact
            ? try exactGroups() : try await similarGroups()
        phase = .previews
        totalCount = groups.reduce(0) { $0 + $1.members.count }
        completedCount = 0
        let byPath = Dictionary(uniqueKeysWithValues: candidates.map { ($0.url.path, $0) })
        for groupIndex in groups.indices {
            for memberIndex in groups[groupIndex].members.indices {
                try Task.checkCancellation()
                let path = groups[groupIndex].members[memberIndex].id
                guard let candidate = byPath[path] else { continue }
                report(path, force: true)
                do {
                    groups[groupIndex].members[memberIndex].item = try await readVideo(
                        candidate, features: false
                    ).item
                } catch {
                    try Task.checkCancellation()
                    if case VideoReadError.changed = error { record(error, candidate) }
                    else { diagnostics.previewErrorCount += 1 }
                }
                completedCount += 1
            }
        }
        // A scan is a snapshot. Recheck every published path after all the slow
        // hashing/decoding work, and drop groups whose reference changed.
        for groupIndex in groups.indices {
            for member in groups[groupIndex].members {
                try Task.checkCancellation()
                if let candidate = byPath[member.id] {
                    do { try candidate.validate() } catch { record(error, candidate) }
                }
            }
            if let reference = groups[groupIndex].members.first,
               changedPaths.contains(reference.id) {
                groups[groupIndex].members = []
            } else {
                groups[groupIndex].members.removeAll { changedPaths.contains($0.id) }
            }
        }
        groups = groups.filter { $0.members.count > 1 }.sorted {
            if $0.totalBytes != $1.totalBytes { return $0.totalBytes > $1.totalBytes }
            return $0.id < $1.id
        }
        try Task.checkCancellation()
        phase = .done
        report(rootURL.path, force: true)
        return VideoScanResult(
            rootURL: rootURL, configuration: configuration, groups: groups,
            scannedFileCount: scannedFileCount, candidateVideoCount: candidates.count,
            analyzedVideoCount: analyzedVideoCount, elapsedSeconds: Date().timeIntervalSince(started),
            diagnostics: diagnostics
        )
    }

    func discover() throws {
        var rootStat = stat()
        guard lstat(rootURL.path, &rootStat) == 0 else {
            throw DiskScanError.cannotReadMetadata(rootURL.path)
        }
        guard rootStat.st_mode & S_IFMT == S_IFDIR else {
            throw DiskScanError.rootIsNotDirectory(rootURL.path)
        }
        guard let pointer = strdup(rootURL.path) else { throw VideoReadError.undecodable }
        defer { free(pointer) }
        var paths: [UnsafeMutablePointer<CChar>?] = [pointer, nil]
        guard let tree = paths.withUnsafeMutableBufferPointer({
            fts_open($0.baseAddress, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil)
        }) else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { fts_close(tree) }
        var directories: Set<VideoFileIdentity> = []
        var files: Set<VideoFileIdentity> = []
        while true {
            try Task.checkCancellation()
            errno = 0
            guard let pointer = fts_read(tree) else {
                if errno != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                break
            }
            let entry = pointer.pointee
            let path = String(cString: entry.fts_path)
            defer { report(path) }
            switch Int32(entry.fts_info) {
            case FTS_D:
                guard let info = entry.fts_statp?.pointee else {
                    diagnostics.metadataErrorCount += 1
                    fts_set(tree, pointer, FTS_SKIP)
                    continue
                }
                if rootURL.path == "/" && path == "/System/Volumes/Data" {
                    fts_set(tree, pointer, FTS_SKIP)
                } else if info.st_dev != rootStat.st_dev {
                    diagnostics.skippedVolumeCount += 1
                    fts_set(tree, pointer, FTS_SKIP)
                } else if !directories.insert(VideoFileIdentity(info)).inserted {
                    fts_set(tree, pointer, FTS_SKIP)
                }
            case FTS_F:
                scannedFileCount += 1
                let url = URL(fileURLWithPath: path)
                guard Self.isVideo(url) else { continue }
                guard let info = entry.fts_statp?.pointee else {
                    diagnostics.metadataErrorCount += 1
                    continue
                }
                guard files.insert(VideoFileIdentity(info)).inserted else {
                    diagnostics.linkedFileCount += 1
                    continue
                }
                candidates.append(VideoCandidate(url: url, stamp: VideoFileStamp(info)))
            case FTS_DNR: diagnostics.unreadableDirectoryCount += 1
            case FTS_ERR, FTS_NS, FTS_DC: diagnostics.metadataErrorCount += 1
            default: break // Never follow symbolic links or open special files.
            }
        }
        candidates.sort { $0.url.path < $1.url.path }
        report(rootURL.path, force: true)
    }

    static func isVideo(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if let type = UTType(filenameExtension: ext),
           type.conforms(to: .movie) || type.conforms(to: .video) { return true }
        // Exact matching also works for containers the local decoder cannot open.
        return ["mkv", "webm", "avi", "mp4", "mov", "m4v", "mpg", "mpeg",
                "mts", "m2ts", "wmv", "flv", "3gp", "vob"].contains(ext)
    }

    func exactGroups() throws -> [DuplicateVideoGroup] {
        let buckets = Dictionary(grouping: candidates, by: { $0.stamp.size })
            .filter { $0.value.count > 1 }
        phase = .hashing
        totalCount = buckets.values.reduce(0) { $0 + $1.count }
        var groups: [DuplicateVideoGroup] = []
        for size in buckets.keys.sorted(by: >) {
            var hashed: [SHA256.Digest: [VideoCandidate]] = [:]
            for candidate in buckets[size] ?? [] {
                try Task.checkCancellation()
                report(candidate.url.path, force: true)
                do {
                    let digest = try hash(candidate)
                    hashed[digest, default: []].append(candidate)
                    analyzedVideoCount += 1
                } catch {
                    try Task.checkCancellation()
                    record(error, candidate)
                }
                completedCount += 1
            }
            for matching in hashed.values where matching.count > 1 {
                guard let reference = matching.first else { continue }
                var members = [DuplicateVideoMember(
                    item: reference.item, maximumFrameDistance: nil, isReference: true
                )]
                for candidate in matching.dropFirst() {
                    do {
                        if try equalContents(reference, candidate) {
                            members.append(DuplicateVideoMember(
                                item: candidate.item, maximumFrameDistance: nil, isReference: false
                            ))
                        }
                    } catch {
                        try Task.checkCancellation()
                        record(error, candidate)
                    }
                }
                if members.count > 1 { groups.append(DuplicateVideoGroup(members: members)) }
            }
        }
        return groups
    }

    func hash(_ candidate: VideoCandidate) throws -> SHA256.Digest {
        let handle = try candidate.openForReading()
        defer { try? handle.close() }
        var hash = SHA256()
        while true {
            try Task.checkCancellation()
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            hash.update(data: data)
            report(candidate.url.path)
        }
        try candidate.validate(handle)
        return hash.finalize()
    }

    func equalContents(_ lhs: VideoCandidate, _ rhs: VideoCandidate) throws -> Bool {
        let left = try lhs.openForReading()
        defer { try? left.close() }
        let right = try rhs.openForReading()
        defer { try? right.close() }
        while true {
            try Task.checkCancellation()
            let a = try left.read(upToCount: 1_048_576) ?? Data()
            let b = try right.read(upToCount: 1_048_576) ?? Data()
            guard a == b else { return false }
            report(rhs.url.path)
            if a.isEmpty { break }
        }
        try lhs.validate(left)
        try rhs.validate(right)
        return true
    }

    func similarGroups() async throws -> [DuplicateVideoGroup] {
        phase = .analyzing
        totalCount = candidates.count
        var fingerprints: [VideoFingerprint] = []
        for candidate in candidates {
            try Task.checkCancellation()
            report(candidate.url.path, force: true)
            do {
                fingerprints.append(try await readVideo(candidate, features: true))
                analyzedVideoCount += 1
            } catch {
                try Task.checkCancellation()
                record(error, candidate)
            }
            completedCount += 1
        }
        // Prefer a high-resolution reference, with deterministic ties.
        fingerprints.sort {
            let a = Double($0.item.pixelWidth ?? 0) * Double($0.item.pixelHeight ?? 0)
            let b = Double($1.item.pixelWidth ?? 0) * Double($1.item.pixelHeight ?? 0)
            if a != b { return a > b }
            if $0.item.logicalBytes != $1.item.logicalBytes {
                return $0.item.logicalBytes > $1.item.logicalBytes
            }
            return $0.item.id < $1.item.id
        }
        phase = .comparing
        totalCount = fingerprints.count
        completedCount = 0
        var grouped: Set<Int> = []
        var groups: [DuplicateVideoGroup] = []
        for index in fingerprints.indices {
            try Task.checkCancellation()
            completedCount = index + 1
            let reference = fingerprints[index]
            report(reference.item.id, force: true)
            guard !grouped.contains(index) else { continue }
            var members = [DuplicateVideoMember(
                item: reference.item, maximumFrameDistance: nil, isReference: true
            )]
            for other in fingerprints.indices where other > index && !grouped.contains(other) {
                try Task.checkCancellation()
                let candidate = fingerprints[other]
                guard VideoMatching.hasCompatibleGeometry(reference.item, candidate.item) else { continue }
                var distances: [Double] = []
                for (left, right) in zip(reference.frames, candidate.frames) {
                    try Task.checkCancellation()
                    var distance: Float = 0
                    try left.computeDistance(&distance, to: right)
                    guard distance.isFinite, distance >= 0 else { throw VideoReadError.invalidFeature }
                    distances.append(Double(distance))
                    if Double(distance) > configuration.maximumDistance + 0.000_001 { break }
                }
                if let maximum = VideoMatching.matchDistance(
                    distances, threshold: configuration.maximumDistance
                ) {
                    members.append(DuplicateVideoMember(
                        item: candidate.item, maximumFrameDistance: maximum, isReference: false
                    ))
                    grouped.insert(other)
                }
                report(candidate.item.id)
            }
            if members.count > 1 { groups.append(DuplicateVideoGroup(members: members)) }
        }
        return groups
    }

    func readVideo(_ candidate: VideoCandidate, features: Bool) async throws -> VideoFingerprint {
        try candidate.validate()
        let asset = AVURLAsset(url: candidate.url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 320)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try await withTaskCancellationHandler {
            let duration = try await asset.load(.duration).seconds
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard duration.isFinite, duration > 0, let track = tracks.first else {
                throw VideoReadError.undecodable
            }
            let size = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            let rect = CGRect(origin: .zero, size: size).applying(transform)
            guard rect.width.isFinite, rect.height.isFinite,
                  abs(rect.width) >= 1, abs(rect.height) >= 1,
                  abs(rect.width) < CGFloat(Int.max), abs(rect.height) < CGFloat(Int.max) else {
                throw VideoReadError.undecodable
            }
            let audio = try await asset.loadTracks(withMediaType: .audio)
            var item = candidate.item
            item.duration = duration
            item.pixelWidth = Int(abs(rect.width).rounded())
            item.pixelHeight = Int(abs(rect.height).rounded())
            item.audioTrackCount = audio.count
            var observations: [VNFeaturePrintObservation] = []
            let fractions = features ? VideoMatching.sampleFractions : [0.05, 0.5, 0.95]
            for fraction in fractions {
                try Task.checkCancellation()
                let frame = try await generator.image(at: CMTime(seconds: duration * fraction, preferredTimescale: 60_000))
                try Task.checkCancellation()
                try autoreleasepool {
                    if features {
                        let normalizedImage = try Self.normalizedFrame(frame.image)
                        let request = VNGenerateImageFeaturePrintRequest()
                        request.revision = VNGenerateImageFeaturePrintRequestRevision1
                        request.imageCropAndScaleOption = .scaleFit
                        try VNImageRequestHandler(cgImage: normalizedImage, options: [:]).perform([request])
                        guard let observation = request.results?.first else { throw VideoReadError.invalidFeature }
                        observations.append(observation)
                    } else {
                        let data = NSMutableData()
                        guard let destination = CGImageDestinationCreateWithData(
                            data, UTType.jpeg.identifier as CFString, 1, nil
                        ) else { throw VideoReadError.undecodable }
                        CGImageDestinationAddImage(destination, frame.image, [
                            kCGImageDestinationLossyCompressionQuality: 0.7
                        ] as CFDictionary)
                        guard CGImageDestinationFinalize(destination) else { throw VideoReadError.undecodable }
                        item.previews.append(VideoPreviewFrame(seconds: frame.actualTime.seconds, jpeg: data as Data))
                    }
                }
                report(candidate.url.path)
            }
            try candidate.validate()
            return VideoFingerprint(candidate: candidate, item: item, frames: observations)
        } onCancel: {
            asset.cancelLoading()
            generator.cancelAllCGImageGeneration()
        }
    }

    func record(_ error: Error, _ candidate: VideoCandidate) {
        if case VideoReadError.changed = error {
            if changedPaths.insert(candidate.url.path).inserted { diagnostics.changedFileCount += 1 }
        } else { diagnostics.readErrorCount += 1 }
    }

    private static func normalizedFrame(_ image: CGImage) throws -> CGImage {
        // Image generators only downscale. Normalize small and large originals
        // to the same letterboxed model input so resolution alone is not a cue.
        let side = 256
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: side, height: side, bitsPerComponent: 8,
                bytesPerRow: side * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { throw VideoReadError.undecodable }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let scale = Double(side) / Double(max(image.width, image.height))
        let width = Double(image.width) * scale
        let height = Double(image.height) * scale
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: (Double(side) - width) / 2, y: (Double(side) - height) / 2, width: width, height: height))
        guard let normalized = context.makeImage() else { throw VideoReadError.undecodable }
        return normalized
    }

    func report(_ path: String, force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastReport) >= 0.15 else { return }
        lastReport = now
        continuation.yield(VideoScanProgress(
            phase: phase, scannedFileCount: scannedFileCount, candidateVideoCount: candidates.count,
            completedCount: completedCount, totalCount: totalCount, currentPath: path
        ))
    }
}

enum VideoMatching {
    static let sampleFractions = (0..<8).map { 0.05 + Double($0) * 0.9 / 7 }

    static func hasCompatibleGeometry(_ lhs: DuplicateVideoItem, _ rhs: DuplicateVideoItem) -> Bool {
        guard let a = lhs.duration, let b = rhs.duration, a > 0, b > 0,
              abs(a - b) <= max(0.1, min(a, b) * 0.02),
              let aw = lhs.pixelWidth, let ah = lhs.pixelHeight, aw > 0, ah > 0,
              let bw = rhs.pixelWidth, let bh = rhs.pixelHeight, bw > 0, bh > 0 else { return false }
        let aspectA = Double(aw) / Double(ah)
        let aspectB = Double(bw) / Double(bh)
        return abs(aspectA - aspectB) / max(aspectA, aspectB) <= 0.03
    }

    static func matchDistance(_ distances: [Double], threshold: Double) -> Double? {
        guard distances.count == sampleFractions.count,
              threshold.isFinite, threshold >= 0,
              distances.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= threshold + 0.000_001 }) else { return nil }
        return distances.max()
    }
}
