import Foundation
import Testing
@testable import DiskAnalyzer

@Suite("Snapshot trash reconciler")
struct SnapshotTrashReconcilerTests {
    @Test("Mapped paths compare complete path components")
    func mappedPathsDoNotConfuseSiblingPrefixes() {
        #expect(SnapshotTrashReconciler.mappedPath(
            "/foo/child.bin",
            sourcePath: "/foo",
            destinationPath: "/Trash/foo"
        ) == "/Trash/foo/child.bin")
        #expect(SnapshotTrashReconciler.mappedPath(
            "/foobar/child.bin",
            sourcePath: "/foo",
            destinationPath: "/Trash/foo"
        ) == "/foobar/child.bin")
    }

    @Test("A directory move inside the root rebases the snapshot but still needs verification")
    func sameRootDirectoryMoveRebasesWholeSubtree() async throws {
        let rootURL = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let sourceURL = rootURL.appendingPathComponent("source", isDirectory: true)
        let nestedURL = sourceURL.appendingPathComponent("nested", isDirectory: true)
        let destinationParentURL = rootURL.appendingPathComponent("trash", isDirectory: true)
        try FileManager.default.createDirectory(
            at: nestedURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: destinationParentURL,
            withIntermediateDirectories: true
        )
        try writeFiles(count: 3, to: sourceURL, prefix: "direct")
        try writeFiles(count: 3, to: nestedURL, prefix: "nested")

        var options = ScanOptions.default
        options.retainedFilesPerDirectory = 1
        let original = try await scan(rootURL, options: options)
        let source = try #require(findNode(path: sourceURL.path, in: original.root))
        let originalPathEntries = pathEntries(in: source)
        let originalAggregateEntries = aggregateEntries(in: source)
        #expect(!originalAggregateEntries.isEmpty)

        let destinationURL = destinationParentURL
            .appendingPathComponent("moved-source", isDirectory: true)
        try FileManager.default.moveItem(at: sourceURL, to: destinationURL)

        let update = try #require(SnapshotTrashReconciler.moved(
            source,
            destinationURL: destinationURL,
            in: original
        ))

        #expect(update.freshness == .needsVerification)
        #expect(update.destinationPath == destinationURL.path)
        #expect(findNode(path: sourceURL.path, in: update.result.root) == nil)
        #expect(update.result.root.fileCount == original.root.fileCount)
        #expect(update.result.root.directoryCount == original.root.directoryCount)

        for entry in originalPathEntries {
            #expect(entry.id == entry.path)
            let expectedPath = try #require(SnapshotTrashReconciler.mappedPath(
                entry.path,
                sourcePath: sourceURL.path,
                destinationPath: destinationURL.path
            ))
            let rebased = try #require(findNode(path: expectedPath, in: update.result.root))
            #expect(rebased.path == expectedPath)
            #expect(rebased.id == expectedPath)
        }

        let moved = try #require(findNode(path: destinationURL.path, in: update.result.root))
        let expectedAggregateIDs = Set(originalAggregateEntries.compactMap { entry in
            SnapshotTrashReconciler.mappedPath(
                entry.parentPath,
                sourcePath: sourceURL.path,
                destinationPath: destinationURL.path
            ).map { "aggregate:\($0)" }
        })
        let rebasedAggregateIDs = Set(aggregateEntries(in: moved).map(\.id))
        #expect(rebasedAggregateIDs == expectedAggregateIDs)
    }

    @Test("A same-root move stays unverified when the subtree changed after scanning")
    func changedSubtreePreventsAFalseAccuracyClaim() async throws {
        let rootURL = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let sourceURL = rootURL.appendingPathComponent("source", isDirectory: true)
        let destinationParentURL = rootURL.appendingPathComponent("trash", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourceURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: destinationParentURL,
            withIntermediateDirectories: true
        )
        let originalFileURL = sourceURL.appendingPathComponent("original.bin")
        try Data(repeating: 0x5A, count: 16_384).write(to: originalFileURL)

        let original = try await scan(rootURL)
        let source = try #require(findNode(path: sourceURL.path, in: original.root))
        try Data(repeating: 0x6B, count: 32_768).write(
            to: sourceURL.appendingPathComponent("added-after-scan.bin")
        )

        let destinationURL = destinationParentURL
            .appendingPathComponent("moved-source", isDirectory: true)
        try FileManager.default.moveItem(at: sourceURL, to: destinationURL)

        let update = try #require(SnapshotTrashReconciler.moved(
            source,
            destinationURL: destinationURL,
            in: original
        ))

        #expect(update.destinationPath == destinationURL.path)
        #expect(update.freshness == .needsVerification)
        let fresh = try await scan(rootURL)
        #expect(update.result.root.fileCount != fresh.root.fileCount)
    }

    @Test("A move outside the root needs verification and subtracts root counts")
    func destinationOutsideRootSubtractsMovedSubtreeCounts() async throws {
        let fixtureURL = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: fixtureURL) }

        let rootURL = fixtureURL.appendingPathComponent("scan-root", isDirectory: true)
        let outsideURL = fixtureURL.appendingPathComponent("outside", isDirectory: true)
        let sourceURL = rootURL.appendingPathComponent("source", isDirectory: true)
        let nestedURL = sourceURL.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(
            at: nestedURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: outsideURL,
            withIntermediateDirectories: true
        )
        try Data(repeating: 0x11, count: 4_096)
            .write(to: sourceURL.appendingPathComponent("source.bin"))
        try Data(repeating: 0x22, count: 8_192)
            .write(to: nestedURL.appendingPathComponent("nested.bin"))
        try Data(repeating: 0x33, count: 12_288)
            .write(to: rootURL.appendingPathComponent("kept.bin"))

        let original = try await scan(rootURL)
        let source = try #require(findNode(path: sourceURL.path, in: original.root))
        let destinationURL = outsideURL
            .appendingPathComponent("moved-source", isDirectory: true)
        try FileManager.default.moveItem(at: sourceURL, to: destinationURL)

        let update = try #require(SnapshotTrashReconciler.moved(
            source,
            destinationURL: destinationURL,
            in: original
        ))

        #expect(update.freshness == .needsVerification)
        #expect(findNode(path: sourceURL.path, in: update.result.root) == nil)
        #expect(update.result.root.fileCount == original.root.fileCount - source.fileCount)
        #expect(
            update.result.root.directoryCount
                == original.root.directoryCount - source.directoryCount
        )
    }

    private func makeFixtureDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SnapshotTrashReconcilerTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }

    private func writeFiles(count: Int, to directory: URL, prefix: String) throws {
        for index in 0..<count {
            try Data(repeating: UInt8(index + 1), count: (index + 1) * 4_096)
                .write(to: directory.appendingPathComponent("\(prefix)-\(index).bin"))
        }
    }

    private func scan(
        _ rootURL: URL,
        options: ScanOptions = .default
    ) async throws -> DiskScanResult {
        let scanner = DiskScanner()
        let operation = await scanner.scan(from: rootURL, options: options)
        return try await operation.task.value
    }

    private func findNode(path: String, in root: FileNode) -> FileNode? {
        var stack = [root]
        while let node = stack.popLast() {
            if node.path == path { return node }
            stack.append(contentsOf: node.children)
        }
        return nil
    }

    private func pathEntries(in root: FileNode) -> [(path: String, id: String)] {
        var entries: [(path: String, id: String)] = []
        var stack = [root]
        while let node = stack.popLast() {
            if let path = node.path {
                entries.append((path: path, id: node.id))
            }
            stack.append(contentsOf: node.children)
        }
        return entries
    }

    private func aggregateEntries(
        in root: FileNode
    ) -> [(id: String, parentPath: String)] {
        var entries: [(id: String, parentPath: String)] = []
        var stack = [root]
        while let directory = stack.popLast() {
            guard directory.isDirectory, let directoryPath = directory.path else { continue }
            for child in directory.children {
                if child.kind == .otherFiles {
                    entries.append((id: child.id, parentPath: directoryPath))
                } else if child.isDirectory {
                    stack.append(child)
                }
            }
        }
        return entries
    }
}
