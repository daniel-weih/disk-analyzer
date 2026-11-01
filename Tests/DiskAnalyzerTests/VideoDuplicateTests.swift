import AppKit
import AVFoundation
import Darwin
import Foundation
import SwiftUI
import Testing
@testable import DiskAnalyzer

@Suite("Duplicate video scanning", .serialized)
struct VideoDuplicateTests {
    @Test("Exact matching checks complete bytes and skips symlinks and hard-link aliases")
    func exactVideos() async throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original.mp4")
        try await writeVideo(original)
        let copied = root.appendingPathComponent("renamed.MP4")
        try FileManager.default.copyItem(at: original, to: copied)
        var changed = try Data(contentsOf: original)
        changed[changed.count / 2] ^= 0xFF
        try changed.write(to: root.appendingPathComponent("changed-middle.mp4"))
        try FileManager.default.copyItem(at: original, to: root.appendingPathComponent("not-video.txt"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.mp4"), withDestinationURL: original)
        try FileManager.default.linkItem(at: original, to: root.appendingPathComponent("hard-link.mp4"))

        let operation = await VideoDuplicateScanner().scan(from: root)
        let result = try await operation.task.value
        #expect(result.groups.count == 1)
        let group = try #require(result.groups.first)
        #expect(group.members.count == 2)
        #expect(group.members.contains { $0.item.url == copied })
        #expect(!group.members.contains { $0.item.url.lastPathComponent == "changed-middle.mp4" })
        #expect(!group.members.contains { $0.item.url.lastPathComponent == "link.mp4" })
        #expect(result.candidateVideoCount == 3)
        #expect(result.diagnostics.linkedFileCount == 1)
        #expect(!result.diagnostics.hasCoverageWarning)
        #expect(result.diagnostics.previewErrorCount == 0)
        #expect(group.members.allSatisfy { $0.item.previews.count == 3 })
        #expect(group.members.allSatisfy { $0.item.pixelWidth == 160 && $0.item.audioTrackCount == 0 })
        #expect(group.members.allSatisfy { $0.maximumFrameDistance == nil })
        var progressCount = 0
        for await progress in operation.stream {
            progressCount += 1
            #expect(progress.phase == .done)
        }
        #expect(progressCount == 1)
    }

    @Test("Visual matching finds re-encoded and resized videos but rejects shared intros and reversed sequences")
    func similarVideos() async throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try await writeVideo(root.appendingPathComponent("original.mp4"))
        try await writeVideo(root.appendingPathComponent("resized.mp4"), width: 320, height: 192, bitRate: 350_000)
        try await writeVideo(root.appendingPathComponent("shared-intro.mp4"), scenes: [0, 1, 2, 20, 21, 22, 23, 24])
        try await writeVideo(root.appendingPathComponent("reversed.mp4"), scenes: Array((0..<8).reversed()))
        try await writeVideo(root.appendingPathComponent("longer.mp4"), framesPerScene: 8)
        try Data("damaged video".utf8).write(to: root.appendingPathComponent("broken.mp4"))

        let operation = await VideoDuplicateScanner().scan(
            from: root, configuration: VideoScanConfiguration(method: .similar)
        )
        let result = try await operation.task.value
        #expect(result.groups.count == 1)
        let group = try #require(result.groups.first)
        #expect(Set(group.members.map { $0.item.url.lastPathComponent }) == ["original.mp4", "resized.mp4"])
        #expect(group.members.first?.item.url.lastPathComponent == "resized.mp4")
        #expect(group.members.allSatisfy { $0.item.previews.count == 3 })
        #expect(result.analyzedVideoCount == 5)
        #expect(result.diagnostics.readErrorCount == 1)
        #expect(result.diagnostics.hasCoverageWarning)
        #expect(result.diagnostics.previewErrorCount == 0)
    }

    @Test("Unsupported playback keeps exact matches and reports unavailable previews")
    func unsupportedPlayback() async throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = Data("same bytes in an unsupported container".utf8)
        try data.write(to: root.appendingPathComponent("first.mkv"))
        try data.write(to: root.appendingPathComponent("second.mkv"))
        let operation = await VideoDuplicateScanner().scan(from: root)
        let result = try await operation.task.value
        #expect(result.groups.count == 1)
        #expect(result.groupedVideoCount == 2)
        #expect(result.diagnostics.previewErrorCount == 2)
        #expect(result.groups.first?.members.allSatisfy { $0.item.previews.isEmpty } == true)
    }

    @Test("Cancelling a full-file scan stops without publishing a partial result")
    func cancelHashing() async throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try sparseVideo(root.appendingPathComponent("first.mp4"))
        try sparseVideo(root.appendingPathComponent("second.mp4"))
        let operation = await VideoDuplicateScanner().scan(from: root)
        for await progress in operation.stream where progress.phase == .hashing {
            operation.task.cancel()
            break
        }
        do {
            _ = try await operation.task.value
            Issue.record("Cancellation must not return a partial result")
        } catch is CancellationError { }
    }

    @Test("Files replaced during hashing are excluded and reported")
    func changedFile() async throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try sparseVideo(root.appendingPathComponent("first.mp4"))
        try sparseVideo(root.appendingPathComponent("second.mp4"))
        let operation = await VideoDuplicateScanner().scan(from: root)
        for await progress in operation.stream where progress.phase == .hashing {
            try Data("replaced".utf8).write(to: URL(fileURLWithPath: progress.currentPath), options: .atomic)
            break
        }
        let result = try await operation.task.value
        #expect(result.groups.isEmpty)
        #expect(result.diagnostics.changedFileCount == 1)
    }

    @Test("One similar frame or a good average cannot hide mismatched video frames")
    func conservativeMatching() {
        #expect(VideoMatching.matchDistance([1, 1, 1, 1, 1, 1, 1, 6], threshold: 5) == nil)
        #expect(VideoMatching.matchDistance([1], threshold: 5) == nil)
        #expect(VideoMatching.matchDistance([1, 1, 1, 1, 1, 1, 1, .nan], threshold: 5) == nil)
        var first = DuplicateVideoItem(url: URL(fileURLWithPath: "/a.mp4"), logicalBytes: 1)
        first.duration = 100
        first.pixelWidth = 1920
        first.pixelHeight = 1080
        var second = first
        second.duration = 100.2
        second.pixelWidth = 1280
        second.pixelHeight = 720
        #expect(VideoMatching.hasCompatibleGeometry(first, second))
        second.duration = 105
        #expect(!VideoMatching.hasCompatibleGeometry(first, second))
        second.duration = 100
        second.pixelHeight = 1280
        #expect(!VideoMatching.hasCompatibleGeometry(first, second))
    }

    @MainActor
    @Test("A cancelled controller can start a fresh scan without stale progress or results")
    func controllerCancellationAndRestart() async throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try sparseVideo(root.appendingPathComponent("first.mp4"))
        try sparseVideo(root.appendingPathComponent("second.mp4"))
        let empty = root.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let controller = VideoScanController(rootURL: root)
        controller.startScan()
        let deadline = Date().addingTimeInterval(10)
        while controller.progress?.phase != .hashing {
            guard Date() < deadline else { throw CocoaError(.coderInvalidValue) }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        controller.cancel()
        while controller.isScanning {
            guard Date() < deadline else { throw CocoaError(.coderInvalidValue) }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(controller.result == nil)
        #expect(controller.progress == nil)
        #expect(!controller.isCancelling)
        controller.rootURL = empty
        controller.startScan()
        while controller.isScanning {
            guard Date() < deadline else { throw CocoaError(.coderInvalidValue) }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(controller.result?.rootURL.path == empty.path)
        #expect(controller.result?.candidateVideoCount == 0)
        #expect(controller.errorMessage == nil)
    }

    @MainActor
    @Test("Video results render at minimum window size in the selected language")
    func videoInterface() async throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try await writeVideo(root.appendingPathComponent("Mountain Journey.mp4"))
        try await writeVideo(root.appendingPathComponent("Mountain Journey - compressed.mp4"), width: 320, height: 192)
        let operation = await VideoDuplicateScanner().scan(
            from: root, configuration: VideoScanConfiguration(method: .similar)
        )
        let scanned = try await operation.task.value
        #expect(scanned.groups.count == 1)
        // Only generated videos and fictional paths appear in captured previews.
        let groups = scanned.groups.map { group in
            DuplicateVideoGroup(members: group.members.map { member in
                var item = member.item
                item = DuplicateVideoItem(
                    url: URL(fileURLWithPath: "/Users/example/Movies/\(item.url.lastPathComponent)"),
                    logicalBytes: item.logicalBytes, duration: item.duration,
                    pixelWidth: item.pixelWidth, pixelHeight: item.pixelHeight,
                    audioTrackCount: item.audioTrackCount, previews: item.previews
                )
                return DuplicateVideoMember(item: item, maximumFrameDistance: member.maximumFrameDistance, isReference: member.isReference)
            })
        }
        let result = VideoScanResult(
            rootURL: URL(fileURLWithPath: "/Users/example/Movies"), configuration: scanned.configuration,
            groups: groups, scannedFileCount: 120, candidateVideoCount: 12, analyzedVideoCount: 12,
            elapsedSeconds: 4.2, diagnostics: VideoScanDiagnostics()
        )
        let controller = VideoScanController(result: result)
        do {
            let language = AppLanguage.current
            let view = VStack(spacing: 0) {
                AnalysisNavigationBar(selection: .constant(.tools), onShowHome: {}, onShowSettings: {})
                Divider()
                ToolsView(
                    largeFileController: LargeFileScanController(), similarImageController: SimilarImageScanController(),
                    videoController: controller, selection: .constant(.duplicateVideos)
                )
            }
            .frame(width: 1040, height: 680)
            .environment(\.locale, language.locale)
            .environment(\.colorScheme, .light)
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(x: 0, y: 0, width: 1040, height: 680)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            #expect(bitmap.pixelsWide >= 1040 && bitmap.pixelsHigh >= 680)
            if let directory = ProcessInfo.processInfo.environment["DISK_ANALYZER_CAPTURE_UI"] {
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("duplicate-videos-\(language.rawValue).png"))
            }
        }
        controller.method = .exact
        controller.invalidateResultIfConfigurationChanged()
        #expect(controller.result == nil)
    }

    private func fixtureDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("disk-analyzer-video-tests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func sparseVideo(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_CREAT | O_WRONLY, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { Darwin.close(descriptor) }
        guard ftruncate(descriptor, 512 * 1_024 * 1_024) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    private func writeVideo(
        _ url: URL, width: Int = 160, height: Int = 96,
        bitRate: Int = 900_000, scenes: [Int] = Array(0..<8), framesPerScene: Int = 4
    ) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitRate]
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        let deadline = Date().addingTimeInterval(30)
        for index in 0..<(scenes.count * framesPerScene) {
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed || Date() > deadline { throw writer.error ?? CocoaError(.fileWriteUnknown) }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            var buffer: CVPixelBuffer?
            let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32ARGB, nil, &buffer)
            guard status == kCVReturnSuccess, let buffer else { throw CocoaError(.fileWriteUnknown) }
            CVPixelBufferLockBaseAddress(buffer, [])
            guard let context = CGContext(
                data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
            ) else { throw CocoaError(.fileWriteUnknown) }
            context.setShouldAntialias(false)
            let scene = scenes[index / framesPerScene]
            var state = UInt64(scene + 1) * 997
            for row in 0..<6 {
                for column in 0..<8 {
                    state = state &* 6_364_136_223_846_793_005 &+ 1
                    context.setFillColor(CGColor(
                        red: CGFloat((state >> 16) & 255) / 255,
                        green: CGFloat((state >> 24) & 255) / 255,
                        blue: CGFloat((state >> 32) & 255) / 255, alpha: 1
                    ))
                    context.fill(CGRect(x: column * width / 8, y: row * height / 6, width: width / 8, height: height / 6))
                }
            }
            context.setFillColor(CGColor(gray: scene % 2 == 0 ? 0 : 1, alpha: 1))
            context.fillEllipse(in: CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 8)) else {
                throw writer.error ?? CocoaError(.fileWriteUnknown)
            }
        }
        writer.endSession(atSourceTime: CMTime(value: Int64(scenes.count * framesPerScene), timescale: 8))
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }
}
