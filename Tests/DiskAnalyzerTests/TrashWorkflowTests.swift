import Foundation
import Testing
@testable import DiskAnalyzer

@Suite("Trash workflow")
struct TrashWorkflowTests {
    @MainActor
    @Test("Moving a directory updates the snapshot without scanning and asks for verification")
    func movedDirectoryUpdatesSnapshotWithoutScanning() async throws {
        let fixtureURL = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: fixtureURL) }

        let sourceURL = fixtureURL.appendingPathComponent("source", isDirectory: true)
        let nestedURL = sourceURL.appendingPathComponent("nested", isDirectory: true)
        let payloadURL = nestedURL.appendingPathComponent("payload.bin")
        let destinationParentURL = fixtureURL.appendingPathComponent(
            "trash-like-destination",
            isDirectory: true
        )
        let destinationURL = destinationParentURL.appendingPathComponent(
            "source-renamed",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: nestedURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: destinationParentURL,
            withIntermediateDirectories: true
        )
        try Data(repeating: 0x41, count: 65_537).write(to: payloadURL)
        try Data(repeating: 0x42, count: 8_193).write(
            to: fixtureURL.appendingPathComponent("kept.bin")
        )

        let initialResult = try await scan(fixtureURL)
        let source = try #require(findNode(path: sourceURL.path, in: initialResult.root))
        let nested = try #require(findNode(path: nestedURL.path, in: initialResult.root))
        let controller = ScanController { url in
            #expect(!Thread.isMainThread)
            #expect(url.standardizedFileURL.path == sourceURL.standardizedFileURL.path)
            try FileManager.default.moveItem(at: url, to: destinationURL)
            return .moved(destinationURL: destinationURL)
        }
        controller.result = initialResult
        controller.navigationPath = [source, nested]
        controller.progress = completedProgress(for: initialResult)
        controller.addToCleanup(source)

        await controller.moveCollectedItemsToTrash()

        let reconciledResult = try #require(controller.result)
        #expect(!controller.isScanning)
        #expect(controller.cleanupItems.isEmpty)
        #expect(controller.cleanupPhase == .idle)
        #expect(controller.alertMessage == nil)
        #expect(controller.noticeMessage == L10n.text("collector.success.single", source.name))
        #expect(controller.resultFreshness == .needsVerification)
        #expect(!FileManager.default.fileExists(atPath: sourceURL.path))
        #expect(FileManager.default.fileExists(atPath: destinationURL.path))

        let movedNestedURL = destinationURL.appendingPathComponent("nested", isDirectory: true)
        let movedPayloadURL = movedNestedURL.appendingPathComponent("payload.bin")
        #expect(findNode(path: sourceURL.path, in: reconciledResult.root) == nil)
        #expect(findNode(path: nestedURL.path, in: reconciledResult.root) == nil)
        #expect(findNode(path: destinationURL.path, in: reconciledResult.root) != nil)
        #expect(findNode(path: movedNestedURL.path, in: reconciledResult.root) != nil)
        #expect(findNode(path: movedPayloadURL.path, in: reconciledResult.root) != nil)
        #expect(controller.navigationPath.map(\.path) == [
            destinationParentURL.path,
            destinationURL.path,
            movedNestedURL.path
        ])
        #expect(controller.displayRoot?.path == movedNestedURL.path)
        #expect(controller.displayRoot === controller.navigationPath.last)

        let freshResult = try await scan(fixtureURL)
        #expect(reconciledResult.root.logicalBytes == freshResult.root.logicalBytes)
        #expect(reconciledResult.root.allocatedBytes == freshResult.root.allocatedBytes)
        #expect(reconciledResult.root.fileCount == freshResult.root.fileCount)
        #expect(reconciledResult.root.directoryCount == freshResult.root.directoryCount)

        let publishedRoot = reconciledResult.root
        await Task.yield()
        #expect(controller.result?.root === publishedRoot)
        #expect(!controller.isScanning)
    }

    @MainActor
    @Test("An already-missing item is removed immediately without starting a scan")
    func alreadyMissingItemNeedsVerificationWithoutScanning() async throws {
        let fixtureURL = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: fixtureURL) }

        let missingURL = fixtureURL.appendingPathComponent("missing.bin")
        let keptURL = fixtureURL.appendingPathComponent("kept.bin")
        try Data(repeating: 0x41, count: 4_097).write(to: missingURL)
        try Data(repeating: 0x42, count: 8_193).write(to: keptURL)

        let initialResult = try await scan(fixtureURL)
        let missing = try #require(findNode(path: missingURL.path, in: initialResult.root))
        let kept = try #require(findNode(path: keptURL.path, in: initialResult.root))
        try FileManager.default.removeItem(at: missingURL)

        let controller = ScanController { url in
            #expect(url.standardizedFileURL.path == missingURL.standardizedFileURL.path)
            #expect(!FileManager.default.fileExists(atPath: url.path))
            return .alreadyMissing
        }
        controller.result = initialResult
        controller.progress = completedProgress(for: initialResult)
        controller.addToCleanup(missing)
        controller.selectedRankingNodeID = kept.id

        await controller.moveCollectedItemsToTrash()

        let reconciledResult = try #require(controller.result)
        #expect(!controller.isScanning)
        #expect(controller.resultFreshness == .needsVerification)
        #expect(findNode(path: missingURL.path, in: reconciledResult.root) == nil)
        #expect(findNode(path: keptURL.path, in: reconciledResult.root) != nil)
        #expect(controller.selectedRankingNodeID == kept.id)
        #expect(reconciledResult.root.fileCount == initialResult.root.fileCount - 1)
        #expect(controller.noticeMessage == L10n.text("collector.success.missing", missing.name))
        #expect(controller.cleanupItems.isEmpty)
        #expect(controller.cleanupPhase == .idle)
        #expect(controller.alertMessage == nil)

        let publishedRoot = reconciledResult.root
        await Task.yield()
        #expect(controller.result?.root === publishedRoot)
        #expect(!controller.isScanning)
    }

    @MainActor
    @Test("Collector reviews items and removes redundant descendants")
    func collectorReviewsItemsAndRemovesRedundantDescendants() {
        let child = fileNode(
            path: "/Users/demo/folder/child.bin",
            logicalBytes: 100,
            allocatedBytes: 80
        )
        let folder = FileNode(
            path: "/Users/demo/folder",
            name: "folder",
            kind: .directory,
            logicalBytes: 120,
            allocatedBytes: 96,
            children: [child],
            fileCount: 1,
            directoryCount: 1
        )
        let peer = fileNode(
            path: "/Users/demo/peer.bin",
            logicalBytes: 200,
            allocatedBytes: 160
        )
        let root = FileNode(
            path: "/Users/demo",
            name: "demo",
            kind: .directory,
            logicalBytes: 320,
            allocatedBytes: 256,
            children: [folder, peer],
            fileCount: 2,
            directoryCount: 2
        )
        let controller = ScanController()
        controller.result = scanResult(root: root)

        controller.addToCleanup(child)
        #expect(controller.cleanupItems.map(\.id) == [child.id])

        controller.addToCleanup(folder)
        #expect(controller.cleanupItems.map(\.id) == [folder.id])

        controller.addToCleanup(child)
        #expect(controller.cleanupItems.map(\.id) == [folder.id])
        #expect(controller.noticeMessage == L10n.text("collector.already_included", folder.name))

        controller.addToCleanup(peer)
        #expect(controller.cleanupItems.map(\.id) == [folder.id, peer.id])
        #expect(controller.cleanupBytes(for: .allocated) == 256)

        controller.removeFromCleanup(folder)
        #expect(controller.cleanupItems.map(\.id) == [peer.id])
        controller.clearCleanup()
        #expect(controller.cleanupItems.isEmpty)
    }

    @MainActor
    @Test("Collector countdown can be cancelled before any file operation")
    func collectorCountdownCanBeCancelled() async {
        let target = fileNode(
            path: "/Users/demo/target.bin",
            logicalBytes: 100,
            allocatedBytes: 80
        )
        let root = FileNode(
            path: "/Users/demo",
            name: "demo",
            kind: .directory,
            logicalBytes: 100,
            allocatedBytes: 80,
            children: [target],
            fileCount: 1,
            directoryCount: 1
        )
        let controller = ScanController { _ in
            Issue.record("Trash operation must not start after countdown cancellation")
            return .alreadyMissing
        }
        controller.result = scanResult(root: root)
        controller.addToCleanup(target)

        controller.beginCleanupCountdown(seconds: 1)
        #expect(controller.cleanupPhase == .countdown(1))
        controller.cancelCleanupCountdown()
        await Task.yield()

        #expect(controller.cleanupPhase == .idle)
        #expect(controller.cleanupItems.map(\.id) == [target.id])
    }

    @Test("The system trash bridge classifies a missing path without creating a fixture")
    func finderBridgeClassifiesMissingPath() throws {
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskAnalyzerMissing-\(UUID().uuidString)")

        #expect(!FileManager.default.fileExists(atPath: missingURL.path))
        #expect(try FinderBridge.moveToTrash(missingURL) == .alreadyMissing)
        #expect(!FileManager.default.fileExists(atPath: missingURL.path))
    }

    @MainActor
    @Test("A non-missing trash error preserves the complete scan snapshot")
    func ordinaryTrashErrorPreservesSnapshot() async {
        let target = fileNode(
            path: "/Users/demo/folder/target.bin",
            logicalBytes: 100,
            allocatedBytes: 80
        )
        let kept = fileNode(
            path: "/Users/demo/folder/kept.bin",
            logicalBytes: 200,
            allocatedBytes: 160
        )
        let folder = FileNode(
            path: "/Users/demo/folder",
            name: "folder",
            kind: .directory,
            logicalBytes: 300,
            allocatedBytes: 240,
            children: [target, kept],
            fileCount: 2,
            directoryCount: 1
        )
        let root = FileNode(
            path: "/Users/demo",
            name: "demo",
            kind: .directory,
            logicalBytes: 400,
            allocatedBytes: 320,
            children: [folder],
            fileCount: 2,
            directoryCount: 2
        )
        let initialResult = scanResult(
            root: root,
            largestDirectories: [folder],
            largestFiles: [target, kept]
        )
        let controller = ScanController { _ in
            throw SimulatedTrashError.permissionDenied
        }
        controller.result = initialResult
        controller.navigationPath = [folder]
        controller.progress = completedProgress(for: initialResult)
        controller.addToCleanup(target)
        controller.selectedRankingNodeID = target.id

        await controller.moveCollectedItemsToTrash()

        #expect(controller.cleanupItems.map(\.id) == [target.id])
        #expect(controller.cleanupPhase == .idle)
        #expect(controller.result?.root === root)
        #expect(controller.navigationPath.count == 1)
        #expect(controller.navigationPath.first === folder)
        #expect(controller.result?.root.logicalBytes == 400)
        #expect(controller.result?.root.allocatedBytes == 320)
        #expect(controller.result?.root.fileCount == 2)
        #expect(controller.result?.root.directoryCount == 2)
        #expect(controller.result?.largestDirectories.first === folder)
        #expect(controller.result?.largestFiles.map(\.id) == [target.id, kept.id])
        #expect(controller.resultFreshness == .scanBacked)
        #expect(controller.selectedRankingNodeID == target.id)
        #expect(!controller.isScanning)
        #expect(controller.noticeMessage == nil)
        #expect(controller.alertMessage == L10n.text(
            "trash.failed",
            SimulatedTrashError.permissionDenied.localizedDescription
        ))
    }

    private func makeFixtureDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "DiskAnalyzerTrashWorkflow-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }

    private func scan(_ url: URL) async throws -> DiskScanResult {
        let scanner = DiskScanner()
        let operation = await scanner.scan(from: url)
        return try await operation.task.value
    }

    private func completedProgress(for result: DiskScanResult) -> ScanProgress {
        ScanProgress(
            scannedItems: result.root.fileCount + result.root.directoryCount,
            scannedFiles: result.root.fileCount,
            scannedDirectories: result.root.directoryCount,
            allocatedBytes: result.root.allocatedBytes,
            currentPath: result.rootURL.path,
            phase: .done
        )
    }

    private func fileNode(
        path: String,
        logicalBytes: Int64,
        allocatedBytes: Int64
    ) -> FileNode {
        FileNode(
            path: path,
            name: URL(fileURLWithPath: path).lastPathComponent,
            kind: .file,
            logicalBytes: logicalBytes,
            allocatedBytes: allocatedBytes,
            fileCount: 1
        )
    }

    private func scanResult(
        root: FileNode,
        largestDirectories: [FileNode] = [],
        largestFiles: [FileNode] = []
    ) -> DiskScanResult {
        DiskScanResult(
            root: root,
            rootURL: URL(fileURLWithPath: root.path ?? "/", isDirectory: true),
            volume: nil,
            isVolumeRoot: false,
            elapsedSeconds: 1,
            diagnostics: ScanDiagnostics(
                unreadableDirectoryCount: 0,
                metadataErrorCount: 0,
                duplicateDirectoryCount: 0,
                duplicateFileCount: 0
            ),
            largestDirectories: largestDirectories,
            largestFiles: largestFiles
        )
    }

    private func findNode(path: String, in root: FileNode?) -> FileNode? {
        guard let root else { return nil }
        var stack = [root]
        while let node = stack.popLast() {
            if node.path == path { return node }
            stack.append(contentsOf: node.children)
        }
        return nil
    }
}

private enum SimulatedTrashError: LocalizedError {
    case permissionDenied

    var errorDescription: String? {
        "Simulated permission denial"
    }
}
