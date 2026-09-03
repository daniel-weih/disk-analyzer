import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

enum SimilarImageComparisonMethod: String, CaseIterable, Identifiable, Sendable {
    case perceptualDuplicate
    case appleVision

    var id: String { rawValue }
}

enum ImageSimilarityThreshold {
    static let defaultPercent = 90
    static let minimumPercent = 70
    static let maximumPercent = 100

    static func clampedPercent(_ value: Int) -> Int {
        min(max(value, minimumPercent), maximumPercent)
    }
}

enum VisionFeatureDistanceThreshold {
    static let defaultValue = 12.5
    static let minimumValue = 0.0
    static let maximumValue = 50.0
    static let step = 0.5

    static func clamped(_ value: Double) -> Double {
        guard value.isFinite else { return defaultValue }
        return min(max(value, minimumValue), maximumValue)
    }
}

/// A presentation-only scale for Apple Vision Feature Print distances.
///
/// Vision exposes a distance, not a confidence score or percentage. The app
/// maps its supported 0...50 distance range linearly to 100...0 so people can
/// adjust and compare results without having to interpret an unfamiliar unit.
/// Matching still uses the original Vision distance without rounding.
enum VisionFeatureSimilarityScale {
    static let defaultPercent = 75
    static let minimumPercent = 0
    static let maximumPercent = 100

    static func clampedPercent(_ value: Int) -> Int {
        min(max(value, minimumPercent), maximumPercent)
    }

    static func distance(forSimilarityPercent value: Int) -> Double {
        let percent = Double(clampedPercent(value)) / 100
        return VisionFeatureDistanceThreshold.maximumValue * (1 - percent)
    }

    static func similarityPercent(forDistance value: Double) -> Int {
        let distance = VisionFeatureDistanceThreshold.clamped(value)
        let ratio = 1 - distance / VisionFeatureDistanceThreshold.maximumValue
        return clampedPercent(Int((ratio * 100).rounded()))
    }
}

struct SimilarImageScanConfiguration: Equatable, Sendable {
    let method: SimilarImageComparisonMethod
    let perceptualSimilarityPercent: Int
    let visionMaximumDistance: Double

    init(
        method: SimilarImageComparisonMethod = .perceptualDuplicate,
        perceptualSimilarityPercent: Int = ImageSimilarityThreshold.defaultPercent,
        visionMaximumDistance: Double = VisionFeatureDistanceThreshold.defaultValue
    ) {
        self.method = method
        self.perceptualSimilarityPercent = ImageSimilarityThreshold.clampedPercent(
            perceptualSimilarityPercent
        )
        self.visionMaximumDistance = VisionFeatureDistanceThreshold.clamped(
            visionMaximumDistance
        )
    }

    var visionSimilarityPercent: Int {
        VisionFeatureSimilarityScale.similarityPercent(
            forDistance: visionMaximumDistance
        )
    }

    func hasSameActiveThreshold(as other: SimilarImageScanConfiguration) -> Bool {
        guard method == other.method else { return false }
        switch method {
        case .perceptualDuplicate:
            return perceptualSimilarityPercent == other.perceptualSimilarityPercent
        case .appleVision:
            return visionMaximumDistance == other.visionMaximumDistance
        }
    }
}

struct SimilarImageItem: Identifiable, Equatable, Sendable {
    let url: URL
    let logicalBytes: Int64
    let pixelWidth: Int
    let pixelHeight: Int
    let thumbnailRGBA: Data

    var id: String { url.path }
}

struct SimilarImageMember: Identifiable, Equatable, Sendable {
    let item: SimilarImageItem
    let score: SimilarImageMatchScore
    let isReference: Bool

    var id: String { item.id }
}

enum SimilarImageMatchScore: Equatable, Sendable {
    case perceptualSimilarity(Double)
    case visionDistance(Double)
}

struct SimilarImageGroup: Identifiable, Equatable, Sendable {
    let members: [SimilarImageMember]

    var id: String { members.first?.id ?? "empty-similar-image-group" }
    var totalBytes: Int64 { members.reduce(0) { $0 + $1.item.logicalBytes } }
    var minimumPerceptualSimilarity: Double? {
        members.dropFirst().compactMap { member in
            guard case let .perceptualSimilarity(value) = member.score else {
                return nil
            }
            return value
        }.min()
    }
    var maximumVisionDistance: Double? {
        members.dropFirst().compactMap { member in
            guard case let .visionDistance(value) = member.score else {
                return nil
            }
            return value
        }.max()
    }
    var minimumVisionSimilarityPercent: Int? {
        maximumVisionDistance.map {
            VisionFeatureSimilarityScale.similarityPercent(forDistance: $0)
        }
    }
}

struct SimilarImageScanDiagnostics: Equatable, Sendable {
    var unreadableDirectoryCount = 0
    var metadataErrorCount = 0
    var skippedVolumeCount = 0
    var duplicateDirectoryCount = 0
    var imageDecodeErrorCount = 0

    var hasCoverageWarning: Bool {
        unreadableDirectoryCount > 0
            || metadataErrorCount > 0
            || imageDecodeErrorCount > 0
    }
}

struct SimilarImageScanResult: Equatable, Sendable {
    let rootURL: URL
    let configuration: SimilarImageScanConfiguration
    let groups: [SimilarImageGroup]
    let scannedFileCount: Int
    let candidateImageCount: Int
    let analyzedImageCount: Int
    let elapsedSeconds: Double
    let diagnostics: SimilarImageScanDiagnostics

    var groupedImageCount: Int {
        groups.reduce(0) { $0 + $1.members.count }
    }

    var similarityPercent: Int {
        configuration.perceptualSimilarityPercent
    }
}

struct SimilarImageScanProgress: Sendable {
    enum Phase: Equatable, Sendable {
        case scanningFiles
        case comparing
        case done
    }

    let scannedFileCount: Int
    let candidateImageCount: Int
    let analyzedImageCount: Int
    let comparedImageCount: Int
    let groupCount: Int
    let currentPath: String
    let phase: Phase
}

actor SimilarImageScanner {
    private var scanTask: Task<SimilarImageScanResult, Error>?

    func scan(
        from rootURL: URL,
        similarityPercent: Int,
        stayOnVolume: Bool = true
    ) -> (
        stream: AsyncStream<SimilarImageScanProgress>,
        task: Task<SimilarImageScanResult, Error>
    ) {
        scan(
            from: rootURL,
            configuration: SimilarImageScanConfiguration(
                method: .perceptualDuplicate,
                perceptualSimilarityPercent: similarityPercent
            ),
            stayOnVolume: stayOnVolume
        )
    }

    func scan(
        from rootURL: URL,
        configuration: SimilarImageScanConfiguration,
        stayOnVolume: Bool = true
    ) -> (
        stream: AsyncStream<SimilarImageScanProgress>,
        task: Task<SimilarImageScanResult, Error>
    ) {
        scanTask?.cancel()

        let (stream, continuation) = AsyncStream<SimilarImageScanProgress>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let task = Task.detached(priority: .userInitiated) {
            do {
                let result = try Self.performScan(
                    from: rootURL.standardizedFileURL,
                    configuration: configuration,
                    stayOnVolume: stayOnVolume,
                    continuation: continuation
                )
                continuation.yield(SimilarImageScanProgress(
                    scannedFileCount: result.scannedFileCount,
                    candidateImageCount: result.candidateImageCount,
                    analyzedImageCount: result.analyzedImageCount,
                    comparedImageCount: result.analyzedImageCount,
                    groupCount: result.groups.count,
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
        configuration: SimilarImageScanConfiguration,
        stayOnVolume: Bool,
        continuation: AsyncStream<SimilarImageScanProgress>.Continuation
    ) throws -> SimilarImageScanResult {
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
        let context = SimilarImageScanContext(
            rootDevice: stableDeviceID(rootStat),
            comparisonMethod: configuration.method,
            continuation: continuation
        )
        context.seenDirectories.insert(SimilarImageIdentity(rootStat))

        try scanUsingFTS(
            rootURL: rootURL,
            stayOnVolume: stayOnVolume,
            context: context
        )
        try Task.checkCancellation()

        let groups: [SimilarImageGroup]
        switch configuration.method {
        case .perceptualDuplicate:
            let fingerprints: [ImagePerceptualFingerprint] = context.features
                .compactMap { feature in
                    guard case let .perceptual(value) = feature else { return nil }
                    return value
                }
            groups = try groupPerceptualImages(
                fingerprints,
                similarityPercent: configuration.perceptualSimilarityPercent,
                scannedFileCount: context.scannedFileCount,
                candidateImageCount: context.candidateImageCount,
                continuation: continuation
            )
        case .appleVision:
            let fingerprints: [ImageVisionFingerprint] = context.features
                .compactMap { feature in
                    guard case let .vision(value) = feature else { return nil }
                    return value
                }
            groups = try groupVisionImages(
                fingerprints,
                maximumDistance: configuration.visionMaximumDistance,
                scannedFileCount: context.scannedFileCount,
                candidateImageCount: context.candidateImageCount,
                continuation: continuation
            )
        }

        return SimilarImageScanResult(
            rootURL: rootURL,
            configuration: configuration,
            groups: groups,
            scannedFileCount: context.scannedFileCount,
            candidateImageCount: context.candidateImageCount,
            analyzedImageCount: context.features.count,
            elapsedSeconds: Date.timeIntervalSinceReferenceDate - startedAt,
            diagnostics: SimilarImageScanDiagnostics(
                unreadableDirectoryCount: context.unreadableDirectoryCount,
                metadataErrorCount: context.metadataErrorCount,
                skippedVolumeCount: context.skippedVolumeCount,
                duplicateDirectoryCount: context.duplicateDirectoryCount,
                imageDecodeErrorCount: context.imageDecodeErrorCount
            )
        )
    }

    private nonisolated static func scanUsingFTS(
        rootURL: URL,
        stayOnVolume: Bool,
        context: SimilarImageScanContext
    ) throws {
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
                    let identity = SimilarImageIdentity(info)
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

                context.scannedFileCount += 1
                let url = URL(fileURLWithPath: path)
                guard isImageFile(url) else {
                    context.report(path: path)
                    continue
                }

                context.candidateImageCount += 1
                let logicalBytes = max(Int64(statPointer.pointee.st_size), 0)
                let feature = autoreleasepool {
                    makeComparisonFeature(
                        url: url,
                        logicalBytes: logicalBytes,
                        method: context.comparisonMethod
                    )
                }
                if let feature {
                    context.features.append(feature)
                } else {
                    context.imageDecodeErrorCount += 1
                }
                context.report(path: path)

            case FTS_ERR, FTS_NS:
                context.metadataErrorCount += 1
                context.report(path: path)

            default:
                // Symbolic links and non-regular entries are deliberately ignored.
                context.report(path: path)
            }
        }

        context.report(path: rootURL.path, force: true)
    }

    private nonisolated static func groupPerceptualImages(
        _ fingerprints: [ImagePerceptualFingerprint],
        similarityPercent: Int,
        scannedFileCount: Int,
        candidateImageCount: Int,
        continuation: AsyncStream<SimilarImageScanProgress>.Continuation
    ) throws -> [SimilarImageGroup] {
        guard fingerprints.count > 1 else { return [] }

        let threshold = Double(similarityPercent) / 100
        let maximumCombinedHashDistance = min(
            64,
            max(0, Int(floor((1 - threshold) * 128 + 0.000_001)))
        )
        let tree = HammingBKTree()
        for index in fingerprints.indices {
            tree.insert(hash: fingerprints[index].differenceHash, index: index)
        }

        let orderedIndices = fingerprints.indices.sorted { lhs, rhs in
            let left = fingerprints[lhs]
            let right = fingerprints[rhs]
            let leftPixels = safePixelCount(left.item)
            let rightPixels = safePixelCount(right.item)
            if leftPixels != rightPixels { return leftPixels > rightPixels }
            if left.item.logicalBytes != right.item.logicalBytes {
                return left.item.logicalBytes > right.item.logicalBytes
            }
            return left.item.url.path.localizedStandardCompare(
                right.item.url.path
            ) == .orderedAscending
        }

        var processed = Array(repeating: false, count: fingerprints.count)
        var groups: [SimilarImageGroup] = []
        var lastReportedAt = Date.timeIntervalSinceReferenceDate

        for (position, referenceIndex) in orderedIndices.enumerated() {
            try Task.checkCancellation()
            guard !processed[referenceIndex] else { continue }
            processed[referenceIndex] = true

            let reference = fingerprints[referenceIndex]
            var matched: [(index: Int, similarity: Double)] = []
            let candidates = tree.matches(
                hash: reference.differenceHash,
                maximumDistance: maximumCombinedHashDistance
            )
            for candidateIndex in candidates where candidateIndex != referenceIndex {
                guard !processed[candidateIndex] else { continue }
                let similarity = reference.similarity(to: fingerprints[candidateIndex])
                if similarity + 0.000_000_1 >= threshold {
                    matched.append((candidateIndex, similarity))
                }
            }

            if !matched.isEmpty {
                matched.sort { lhs, rhs in
                    if lhs.similarity != rhs.similarity {
                        return lhs.similarity > rhs.similarity
                    }
                    return fingerprints[lhs.index].item.url.path.localizedStandardCompare(
                        fingerprints[rhs.index].item.url.path
                    ) == .orderedAscending
                }
                for match in matched {
                    processed[match.index] = true
                }

                var members = [SimilarImageMember(
                    item: reference.item,
                    score: .perceptualSimilarity(1),
                    isReference: true
                )]
                members.append(contentsOf: matched.map { match in
                    SimilarImageMember(
                        item: fingerprints[match.index].item,
                        score: .perceptualSimilarity(match.similarity),
                        isReference: false
                    )
                })
                groups.append(SimilarImageGroup(members: members))
            }

            let now = Date.timeIntervalSinceReferenceDate
            if position.isMultiple(of: 50) || now - lastReportedAt >= 0.5 {
                lastReportedAt = now
                continuation.yield(SimilarImageScanProgress(
                    scannedFileCount: scannedFileCount,
                    candidateImageCount: candidateImageCount,
                    analyzedImageCount: fingerprints.count,
                    comparedImageCount: position + 1,
                    groupCount: groups.count,
                    currentPath: reference.item.url.path,
                    phase: .comparing
                ))
            }
        }

        groups.sort { lhs, rhs in
            if lhs.totalBytes != rhs.totalBytes { return lhs.totalBytes > rhs.totalBytes }
            return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
        }
        return groups
    }

    private nonisolated static func groupVisionImages(
        _ fingerprints: [ImageVisionFingerprint],
        maximumDistance: Double,
        scannedFileCount: Int,
        candidateImageCount: Int,
        continuation: AsyncStream<SimilarImageScanProgress>.Continuation
    ) throws -> [SimilarImageGroup] {
        guard fingerprints.count > 1 else { return [] }

        let orderedIndices = fingerprints.indices.sorted { lhs, rhs in
            let left = fingerprints[lhs]
            let right = fingerprints[rhs]
            let leftPixels = safePixelCount(left.item)
            let rightPixels = safePixelCount(right.item)
            if leftPixels != rightPixels { return leftPixels > rightPixels }
            if left.item.logicalBytes != right.item.logicalBytes {
                return left.item.logicalBytes > right.item.logicalBytes
            }
            return left.item.url.path.localizedStandardCompare(
                right.item.url.path
            ) == .orderedAscending
        }

        // Vision does not publish a universal cutoff or an indexing contract
        // for Feature Prints. Compare every ungrouped image with each chosen
        // reference so an approximate prefilter can never hide a valid match.
        // This optional mode intentionally favors completeness over speed.
        var processed = Array(repeating: false, count: fingerprints.count)
        var groups: [SimilarImageGroup] = []
        var lastReportedAt = Date.timeIntervalSinceReferenceDate

        for (position, referenceIndex) in orderedIndices.enumerated() {
            try Task.checkCancellation()
            guard !processed[referenceIndex] else { continue }
            processed[referenceIndex] = true

            let reference = fingerprints[referenceIndex]
            var matched: [(index: Int, distance: Double)] = []
            for candidateIndex in orderedIndices where candidateIndex != referenceIndex {
                try Task.checkCancellation()
                guard !processed[candidateIndex] else { continue }

                let distance = try visionDistance(
                    from: reference.observation,
                    to: fingerprints[candidateIndex].observation
                )
                if distance <= maximumDistance + 0.000_001 {
                    matched.append((candidateIndex, distance))
                }

                let now = Date.timeIntervalSinceReferenceDate
                if now - lastReportedAt >= 0.5 {
                    lastReportedAt = now
                    continuation.yield(SimilarImageScanProgress(
                        scannedFileCount: scannedFileCount,
                        candidateImageCount: candidateImageCount,
                        analyzedImageCount: fingerprints.count,
                        comparedImageCount: position + 1,
                        groupCount: groups.count,
                        currentPath: fingerprints[candidateIndex].item.url.path,
                        phase: .comparing
                    ))
                }
            }

            if !matched.isEmpty {
                matched.sort { lhs, rhs in
                    if lhs.distance != rhs.distance {
                        return lhs.distance < rhs.distance
                    }
                    return fingerprints[lhs.index].item.url.path.localizedStandardCompare(
                        fingerprints[rhs.index].item.url.path
                    ) == .orderedAscending
                }
                for match in matched {
                    processed[match.index] = true
                }

                var members = [SimilarImageMember(
                    item: reference.item,
                    score: .visionDistance(0),
                    isReference: true
                )]
                members.append(contentsOf: matched.map { match in
                    SimilarImageMember(
                        item: fingerprints[match.index].item,
                        score: .visionDistance(match.distance),
                        isReference: false
                    )
                })
                groups.append(SimilarImageGroup(members: members))
            }

            let now = Date.timeIntervalSinceReferenceDate
            if position.isMultiple(of: 10) || now - lastReportedAt >= 0.5 {
                lastReportedAt = now
                continuation.yield(SimilarImageScanProgress(
                    scannedFileCount: scannedFileCount,
                    candidateImageCount: candidateImageCount,
                    analyzedImageCount: fingerprints.count,
                    comparedImageCount: position + 1,
                    groupCount: groups.count,
                    currentPath: reference.item.url.path,
                    phase: .comparing
                ))
            }
        }

        groups.sort { lhs, rhs in
            if lhs.totalBytes != rhs.totalBytes { return lhs.totalBytes > rhs.totalBytes }
            return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
        }
        return groups
    }

    private nonisolated static func visionDistance(
        from reference: VNFeaturePrintObservation,
        to candidate: VNFeaturePrintObservation
    ) throws -> Double {
        var rawDistance: Float = 0
        try reference.computeDistance(&rawDistance, to: candidate)
        guard rawDistance.isFinite, rawDistance >= 0 else {
            throw SimilarImageVisionError.invalidDistance
        }
        return Double(rawDistance)
    }

    private nonisolated static func safePixelCount(_ item: SimilarImageItem) -> Int64 {
        let width = Int64(item.pixelWidth)
        let height = Int64(item.pixelHeight)
        let (count, overflow) = width.multipliedReportingOverflow(by: height)
        return overflow ? .max : count
    }

    private nonisolated static func isImageFile(_ url: URL) -> Bool {
        let fileExtension = url.pathExtension
        guard !fileExtension.isEmpty,
              let type = UTType(filenameExtension: fileExtension) else {
            return false
        }
        return type.conforms(to: .image)
    }

    private nonisolated static func makeComparisonFeature(
        url: URL,
        logicalBytes: Int64,
        method: SimilarImageComparisonMethod
    ) -> ImageComparisonFeature? {
        switch method {
        case .perceptualDuplicate:
            return makePerceptualFingerprint(url: url, logicalBytes: logicalBytes)
                .map(ImageComparisonFeature.perceptual)
        case .appleVision:
            return makeVisionFingerprint(url: url, logicalBytes: logicalBytes)
                .map(ImageComparisonFeature.vision)
        }
    }

    private nonisolated static func makePerceptualFingerprint(
        url: URL,
        logicalBytes: Int64
    ) -> ImagePerceptualFingerprint? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions),
              CGImageSourceGetCount(source) > 0 else {
            return nil
        }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as? [CFString: Any]
        guard var pixelWidth = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              var pixelHeight = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              pixelWidth > 0,
              pixelHeight > 0 else {
            return nil
        }
        let orientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        if (5...8).contains(orientation) {
            swap(&pixelWidth, &pixelHeight)
        }

        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 128,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            thumbnailOptions
        ), let rgba = normalizedRGBA(from: thumbnail, size: 32) else {
            return nil
        }
        let normalizedRGBA = Data(rgba)

        return ImagePerceptualFingerprint(
            item: SimilarImageItem(
                url: url,
                logicalBytes: logicalBytes,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                thumbnailRGBA: normalizedRGBA
            ),
            differenceHash: differenceHash(rgba: rgba, size: 32),
            averageHash: averageHash(rgba: rgba, size: 32),
            normalizedRGBA: normalizedRGBA
        )
    }

    private nonisolated static func makeVisionFingerprint(
        url: URL,
        logicalBytes: Int64
    ) -> ImageVisionFingerprint? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions),
              CGImageSourceGetCount(source) > 0 else {
            return nil
        }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as? [CFString: Any]
        guard var pixelWidth = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              var pixelHeight = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              pixelWidth > 0,
              pixelHeight > 0 else {
            return nil
        }
        let orientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        if (5...8).contains(orientation) {
            swap(&pixelWidth, &pixelHeight)
        }

        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1_024,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            thumbnailOptions
        ), let rgba = normalizedRGBA(from: thumbnail, size: 32) else {
            return nil
        }

        let request = VNGenerateImageFeaturePrintRequest()
        // Pin Revision 1 so distances retain one meaning on all supported
        // systems; Revision 2 is only available beginning with macOS 14.
        request.revision = VNGenerateImageFeaturePrintRequestRevision1
        request.imageCropAndScaleOption = .scaleFit
        do {
            try VNImageRequestHandler(cgImage: thumbnail, options: [:])
                .perform([request])
        } catch {
            return nil
        }
        guard let observation = request.results?.first else { return nil }

        return ImageVisionFingerprint(
            item: SimilarImageItem(
                url: url,
                logicalBytes: logicalBytes,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                thumbnailRGBA: Data(rgba)
            ),
            observation: observation
        )
    }

    private nonisolated static func normalizedRGBA(
        from image: CGImage,
        size: Int
    ) -> [UInt8]? {
        var pixels = [UInt8](repeating: 255, count: size * size * 4)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
            ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue

        let created = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let baseAddress = bytes.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: size,
                    height: size,
                    bitsPerComponent: 8,
                    bytesPerRow: size * 4,
                    space: colorSpace,
                    bitmapInfo: bitmapInfo
                  ) else {
                return false
            }

            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: size, height: size))
            context.interpolationQuality = .high

            let scale = min(
                CGFloat(size) / CGFloat(image.width),
                CGFloat(size) / CGFloat(image.height)
            )
            let width = CGFloat(image.width) * scale
            let height = CGFloat(image.height) * scale
            let rect = CGRect(
                x: (CGFloat(size) - width) / 2,
                y: (CGFloat(size) - height) / 2,
                width: width,
                height: height
            )
            context.draw(image, in: rect)
            return true
        }
        return created ? pixels : nil
    }

    private nonisolated static func differenceHash(
        rgba: [UInt8],
        size: Int
    ) -> UInt64 {
        let samples = grayscaleGrid(rgba: rgba, size: size, columns: 9, rows: 8)
        var hash: UInt64 = 0
        var bit = 0
        for row in 0..<8 {
            for column in 0..<8 {
                if samples[row * 9 + column] > samples[row * 9 + column + 1] {
                    hash |= UInt64(1) << UInt64(bit)
                }
                bit += 1
            }
        }
        return hash
    }

    private nonisolated static func averageHash(
        rgba: [UInt8],
        size: Int
    ) -> UInt64 {
        let samples = grayscaleGrid(rgba: rgba, size: size, columns: 8, rows: 8)
        let average = samples.reduce(0, +) / max(samples.count, 1)
        var hash: UInt64 = 0
        for (bit, sample) in samples.enumerated() where sample >= average {
            hash |= UInt64(1) << UInt64(bit)
        }
        return hash
    }

    private nonisolated static func grayscaleGrid(
        rgba: [UInt8],
        size: Int,
        columns: Int,
        rows: Int
    ) -> [Int] {
        var output: [Int] = []
        output.reserveCapacity(columns * rows)
        for row in 0..<rows {
            let startY = row * size / rows
            let endY = max((row + 1) * size / rows, startY + 1)
            for column in 0..<columns {
                let startX = column * size / columns
                let endX = max((column + 1) * size / columns, startX + 1)
                var sum = 0
                var count = 0
                for y in startY..<min(endY, size) {
                    for x in startX..<min(endX, size) {
                        let offset = (y * size + x) * 4
                        let red = Int(rgba[offset])
                        let green = Int(rgba[offset + 1])
                        let blue = Int(rgba[offset + 2])
                        sum += (red * 299 + green * 587 + blue * 114) / 1_000
                        count += 1
                    }
                }
                output.append(sum / max(count, 1))
            }
        }
        return output
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
}

private struct SimilarImageIdentity: Hashable {
    let device: UInt64
    let inode: UInt64

    init(_ info: stat) {
        device = UInt64(UInt32(bitPattern: info.st_dev))
        inode = UInt64(info.st_ino)
    }
}

private struct ImagePerceptualFingerprint {
    let item: SimilarImageItem
    let differenceHash: UInt64
    let averageHash: UInt64
    // Data is copy-on-write, so the result thumbnail and comparison pixels share
    // one 4 KB backing buffer instead of duplicating it for every scanned image.
    let normalizedRGBA: Data

    func similarity(to other: ImagePerceptualFingerprint) -> Double {
        let differenceDistance = (differenceHash ^ other.differenceHash).nonzeroBitCount
        let averageDistance = (averageHash ^ other.averageHash).nonzeroBitCount
        let structural = 1 - Double(differenceDistance + averageDistance) / 128

        var absoluteDifference: UInt64 = 0
        let comparableCount = min(normalizedRGBA.count, other.normalizedRGBA.count)
        var componentCount = 0
        var index = 0
        while index + 2 < comparableCount {
            absoluteDifference += UInt64(abs(
                Int(normalizedRGBA[index]) - Int(other.normalizedRGBA[index])
            ))
            absoluteDifference += UInt64(abs(
                Int(normalizedRGBA[index + 1]) - Int(other.normalizedRGBA[index + 1])
            ))
            absoluteDifference += UInt64(abs(
                Int(normalizedRGBA[index + 2]) - Int(other.normalizedRGBA[index + 2])
            ))
            componentCount += 3
            index += 4
        }
        let maximumDifference = Double(max(componentCount, 1) * 255)
        let visual = 1 - Double(absoluteDifference) / maximumDifference

        let ownAspect = Double(item.pixelWidth) / Double(max(item.pixelHeight, 1))
        let otherAspect = Double(other.item.pixelWidth) / Double(max(other.item.pixelHeight, 1))
        let aspect = min(ownAspect, otherAspect) / max(ownAspect, otherAspect)

        return max(0, min(structural, min(visual, aspect)))
    }
}

private enum ImageComparisonFeature {
    case perceptual(ImagePerceptualFingerprint)
    case vision(ImageVisionFingerprint)
}

private struct ImageVisionFingerprint {
    let item: SimilarImageItem
    let observation: VNFeaturePrintObservation
}

private enum SimilarImageVisionError: LocalizedError {
    case invalidDistance

    var errorDescription: String? {
        L10n.text("similar_images.error.invalid_vision_distance")
    }
}

private final class SimilarImageScanContext {
    let rootDevice: UInt64
    let comparisonMethod: SimilarImageComparisonMethod
    let continuation: AsyncStream<SimilarImageScanProgress>.Continuation

    var features: [ImageComparisonFeature] = []
    var seenDirectories: Set<SimilarImageIdentity> = []
    var scannedFileCount = 0
    var candidateImageCount = 0
    var unreadableDirectoryCount = 0
    var metadataErrorCount = 0
    var skippedVolumeCount = 0
    var duplicateDirectoryCount = 0
    var imageDecodeErrorCount = 0

    private var lastReportedItemCount = 0
    private var lastReportedCandidateImageCount = 0
    private var lastReportedAt = Date.timeIntervalSinceReferenceDate

    init(
        rootDevice: UInt64,
        comparisonMethod: SimilarImageComparisonMethod,
        continuation: AsyncStream<SimilarImageScanProgress>.Continuation
    ) {
        self.rootDevice = rootDevice
        self.comparisonMethod = comparisonMethod
        self.continuation = continuation
    }

    func report(path: String, force: Bool = false) {
        let now = Date.timeIntervalSinceReferenceDate
        let itemDelta = scannedFileCount - lastReportedItemCount
        let elapsed = now - lastReportedAt
        let batchIsReady = itemDelta >= 500 && elapsed >= 0.15
        let imageBatchIsReady = candidateImageCount > lastReportedCandidateImageCount
            && candidateImageCount.isMultiple(of: 50)
            && elapsed >= 0.15
        let heartbeatIsDue = elapsed >= 1
        guard force || batchIsReady || imageBatchIsReady || heartbeatIsDue else { return }

        lastReportedItemCount = scannedFileCount
        lastReportedCandidateImageCount = candidateImageCount
        lastReportedAt = now
        continuation.yield(SimilarImageScanProgress(
            scannedFileCount: scannedFileCount,
            candidateImageCount: candidateImageCount,
            analyzedImageCount: features.count,
            comparedImageCount: 0,
            groupCount: 0,
            currentPath: path,
            phase: .scanningFiles
        ))
    }
}

private final class HammingBKTree {
    private final class Node {
        let hash: UInt64
        var indices: [Int]
        var children: [Int: Node] = [:]

        init(hash: UInt64, index: Int) {
            self.hash = hash
            self.indices = [index]
        }
    }

    private var root: Node?

    func insert(hash: UInt64, index: Int) {
        guard let root else {
            self.root = Node(hash: hash, index: index)
            return
        }

        var node = root
        while true {
            let distance = (hash ^ node.hash).nonzeroBitCount
            if distance == 0 {
                node.indices.append(index)
                return
            }
            if let child = node.children[distance] {
                node = child
            } else {
                node.children[distance] = Node(hash: hash, index: index)
                return
            }
        }
    }

    func matches(hash: UInt64, maximumDistance: Int) -> [Int] {
        guard let root else { return [] }
        var matches: [Int] = []
        var stack = [root]
        while let node = stack.popLast() {
            let distance = (hash ^ node.hash).nonzeroBitCount
            if distance <= maximumDistance {
                matches.append(contentsOf: node.indices)
            }
            let lowerBound = max(0, distance - maximumDistance)
            let upperBound = min(64, distance + maximumDistance)
            for (edge, child) in node.children
                where edge >= lowerBound && edge <= upperBound {
                stack.append(child)
            }
        }
        return matches
    }
}
