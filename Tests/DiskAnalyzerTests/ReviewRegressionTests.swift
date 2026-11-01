import AppKit
import Foundation
import ImageIO
import DiskStatusCore
import SwapAnalysisCore
import Testing
import UniformTypeIdentifiers
@testable import DiskAnalyzer

@Suite("Review regressions", .serialized)
struct ReviewRegressionTests {
    private func fixture() throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("disk-review-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @MainActor
    @Test(arguments: ["file", "directory", "symlink"])
    func cleanupRejectsReplacement(replacementKind: String) async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("selected.bin")
        try Data("old selected file".utf8).write(to: source)
        let scan = await DiskScanner().scan(from: root)
        let result = try await scan.task.value
        let selected = try #require(result.root.children.first(where: { $0.name == source.lastPathComponent }))
        let destination = root.appendingPathComponent("trash-like-destination")
        let controller = ScanController { url in
            try FileManager.default.moveItem(at: url, to: destination)
            return .moved(destinationURL: destination)
        }
        controller.result = result
        controller.addToCleanup(selected)
        try FileManager.default.moveItem(at: source, to: root.appendingPathComponent("original-retained.bin"))
        let replacementContent: URL
        switch replacementKind {
        case "directory":
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            replacementContent = source.appendingPathComponent("new.txt")
        case "symlink":
            replacementContent = root.appendingPathComponent("unrelated.bin")
            try FileManager.default.createSymbolicLink(at: source, withDestinationURL: replacementContent)
        default:
            replacementContent = source
        }
        try Data("new unrelated content".utf8).write(to: replacementContent)
        await controller.moveCollectedItemsToTrash()
        #expect(selected.kind == .file)
        #expect(try String(contentsOf: replacementContent, encoding: .utf8) == "new unrelated content")
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(controller.alertMessage != nil)
        #expect(controller.cleanupItems.map(\.id) == [selected.id])
    }

    private func png(red: CGFloat, blue: CGFloat) throws -> Data {
        let context = try #require(CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8,
            bytesPerRow: 4096, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: red, green: 0, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let output = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(output, image, nil)
        #expect(CGImageDestinationFinalize(output))
        return data as Data
    }

    @Test(arguments: [SimilarImageComparisonMethod.perceptualDuplicate, .appleVision])
    func changedImageIsExcludedFromDuplicateResults(method: SimilarImageComparisonMethod) async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try png(red: 0, blue: 1)
        let replacement = try png(red: 1, blue: 0)
        let count = method == .appleVision ? 200 : 1500
        for index in 0..<count {
            try original.write(to: root.appendingPathComponent("image-\(index).png"))
        }
        let scanner = SimilarImageScanner()
        let operation = await scanner.scan(from: root, configuration: SimilarImageScanConfiguration(method: method))
        var changed: String?
        for await progress in operation.stream {
            if changed == nil, progress.phase == .scanningFiles,
               progress.analyzedImageCount > 0, progress.analyzedImageCount < count,
               progress.currentPath.hasSuffix(".png") {
                changed = progress.currentPath
                try replacement.write(to: URL(fileURLWithPath: progress.currentPath), options: .atomic)
            }
        }
        let changedPath = try #require(changed)
        let result = try await operation.task.value
        #expect(!result.groups.flatMap(\.members).contains { $0.item.url.path == changedPath })
        #expect(result.diagnostics.hasCoverageWarning)
        #expect(result.diagnostics.changedImageCount == 1)
    }

    @Test func smartDrainsBothPipes() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let json = try JSONSerialization.data(withJSONObject: [
            "smart_status": ["passed": true], "padding": String(repeating: "x", count: 1_048_576)
        ])
        let payload = root.appendingPathComponent("smart.json")
        try json.write(to: payload)
        let executable = root.appendingPathComponent("fake-smartctl")
        try Data("#!/bin/sh\n/bin/cat '\(payload.path)' >&2\nexec /bin/cat '\(payload.path)'\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        #expect(try SMARTHealthProbe.decode(json, capturedAt: Date(), deviceBSDName: "disk0",
            executablePath: executable.path, processExitStatus: 0).overallPassed == true)
        #expect(try SMARTHealthProbe.capture(deviceBSDName: "disk0", executableURL: executable, timeout: 5).overallPassed == true)
    }

    @Test func smartTimeoutAndCancellationRemainBounded() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("slow-smartctl")
        try Data("#!/bin/sh\nexec /bin/sleep 30\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let started = Date()
        #expect(throws: SMARTHealthProbeError.timedOut) {
            try SMARTHealthProbe.capture(deviceBSDName: "disk0", executableURL: executable, timeout: 0.1)
        }
        let task = Task.detached {
            try SMARTHealthProbe.capture(deviceBSDName: "disk0", executableURL: executable, timeout: 10)
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Cancelled SMART probe must not publish a snapshot")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @MainActor
    @Test func cancelledSwapRefreshCannotClearNewRefreshState() async throws {
        let probe = ControlledSwapProbe()
        let monitor = SwapMonitor(capture: { try await probe.capture() })
        defer { monitor.stop() }
        monitor.refresh()
        while await probe.count < 1 { await Task.yield() }
        monitor.stop()
        monitor.refresh()
        while await probe.count < 2 { await Task.yield() }
        // Complete the obsolete request with an ordinary failure. It must not
        // overwrite either the current request's error or its loading state.
        await probe.finish(0, result: .failure(NSError(domain: "OldProbe", code: 1)))
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(monitor.isRefreshing)
        #expect(monitor.errorMessage == nil)
        #expect(monitor.history.isEmpty)
        await probe.finish(1, result: .success(.empty))
        for _ in 0..<1000 {
            if !monitor.isRefreshing { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(!monitor.isRefreshing)
        #expect(monitor.history.count == 1)
    }
}

private actor ControlledSwapProbe {
    private var requests: [CheckedContinuation<SwapSnapshot, Error>] = []
    var count: Int { requests.count }

    func capture() async throws -> SwapSnapshot {
        try await withCheckedThrowingContinuation { requests.append($0) }
    }

    func finish(_ index: Int, result: Result<SwapSnapshot, Error>) {
        requests[index].resume(with: result)
    }
}
