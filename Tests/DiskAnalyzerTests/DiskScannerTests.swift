import Darwin
import AppKit
import DiskStatusCore
import Foundation
import ImageIO
import SwapAnalysisCore
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import DiskAnalyzer

@Suite("Disk scanner accuracy")
struct DiskScannerTests {
    @MainActor
    @Test("Tool scanners default to the startup disk root")
    func toolScannersDefaultToStartupDiskRoot() {
        #expect(LargeFileScanController().rootURL.standardizedFileURL.path == "/")
        #expect(SimilarImageScanController().rootURL.standardizedFileURL.path == "/")
    }

    @Test("Large file scan uses a strict decimal MB threshold and ignores symlinks")
    func largeFileScanThresholdAndTraversalRules() async throws {
        let fixtureURL = try makeFixture()
        let outsideURL = try makeFixture()
        defer {
            try? FileManager.default.removeItem(at: fixtureURL)
            try? FileManager.default.removeItem(at: outsideURL)
        }

        func createSparseFile(named name: String, size: Int64, in root: URL) throws {
            let url = root.appendingPathComponent(name)
            let descriptor = Darwin.open(url.path, O_CREAT | O_WRONLY, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else { throw FixtureError.cannotCreateSparseFile }
            defer { Darwin.close(descriptor) }
            guard Darwin.ftruncate(descriptor, size) == 0 else {
                throw FixtureError.cannotCreateSparseFile
            }
        }

        try createSparseFile(named: "below.bin", size: 999_999, in: fixtureURL)
        try createSparseFile(named: "exact.bin", size: 1_000_000, in: fixtureURL)
        try createSparseFile(named: "above.bin", size: 1_000_001, in: fixtureURL)
        try createSparseFile(named: "largest.bin", size: 2_000_000, in: fixtureURL)
        try createSparseFile(named: "outside.bin", size: 3_000_000, in: outsideURL)
        try FileManager.default.createSymbolicLink(
            at: fixtureURL.appendingPathComponent("outside-link.bin"),
            withDestinationURL: outsideURL.appendingPathComponent("outside.bin")
        )

        #expect(LargeFileThreshold.bytes(forMegabytes: 1) == 1_000_000)
        #expect(LargeFileThreshold.bytes(forMegabytes: 100) == 100_000_000)
        #expect(LargeFileThreshold.bytes(forMegabytes: 0) == 1_000_000)

        let scanner = LargeFileScanner()
        let operation = await scanner.scan(
            from: fixtureURL,
            thresholdBytes: LargeFileThreshold.bytes(forMegabytes: 1)
        )
        let result = try await operation.task.value

        #expect(result.files.map { $0.url.lastPathComponent } == [
            "largest.bin",
            "above.bin"
        ])
        #expect(result.files.map(\.logicalBytes) == [2_000_000, 1_000_001])
        #expect(result.scannedFileCount == 4)
        #expect(result.scannedDirectoryCount == 1)
        #expect(result.thresholdBytes == 1_000_000)
        #expect(result.diagnostics == LargeFileScanDiagnostics())

        var bufferedProgress: [LargeFileScanProgress] = []
        for await update in operation.stream {
            bufferedProgress.append(update)
        }
        #expect(bufferedProgress.count == 1)
        guard case .done = try #require(bufferedProgress.first).phase else {
            Issue.record("The final large-file progress update must be retained")
            return
        }
    }

    @Test("Similar image scan finds transformed copies without following symlinks")
    func similarImageScanFindsNearDuplicates() async throws {
        let fixtureURL = try makeFixture()
        let outsideURL = try makeFixture()
        defer {
            try? FileManager.default.removeItem(at: fixtureURL)
            try? FileManager.default.removeItem(at: outsideURL)
        }

        let originalURL = fixtureURL.appendingPathComponent("original.png")
        let resizedURL = fixtureURL.appendingPathComponent("resized.png")
        let convertedURL = fixtureURL.appendingPathComponent("converted.jpg")
        let differentURL = fixtureURL.appendingPathComponent("different.png")
        let brokenURL = fixtureURL.appendingPathComponent("broken.jpg")
        let outsideImageURL = outsideURL.appendingPathComponent("outside.png")

        try writeFixtureImage(
            to: originalURL,
            width: 160,
            height: 100,
            style: .reference,
            type: .png
        )
        try writeFixtureImage(
            to: resizedURL,
            width: 320,
            height: 200,
            style: .reference,
            type: .png
        )
        try writeFixtureImage(
            to: convertedURL,
            width: 160,
            height: 100,
            style: .reference,
            type: .jpeg,
            quality: 0.78
        )
        try writeFixtureImage(
            to: differentURL,
            width: 160,
            height: 100,
            style: .different,
            type: .png
        )
        try Data("not an image".utf8).write(to: brokenURL)
        try writeFixtureImage(
            to: outsideImageURL,
            width: 160,
            height: 100,
            style: .reference,
            type: .png
        )
        try FileManager.default.createSymbolicLink(
            at: fixtureURL.appendingPathComponent("outside-link.png"),
            withDestinationURL: outsideImageURL
        )

        #expect(ImageSimilarityThreshold.clampedPercent(40) == 70)
        #expect(ImageSimilarityThreshold.clampedPercent(110) == 100)
        #expect(VisionFeatureDistanceThreshold.clamped(-1) == 0)
        #expect(VisionFeatureDistanceThreshold.clamped(80) == 50)
        #expect(
            VisionFeatureDistanceThreshold.clamped(.nan)
                == VisionFeatureDistanceThreshold.defaultValue
        )
        #expect(VisionFeatureSimilarityScale.similarityPercent(forDistance: 0) == 100)
        #expect(VisionFeatureSimilarityScale.similarityPercent(forDistance: 12.5) == 75)
        #expect(VisionFeatureSimilarityScale.similarityPercent(forDistance: 50) == 0)
        #expect(VisionFeatureSimilarityScale.similarityPercent(forDistance: 80) == 0)
        #expect(
            VisionFeatureSimilarityScale.distance(forSimilarityPercent: 75) == 12.5
        )
        #expect(
            VisionFeatureSimilarityScale.distance(forSimilarityPercent: 100) == 0
        )
        #expect(
            VisionFeatureSimilarityScale.distance(forSimilarityPercent: -10) == 50
        )

        let scanner = SimilarImageScanner()
        let operation = await scanner.scan(
            from: fixtureURL,
            similarityPercent: ImageSimilarityThreshold.defaultPercent
        )
        let result = try await operation.task.value

        #expect(result.similarityPercent == 90)
        #expect(result.scannedFileCount == 5)
        #expect(result.candidateImageCount == 5)
        #expect(result.analyzedImageCount == 4)
        #expect(result.diagnostics.imageDecodeErrorCount == 1)
        #expect(result.diagnostics.unreadableDirectoryCount == 0)
        #expect(result.diagnostics.metadataErrorCount == 0)
        #expect(result.groups.count == 1)

        let group = try #require(result.groups.first)
        let groupedNames = Set(group.members.map { $0.item.url.lastPathComponent })
        #expect(groupedNames == Set(["original.png", "resized.png", "converted.jpg"]))
        #expect(group.members.first?.item.url.lastPathComponent == "resized.png")
        #expect(group.members.first?.isReference == true)
        #expect(group.members.dropFirst().allSatisfy { member in
            guard case let .perceptualSimilarity(value) = member.score else {
                return false
            }
            return value >= 0.9
        })
        #expect(!groupedNames.contains("different.png"))
        #expect(!groupedNames.contains("outside-link.png"))

        var bufferedProgress: [SimilarImageScanProgress] = []
        for await update in operation.stream {
            bufferedProgress.append(update)
        }
        #expect(bufferedProgress.count == 1)
        #expect(bufferedProgress.first?.phase == .done)

        let visionOperation = await scanner.scan(
            from: fixtureURL,
            configuration: SimilarImageScanConfiguration(
                method: .appleVision,
                visionMaximumDistance: VisionFeatureDistanceThreshold.defaultValue
            )
        )
        let visionResult = try await visionOperation.task.value
        #expect(visionResult.configuration.method == .appleVision)
        #expect(visionResult.scannedFileCount == 5)
        #expect(visionResult.candidateImageCount == 5)
        #expect(visionResult.analyzedImageCount == 4)
        #expect(visionResult.diagnostics.imageDecodeErrorCount == 1)
        #expect(visionResult.groups.count == 1)

        let visionGroup = try #require(visionResult.groups.first)
        let visionNames = Set(visionGroup.members.map { $0.item.url.lastPathComponent })
        #expect(visionNames == Set(["original.png", "resized.png", "converted.jpg"]))
        #expect(visionGroup.members.first?.item.url.lastPathComponent == "resized.png")
        #expect(visionGroup.members.dropFirst().allSatisfy { member in
            guard case let .visionDistance(value) = member.score else {
                return false
            }
            return value <= VisionFeatureDistanceThreshold.defaultValue
        })
        #expect(!visionNames.contains("different.png"))
        #expect(!visionNames.contains("outside-link.png"))
    }

    @Test("Progress stream retains only the latest update for a delayed UI")
    func progressStreamDropsStaleBufferedUpdates() async throws {
        let fixtureURL = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixtureURL) }

        let scanner = DiskScanner()
        let operation = await scanner.scan(from: fixtureURL)
        _ = try await operation.task.value

        var bufferedUpdates: [ScanProgress] = []
        for await update in operation.stream {
            bufferedUpdates.append(update)
        }

        #expect(bufferedUpdates.count == 1)
        let finalUpdate = try #require(bufferedUpdates.first)
        guard case .done = finalUpdate.phase else {
            Issue.record("The newest buffered progress update must be the completed state")
            return
        }
    }

    @Test("Allocated and logical totals match lstat metadata")
    func allocatedAndLogicalTotalsMatchFileSystemMetadata() async throws {
        let fixtureURL = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixtureURL) }

        let nested = fixtureURL.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        let alpha = fixtureURL.appendingPathComponent("alpha.bin")
        let beta = nested.appendingPathComponent("beta.bin")
        try Data(repeating: 0x41, count: 12_345).write(to: alpha)
        try Data(repeating: 0x42, count: 65_537).write(to: beta)

        let betaLink = fixtureURL.appendingPathComponent("beta-hard-link.bin")
        try FileManager.default.linkItem(at: beta, to: betaLink)

        let sparse = fixtureURL.appendingPathComponent("sparse.img")
        let descriptor = Darwin.open(sparse.path, O_CREAT | O_WRONLY, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw FixtureError.cannotCreateSparseFile }
        guard Darwin.ftruncate(descriptor, 8 * 1_024 * 1_024) == 0 else {
            Darwin.close(descriptor)
            throw FixtureError.cannotCreateSparseFile
        }
        Darwin.close(descriptor)

        let directoryLink = fixtureURL.appendingPathComponent("nested-link")
        try FileManager.default.createSymbolicLink(at: directoryLink, withDestinationURL: nested)

        let scanner = DiskScanner()
        let operation = await scanner.scan(from: fixtureURL)
        let result = try await operation.task.value
        let expected = try expectedTotals(at: fixtureURL)

        #expect(result.root.logicalBytes == expected.logical)
        #expect(result.root.allocatedBytes == expected.allocated)
        #expect(result.root.allocatedBytes == (try duAllocatedBytes(at: fixtureURL)))
        #expect(result.root.fileCount == 5)
        #expect(result.root.directoryCount == 2)
        #expect(result.diagnostics.duplicateFileCount == 1)

        let directoryLinkNode = findNode(named: "nested-link", in: result.root)
        #expect(directoryLinkNode?.kind == .symbolicLink)
        #expect(directoryLinkNode?.children.isEmpty == true)

        let hardLinkNode = findNode(named: "beta-hard-link.bin", in: result.root)
        #expect(hardLinkNode?.isSharedReference == true)
    }

    @Test("Omitted files aggregate without losing bytes")
    func omittedFilesAreAggregatedWithoutLosingBytes() async throws {
        let fixtureURL = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixtureURL) }

        for index in 0..<12 {
            let url = fixtureURL.appendingPathComponent("file-\(index).bin")
            try Data(repeating: UInt8(index), count: 4_096 + index * 257).write(to: url)
        }

        var options = ScanOptions.default
        options.retainedFilesPerDirectory = 2
        let scanner = DiskScanner()
        let operation = await scanner.scan(from: fixtureURL, options: options)
        let result = try await operation.task.value

        let aggregate = result.root.children.first { $0.kind == .otherFiles }
        #expect(aggregate != nil)
        #expect((aggregate?.omittedItemCount ?? 0) > 0)

        guard let rootInfo = fileStat(at: fixtureURL) else {
            throw FixtureError.cannotReadMetadata
        }
        let childrenLogical = result.root.children.reduce(Int64(0)) {
            $0 + $1.logicalBytes
        }
        #expect(childrenLogical + Int64(rootInfo.st_size) == result.root.logicalBytes)

        let childrenAllocated = result.root.children.reduce(Int64(0)) {
            $0 + $1.allocatedBytes
        }
        #expect(childrenAllocated + allocatedBytes(rootInfo) == result.root.allocatedBytes)
    }

    @Test("Missing path returns an actionable error")
    func missingPathReturnsActionableError() async throws {
        let fixtureURL = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixtureURL) }
        let missing = fixtureURL.appendingPathComponent("does-not-exist")
        let scanner = DiskScanner()
        let operation = await scanner.scan(from: missing)

        var failureMessage = ""
        do {
            _ = try await operation.task.value
            Issue.record("Expected scan to fail")
        } catch {
            failureMessage = error.localizedDescription
        }
        #expect(failureMessage == L10n.text("scanner.error.path_missing", missing.path))
    }

    @Test("Unreadable directories are reported instead of aborting the scan")
    func unreadableDirectoriesAreReported() async throws {
        let fixtureURL = try makeFixture()
        let locked = fixtureURL.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data(repeating: 0x7F, count: 8_192)
            .write(to: locked.appendingPathComponent("hidden.bin"))
        guard Darwin.chmod(locked.path, 0) == 0 else {
            throw FixtureError.cannotChangePermissions
        }
        defer {
            Darwin.chmod(locked.path, S_IRWXU)
            try? FileManager.default.removeItem(at: fixtureURL)
        }

        let scanner = DiskScanner()
        let operation = await scanner.scan(from: fixtureURL)
        let result = try await operation.task.value

        #expect(result.diagnostics.unreadableDirectoryCount == 1)
        #expect(result.diagnostics.issues.count == 1)
        #expect(result.diagnostics.issues.first?.kind == .unreadableDirectory)
        #expect(result.diagnostics.issues.first?.path == locked.path)
        let lockedNode = findNode(named: "locked", in: result.root)
        #expect(lockedNode?.isUnreadable == true)
        #expect(lockedNode?.fileCount == 0)
    }

    @Test("Skipped volumes stay separate from coverage warnings")
    func skippedVolumesStaySeparateFromCoverageWarnings() {
        let skippedVolumes = (1...11).map { index in
            SkippedVolumeInfo(
                name: "Volume \(index)",
                path: "/Volumes/Volume \(index)",
                kind: .externalOrDiskImage
            )
        }
        let skippedOnly = ScanDiagnostics(
            unreadableDirectoryCount: 0,
            metadataErrorCount: 0,
            skippedVolumes: skippedVolumes,
            duplicateDirectoryCount: 0,
            duplicateFileCount: 0
        )

        #expect(skippedOnly.hasCoverageWarning == false)
        #expect(skippedOnly.coverageSummary == nil)
        #expect(skippedOnly.skippedVolumesSummary == L10n.text(
            "diagnostics.skipped_volumes",
            11.formatted()
        ))
        let previewNames = ["Volume 1", "Volume 2", "Volume 3"]
            .joined(separator: L10n.text("diagnostics.list_separator"))
        #expect(skippedOnly.skippedVolumeNamesPreview == L10n.text(
            "diagnostics.list_more",
            previewNames
        ))

        let partialCoverage = ScanDiagnostics(
            unreadableDirectoryCount: 242,
            metadataErrorCount: 31,
            skippedVolumes: skippedVolumes,
            duplicateDirectoryCount: 0,
            duplicateFileCount: 0
        )

        #expect(partialCoverage.hasCoverageWarning == true)
        let expectedCoverage = [
            L10n.text("diagnostics.unreadable_directories", 242.formatted()),
            L10n.text("diagnostics.metadata_errors", 31.formatted())
        ].joined(separator: L10n.text("diagnostics.list_separator"))
        #expect(partialCoverage.coverageSummary == expectedCoverage)
        #expect(partialCoverage.skippedVolumesSummary == L10n.text(
            "diagnostics.skipped_volumes",
            11.formatted()
        ))
    }

    @Test("Skipped volume categories are evidence based")
    func skippedVolumeCategoriesAreEvidenceBased() {
        #expect(SkippedVolumeInfo.Kind.infer(
            path: "/System/Volumes/Preboot",
            isLocal: true,
            isRemovable: false,
            isEjectable: false
        ) == .system)
        #expect(SkippedVolumeInfo.Kind.infer(
            path: "/Volumes/Backup",
            isLocal: true,
            isRemovable: true,
            isEjectable: true
        ) == .externalOrDiskImage)
        #expect(SkippedVolumeInfo.Kind.infer(
            path: "/Network/Servers/shared",
            isLocal: false,
            isRemovable: false,
            isEjectable: false
        ) == .network)
        #expect(SkippedVolumeInfo.Kind.infer(
            path: "/dev",
            isLocal: true,
            isRemovable: false,
            isEjectable: false
        ) == .other)
    }

    @Test("Scan issue details preserve paths and POSIX errors")
    func scanIssueDetailsPreserveRawEvidence() {
        let issue = ScanIssue(
            kind: .unreadableDirectory,
            path: "/System/protected",
            errorCode: EACCES
        )

        #expect(issue.path == "/System/protected")
        #expect(issue.errorDescription.contains("EACCES 13"))
        #expect(issue.errorDescription.contains("Permission denied"))
    }

    @Test("Ad-hoc updates require Full Disk Access reconfirmation")
    func adHocUpdatesRequireReconfirmation() {
        let oldIdentity = "old-cdhash"
        let newBuild = AppCodeIdentity(fingerprint: "new-cdhash", isAdHoc: true)

        #expect(FullDiskAccessConfirmationStatus.evaluate(
            probeResult: .denied,
            onboardingCompleted: true,
            confirmedCodeIdentity: oldIdentity,
            currentCodeIdentity: newBuild
        ) == .appIdentityChanged)

        #expect(FullDiskAccessConfirmationStatus.evaluate(
            probeResult: .denied,
            onboardingCompleted: true,
            confirmedCodeIdentity: newBuild.fingerprint,
            currentCodeIdentity: newBuild
        ) == .notConfirmed)

        #expect(FullDiskAccessConfirmationStatus.evaluate(
            probeResult: .granted,
            onboardingCompleted: true,
            confirmedCodeIdentity: oldIdentity,
            currentCodeIdentity: newBuild
        ) == .confirmed)
    }

    @Test("A saved confirmation never overrides a denied live probe")
    func savedConfirmationNeverOverridesDeniedProbe() {
        let signedBuild = AppCodeIdentity(fingerprint: "changed-cdhash", isAdHoc: false)

        #expect(FullDiskAccessConfirmationStatus.evaluate(
            probeResult: .denied,
            onboardingCompleted: true,
            confirmedCodeIdentity: "previous-cdhash",
            currentCodeIdentity: signedBuild
        ) == .notConfirmed)
    }

    @Test("An unavailable probe is reported without guessing")
    func unavailableProbeIsReportedWithoutGuessing() {
        #expect(FullDiskAccessConfirmationStatus.evaluate(
            probeResult: .unavailable,
            onboardingCompleted: true,
            confirmedCodeIdentity: "saved-cdhash",
            currentCodeIdentity: AppCodeIdentity(fingerprint: "saved-cdhash", isAdHoc: true)
        ) == .unableToVerify)
    }

    @Test("Full Disk Access probe classifies POSIX outcomes")
    func fullDiskAccessProbeClassifiesPOSIXOutcomes() {
        #expect(FullDiskAccessProbe.classify(fileDescriptor: 4, errorCode: 0) == .granted)
        #expect(FullDiskAccessProbe.classify(fileDescriptor: -1, errorCode: EPERM) == .denied)
        #expect(FullDiskAccessProbe.classify(fileDescriptor: -1, errorCode: EACCES) == .denied)
        #expect(FullDiskAccessProbe.classify(fileDescriptor: -1, errorCode: ENOENT) == .unavailable)
    }

    @Test("English and Simplified Chinese localization tables are available")
    func localizationTablesAreAvailable() {
        #expect(L10n.text("app.title", language: .english) == "Disk Analyzer")
        #expect(L10n.text("app.title", language: .simplifiedChinese) == "磁盘分析")
        #expect(L10n.text("analysis.mode.status", language: .english) == "Disk Status")
        #expect(L10n.text("analysis.mode.status", language: .simplifiedChinese) == "磁盘状态")
        #expect(L10n.text("analysis.mode.tools", language: .english) == "Tools")
        #expect(L10n.text("analysis.mode.tools", language: .simplifiedChinese) == "工具")
        #expect(L10n.text("large_files.title", language: .english) == "Large File Finder")
        #expect(L10n.text("large_files.title", language: .simplifiedChinese) == "大文件扫描")
        #expect(L10n.text("similar_images.title", language: .english) == "Similar Image Finder")
        #expect(L10n.text("similar_images.title", language: .simplifiedChinese) == "相似图片扫描")
        #expect(L10n.text(
            "similar_images.method.vision",
            language: .english
        ) == "Apple Vision")
        #expect(L10n.text(
            "similar_images.method.perceptual",
            language: .simplifiedChinese
        ) == "近似副本")
        #expect(L10n.text(
            "large_files.empty.detail",
            language: .english,
            "100"
        ).contains("100 MB"))
        #expect(L10n.text(
            "large_files.empty.detail",
            language: .simplifiedChinese,
            "100"
        ).contains("100 MB"))
        #expect(L10n.text(
            "similar_images.empty.detail",
            language: .english,
            "90"
        ).contains("90%"))
        #expect(L10n.text(
            "similar_images.empty.detail",
            language: .simplifiedChinese,
            "90"
        ).contains("90%"))
        #expect(L10n.text(
            "similar_images.empty.vision.detail",
            language: .english,
            "12.5"
        ).contains("12.5"))
        #expect(AnalysisMode.allCases.last == .tools)
        #expect(L10n.text(
            "toolbar.items",
            language: .english,
            "12"
        ) == "12 items")
        #expect(L10n.text(
            "toolbar.items",
            language: .simplifiedChinese,
            "12"
        ) == "12 个项目")
        #expect(L10n.text("settings.language.title", language: .english) == "Interface Language")
        #expect(L10n.text("settings.language.title", language: .simplifiedChinese) == "界面语言")
        #expect(L10n.text("swap.title", language: .english) == "Swap Space Analysis")
        #expect(L10n.text("swap.title", language: .simplifiedChinese) == "交换空间分析")
        #expect(L10n.text("smart.title", language: .english) == "S.M.A.R.T. Health")
        #expect(L10n.text("smart.title", language: .simplifiedChinese) == "S.M.A.R.T. 健康")
        #expect(L10n.text("smart.install.title", language: .english) == "Install smartmontools")
        #expect(L10n.text("smart.install.title", language: .simplifiedChinese) == "安装 smartmontools")
        #expect(!L10n.text(
            "swap.accounting.notice",
            language: .english
        ).contains("swap.accounting.notice"))
        #expect(!L10n.text(
            "swap.accounting.notice",
            language: .simplifiedChinese
        ).contains("swap.accounting.notice"))
    }

    @Test("Language selection prefers an explicit preview override and otherwise persists")
    func languageSelectionResolution() {
        #expect(AppLanguage.resolve(
            environmentValue: nil,
            storedValue: AppLanguage.english.rawValue
        ) == .english)
        #expect(AppLanguage.resolve(
            environmentValue: nil,
            storedValue: AppLanguage.simplifiedChinese.rawValue
        ) == .simplifiedChinese)
        #expect(AppLanguage.resolve(
            environmentValue: AppLanguage.english.rawValue,
            storedValue: AppLanguage.simplifiedChinese.rawValue
        ) == .english)
        #expect(AppLanguage.resolve(
            environmentValue: nil,
            storedValue: "unsupported"
        ) == .simplifiedChinese)
    }

    @Test("Permission guide drags the actual application file URL")
    func permissionGuideDragsActualApplicationFileURL() {
        let applicationURL = URL(fileURLWithPath: "/Applications/DiskAnalyzer.app")
        let payload = ApplicationDragPayload.makePasteboardItem(for: applicationURL)

        #expect(payload.string(forType: .fileURL) == applicationURL.absoluteString)
    }

    @MainActor
    @Test("Returning home preserves the completed analysis and drill-down position")
    func returningHomePreservesCompletedAnalysis() {
        let child = FileNode(
            path: "/Users/demo/Projects",
            name: "Projects",
            kind: .directory,
            logicalBytes: 40_000_000_000,
            allocatedBytes: 40_000_000_000
        )
        let root = FileNode(
            path: "/Users/demo",
            name: "demo",
            kind: .directory,
            logicalBytes: 100_000_000_000,
            allocatedBytes: 100_000_000_000,
            children: [child]
        )
        let result = DiskScanResult(
            root: root,
            rootURL: URL(fileURLWithPath: "/Users/demo", isDirectory: true),
            volume: nil,
            isVolumeRoot: false,
            elapsedSeconds: 12,
            diagnostics: ScanDiagnostics(
                unreadableDirectoryCount: 0,
                metadataErrorCount: 0,
                duplicateDirectoryCount: 0,
                duplicateFileCount: 0
            ),
            largestDirectories: [child],
            largestFiles: []
        )
        let controller = ScanController()
        controller.result = result
        controller.navigationPath = [child]

        #expect(controller.isPresentingResult)
        #expect(controller.toolbarScanURL?.path == "/Users/demo")

        controller.showHome()

        #expect(controller.isShowingHome)
        #expect(!controller.isPresentingResult)
        #expect(controller.toolbarScanURL == nil)
        #expect(controller.result?.root.id == root.id)
        #expect(controller.displayRoot?.id == child.id)

        controller.showLatestResult()

        #expect(controller.isPresentingResult)
        #expect(controller.toolbarScanURL?.path == "/Users/demo")
        #expect(controller.displayRoot?.id == child.id)
    }

    @MainActor
    @Test("Rescan releases the previous result tree before building its replacement")
    func rescanReleasesPreviousResultTree() {
        let rootURL = URL(
            fileURLWithPath: "/tmp/disk-analyzer-rescan-memory-fixture",
            isDirectory: true
        )
        let child = FileNode(
            path: rootURL.appendingPathComponent("nested", isDirectory: true).path,
            name: "nested",
            kind: .directory,
            logicalBytes: 4_096,
            allocatedBytes: 4_096
        )
        let root = FileNode(
            path: rootURL.path,
            name: "fixture",
            kind: .directory,
            logicalBytes: 8_192,
            allocatedBytes: 8_192,
            children: [child]
        )
        let controller = ScanController()
        controller.result = DiskScanResult(
            root: root,
            rootURL: rootURL,
            volume: nil,
            isVolumeRoot: false,
            elapsedSeconds: 1,
            diagnostics: ScanDiagnostics(
                unreadableDirectoryCount: 0,
                metadataErrorCount: 0,
                duplicateDirectoryCount: 0,
                duplicateFileCount: 0
            ),
            largestDirectories: [child],
            largestFiles: []
        )
        controller.navigationPath = [child]

        controller.rescan()

        #expect(controller.result == nil)
        #expect(controller.navigationPath.isEmpty)
        #expect(controller.currentScanURL?.path == rootURL.path)
        #expect(controller.isScanning)
        controller.cancelScan()
    }

    @MainActor
    @Test("Result context controls remain visible at the minimum window width")
    func resultContextControlsRemainVisible() throws {
        let root = FileNode(
            path: "/Users/demo",
            name: "demo",
            kind: .directory,
            logicalBytes: 100_000_000_000,
            allocatedBytes: 100_000_000_000
        )
        let controller = ScanController()
        controller.result = DiskScanResult(
            root: root,
            rootURL: URL(fileURLWithPath: "/Users/demo", isDirectory: true),
            volume: nil,
            isVolumeRoot: false,
            elapsedSeconds: 12,
            diagnostics: ScanDiagnostics(
                unreadableDirectoryCount: 0,
                metadataErrorCount: 0,
                duplicateDirectoryCount: 0,
                duplicateFileCount: 0
            ),
            largestDirectories: [],
            largestFiles: []
        )

        let resultToolbar = navigationToolbar(for: controller)
        let resultImage = try render(
            view: resultToolbar,
            size: CGSize(width: 1_040, height: 60)
        )

        #expect(resultImage.pixelsWide >= 1_040)

        if let captureDirectory = ProcessInfo.processInfo.environment["DISK_ANALYZER_CAPTURE_UI"] {
            let directory = URL(fileURLWithPath: captureDirectory)
            try writePNG(resultImage, to: directory.appendingPathComponent("result-toolbar.png"))
        }
    }

    @MainActor
    @Test("Ranking sort menu keeps a readable width in the narrow pane")
    func rankingSortMenuKeepsReadableWidth() throws {
        let root = FileNode(
            path: "/Users/demo",
            name: "demo",
            kind: .directory,
            logicalBytes: 100_000_000_000,
            allocatedBytes: 100_000_000_000
        )
        let view = RankingListView(
            nodes: [],
            displayRoot: root,
            metric: .allocated,
            scope: .constant(.current),
            sortOption: .constant(.sizeDescending),
            searchText: .constant(""),
            selectedNodeID: .constant(nil),
            cleanupNodeIDs: [],
            isCleanupActive: false,
            onRevealInFinder: { _ in },
            onDrillDown: { _ in },
            onAddToCleanup: { _ in },
            onRemoveFromCleanup: { _ in }
        )
        .frame(width: 360, height: 240)

        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(x: 0, y: 0, width: 360, height: 240)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()

        let popUpButtons = descendants(of: hostingView).compactMap { $0 as? NSPopUpButton }
        #expect(popUpButtons.count == 1)
        let sortButton = try #require(popUpButtons.first)
        #expect(sortButton.frame.width >= 96)

        var ancestor = sortButton.superview
        var ancestorWidths: [CGFloat] = []
        while let current = ancestor, current !== hostingView {
            if current.bounds.width > 0 {
                ancestorWidths.append(current.bounds.width)
            }
            ancestor = current.superview
        }
        #expect(ancestorWidths.min() ?? 0 >= sortButton.frame.width - 1)

        if let captureDirectory = ProcessInfo.processInfo.environment["DISK_ANALYZER_CAPTURE_UI"] {
            let image = try render(view: view, size: CGSize(width: 360, height: 240))
            try writePNG(
                image,
                to: URL(fileURLWithPath: captureDirectory)
                    .appendingPathComponent("ranking-controls-narrow.png")
            )
        }
    }

    @MainActor
    @Test("Skipped volume banner and detail views render")
    func skippedVolumeViewsRender() throws {
        let diagnostics = ScanDiagnostics(
            unreadableDirectoryCount: 0,
            metadataErrorCount: 0,
            skippedVolumes: [
                SkippedVolumeInfo(name: "VM", path: "/System/Volumes/VM", kind: .system),
                SkippedVolumeInfo(name: "Preboot", path: "/System/Volumes/Preboot", kind: .system),
                SkippedVolumeInfo(name: "Update", path: "/System/Volumes/Update", kind: .system),
                SkippedVolumeInfo(name: "xART", path: "/System/Volumes/xarts", kind: .system),
                SkippedVolumeInfo(name: "Sample External Volume", path: "/Volumes/TestExternalDrive", kind: .externalOrDiskImage)
            ],
            duplicateDirectoryCount: 0,
            duplicateFileCount: 0
        )

        let banner = SkippedVolumesBannerView(diagnostics: diagnostics)
            .padding(.horizontal, 16)
            .background(Color(nsColor: .windowBackgroundColor))
            .frame(width: 1_032, height: 110)
            .environment(\.colorScheme, .light)
        let detail = SkippedVolumesDetailView(diagnostics: diagnostics)
            .environment(\.colorScheme, .light)

        let bannerImage = try render(view: banner, size: CGSize(width: 1_032, height: 110))
        let detailImage = try render(view: detail, size: CGSize(width: 860, height: 560))
        #expect(bannerImage.pixelsWide > 0)
        #expect(detailImage.pixelsHigh > 0)

        if let captureDirectory = ProcessInfo.processInfo.environment["DISK_ANALYZER_CAPTURE_UI"] {
            try writePNG(
                bannerImage,
                to: URL(fileURLWithPath: captureDirectory)
                    .appendingPathComponent("skipped-volumes-banner.png")
            )
            try writePNG(
                detailImage,
                to: URL(fileURLWithPath: captureDirectory)
                    .appendingPathComponent("skipped-volumes-detail.png")
            )
        }
    }

    @MainActor
    @Test("Shallow ancestor sunburst expands to the full chart radius")
    func shallowAncestorSunburstFillsAvailableRadius() throws {
        func item(_ name: String, path: String, bytes: Int64) -> FileNode {
            FileNode(
                path: path,
                name: name,
                kind: .file,
                logicalBytes: bytes,
                allocatedBytes: bytes
            )
        }

        let workspace = FileNode(
            path: "/Users/demo/Projects/Workspace",
            name: "Workspace",
            kind: .directory,
            logicalBytes: 98_000_000_000,
            allocatedBytes: 98_000_000_000,
            children: [
                item(
                    "dataset-primary.bin",
                    path: "/Users/demo/Projects/Workspace/dataset-primary.bin",
                    bytes: 52_000_000_000
                ),
                item(
                    "dataset-secondary.bin",
                    path: "/Users/demo/Projects/Workspace/dataset-secondary.bin",
                    bytes: 28_000_000_000
                ),
                item(
                    "reference-corpus.bin",
                    path: "/Users/demo/Projects/Workspace/reference-corpus.bin",
                    bytes: 18_000_000_000
                )
            ]
        )
        let ancestor = FileNode(
            path: "/Users/demo/Projects",
            name: "Projects",
            kind: .directory,
            logicalBytes: 132_000_000_000,
            allocatedBytes: 132_000_000_000,
            children: [
                workspace,
                FileNode(
                    path: "/Users/demo/Projects/Automation",
                    name: "Automation",
                    kind: .directory,
                    logicalBytes: 20_000_000_000,
                    allocatedBytes: 20_000_000_000
                ),
                FileNode(
                    path: "/Users/demo/Projects/Utilities",
                    name: "Utilities",
                    kind: .directory,
                    logicalBytes: 8_000_000_000,
                    allocatedBytes: 8_000_000_000
                )
            ]
        )
        let segments = SunburstLayout.layout(
            root: ancestor,
            metric: .allocated,
            isDarkMode: false
        )

        #expect(segments.map(\.depth).max() == 2)
        let outerRadius = try #require(segments.map(\.outerRadius).max())
        #expect(abs(outerRadius - SunburstLayout.maximumOuterRadius) < 0.000_1)

        let view = SunburstView(
            node: ancestor,
            metric: .allocated,
            onDrillDown: { _ in },
            onRevealInFinder: { _ in },
            initialSegments: segments
        )
        .padding(14)
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(width: 920, height: 460)
        .environment(\.colorScheme, .light)

        let image = try render(view: view, size: CGSize(width: 920, height: 460))
        #expect(image.pixelsWide >= 920)
        #expect(image.pixelsHigh >= 460)

        if let captureDirectory = ProcessInfo.processInfo.environment["DISK_ANALYZER_CAPTURE_UI"] {
            try writePNG(
                image,
                to: URL(fileURLWithPath: captureDirectory)
                    .appendingPathComponent("sunburst-shallow-ancestor.png")
            )
        }
    }

    @MainActor
    @Test("Compact sunburst keeps its interaction hint outside the chart")
    func compactSunburstKeepsHintOutsideChart() throws {
        let applications = FileNode(
            path: "/Applications",
            name: "Applications",
            kind: .directory,
            logicalBytes: 70_000_000_000,
            allocatedBytes: 70_000_000_000
        )
        let archives = (1...18).map { index in
            FileNode(
                path: "/Users/demo/Documents/Projects/Archive-\(index)",
                name: "Archive \(index)",
                kind: .directory,
                logicalBytes: 3_500_000_000,
                allocatedBytes: 3_500_000_000
            )
        }
        let projects = FileNode(
            path: "/Users/demo/Documents/Projects",
            name: "Projects",
            kind: .directory,
            logicalBytes: 70_000_000_000,
            allocatedBytes: 70_000_000_000,
            children: archives
        )
        let documents = FileNode(
            path: "/Users/demo/Documents",
            name: "Documents",
            kind: .directory,
            logicalBytes: 90_000_000_000,
            allocatedBytes: 90_000_000_000,
            children: [projects]
        )
        let users = FileNode(
            path: "/Users",
            name: "Users",
            kind: .directory,
            logicalBytes: 300_000_000_000,
            allocatedBytes: 300_000_000_000,
            children: [documents]
        )
        let system = FileNode(
            path: "/System",
            name: "System",
            kind: .directory,
            logicalBytes: 130_000_000_000,
            allocatedBytes: 130_000_000_000
        )
        let root = FileNode(
            path: "/",
            name: "Macintosh HD",
            kind: .directory,
            logicalBytes: 500_000_000_000,
            allocatedBytes: 500_000_000_000,
            children: [users, system, applications]
        )
        let segments = SunburstLayout.layout(
            root: root,
            metric: .allocated,
            isDarkMode: false
        )
        let view = SunburstView(
            node: root,
            metric: .allocated,
            onDrillDown: { _ in },
            onRevealInFinder: { _ in },
            initialSegments: segments
        )
        .padding(14)
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(width: 520, height: 390)
        .environment(\.colorScheme, .light)

        let image = try render(view: view, size: CGSize(width: 520, height: 390))
        #expect(image.pixelsWide >= 520)
        #expect(image.pixelsHigh >= 390)
        #expect(image.pixelsWide * 390 == image.pixelsHigh * 520)

        if let captureDirectory = ProcessInfo.processInfo.environment["DISK_ANALYZER_CAPTURE_UI"] {
            try writePNG(
                image,
                to: URL(fileURLWithPath: captureDirectory)
                    .appendingPathComponent("sunburst-compact.png")
            )
        }
    }

    @MainActor
    @Test("Repository preview renders with privacy-safe sample data")
    func repositoryPreviewRendersWithSampleData() throws {
        let result = makeRepositoryPreviewResult()
        let controller = ScanController { _ in
            Issue.record("Collector rendering must not perform a file operation")
            return .alreadyMissing
        }
        controller.result = result
        controller.metric = .allocated

        let preview = VStack(spacing: 0) {
            AnalysisNavigationBar(
                selection: .constant(.diskSpace),
                onShowHome: {},
                onShowSettings: {}
            )

            Divider()

            ScanControlView(
                controller: controller,
                onChooseDirectory: {},
                onRescan: {}
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)

            Divider()
            ResultsView(
                controller: controller,
                result: result,
                onRescan: {},
                initialSunburstSegments: SunburstLayout.layout(
                    root: result.root,
                    metric: .allocated,
                    isDarkMode: false
                )
            )
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(width: 1_440, height: 1_024)
        .environment(\.locale, AppLanguage.current.locale)
        .environment(\.colorScheme, .light)

        let image = try render(view: preview, size: CGSize(width: 1_440, height: 1_024))
        #expect(image.pixelsWide >= 1_440)
        #expect(image.pixelsHigh >= 1_024)

        if let captureDirectory = ProcessInfo.processInfo.environment["DISK_ANALYZER_CAPTURE_UI"] {
            try writePNG(
                image,
                to: URL(fileURLWithPath: captureDirectory)
                    .appendingPathComponent("disk-analyzer-overview.png")
            )
        }
    }

    @MainActor
    @Test("Tools stays last in the navigation and renders at minimum size")
    func toolsRendersAtMinimumWindowSize() throws {
        let rootURL = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        let result = LargeFileScanResult(
            rootURL: rootURL,
            thresholdBytes: 100_000_000,
            files: [
                LargeFileMatch(
                    url: rootURL.appendingPathComponent("Movies/Archive.mov"),
                    logicalBytes: 8_400_000_000,
                    allocatedBytes: 8_100_000_000
                ),
                LargeFileMatch(
                    url: rootURL.appendingPathComponent("Models/model.safetensors"),
                    logicalBytes: 4_200_000_000,
                    allocatedBytes: 4_200_001_536
                ),
                LargeFileMatch(
                    url: rootURL.appendingPathComponent("Downloads/installer.dmg"),
                    logicalBytes: 1_480_000_000,
                    allocatedBytes: 1_480_003_584
                ),
                LargeFileMatch(
                    url: rootURL.appendingPathComponent("Videos/demo.mp4"),
                    logicalBytes: 780_000_000,
                    allocatedBytes: 780_001_280
                ),
                LargeFileMatch(
                    url: rootURL.appendingPathComponent("Documents/data.jsonl"),
                    logicalBytes: 320_000_000,
                    allocatedBytes: 320_004_096
                )
            ],
            scannedFileCount: 182_431,
            scannedDirectoryCount: 24_618,
            elapsedSeconds: 12.84,
            diagnostics: LargeFileScanDiagnostics()
        )
        let controller = LargeFileScanController(
            rootURL: rootURL,
            thresholdMegabytes: 100,
            result: result
        )
        let similarImageController = SimilarImageScanController(rootURL: rootURL)
        let preview = VStack(spacing: 0) {
            AnalysisNavigationBar(
                selection: .constant(.tools),
                onShowHome: {},
                onShowSettings: {}
            )

            Divider()

            ToolsView(
                largeFileController: controller,
                similarImageController: similarImageController,
                selection: .constant(.largeFiles)
            )
        }
        .frame(width: 1_040, height: 680)
        .environment(\.locale, AppLanguage.current.locale)
        .environment(\.colorScheme, .light)

        let image = try render(view: preview, size: CGSize(width: 1_040, height: 680))
        #expect(image.pixelsWide >= 1_040)
        #expect(image.pixelsHigh >= 680)

        if let captureDirectory = ProcessInfo.processInfo.environment["DISK_ANALYZER_CAPTURE_UI"] {
            try writePNG(
                image,
                to: URL(fileURLWithPath: captureDirectory)
                    .appendingPathComponent("tools.png")
            )
        }
    }

    @MainActor
    @Test("Similar image results remain readable at the minimum window size")
    func similarImageResultsRenderAtMinimumWindowSize() throws {
        let rootURL = URL(fileURLWithPath: "/Users/example/Pictures", isDirectory: true)
        func item(
            _ name: String,
            bytes: Int64,
            width: Int,
            height: Int,
            color: (UInt8, UInt8, UInt8)
        ) -> SimilarImageItem {
            SimilarImageItem(
                url: rootURL.appendingPathComponent(name),
                logicalBytes: bytes,
                pixelWidth: width,
                pixelHeight: height,
                thumbnailRGBA: previewThumbnailRGBA(
                    red: color.0,
                    green: color.1,
                    blue: color.2
                )
            )
        }

        let groups = [
            SimilarImageGroup(members: [
                SimilarImageMember(
                    item: item(
                        "Mountain-original.png",
                        bytes: 12_400_000,
                        width: 6_000,
                        height: 4_000,
                        color: (42, 126, 224)
                    ),
                    score: .visionDistance(0),
                    isReference: true
                ),
                SimilarImageMember(
                    item: item(
                        "Mountain-export.jpg",
                        bytes: 3_800_000,
                        width: 3_000,
                        height: 2_000,
                        color: (46, 130, 220)
                    ),
                    score: .visionDistance(2.58),
                    isReference: false
                ),
                SimilarImageMember(
                    item: item(
                        "Mountain-small.webp",
                        bytes: 840_000,
                        width: 1_200,
                        height: 800,
                        color: (48, 132, 218)
                    ),
                    score: .visionDistance(3.64),
                    isReference: false
                )
            ]),
            SimilarImageGroup(members: [
                SimilarImageMember(
                    item: item(
                        "Poster-master.tiff",
                        bytes: 28_600_000,
                        width: 4_000,
                        height: 5_000,
                        color: (231, 105, 53)
                    ),
                    score: .visionDistance(0),
                    isReference: true
                ),
                SimilarImageMember(
                    item: item(
                        "Poster-copy.heic",
                        bytes: 5_200_000,
                        width: 2_000,
                        height: 2_500,
                        color: (226, 108, 57)
                    ),
                    score: .visionDistance(4.2),
                    isReference: false
                )
            ])
        ]
        let result = SimilarImageScanResult(
            rootURL: rootURL,
            configuration: SimilarImageScanConfiguration(
                method: .appleVision,
                visionMaximumDistance: VisionFeatureDistanceThreshold.defaultValue
            ),
            groups: groups,
            scannedFileCount: 18_420,
            candidateImageCount: 2_316,
            analyzedImageCount: 2_312,
            elapsedSeconds: 9.42,
            diagnostics: SimilarImageScanDiagnostics()
        )
        let largeFileController = LargeFileScanController(rootURL: rootURL)
        let similarImageController = SimilarImageScanController(
            rootURL: rootURL,
            similarityPercent: 90,
            result: result
        )
        let preview = VStack(spacing: 0) {
            AnalysisNavigationBar(
                selection: .constant(.tools),
                onShowHome: {},
                onShowSettings: {}
            )

            Divider()

            ToolsView(
                largeFileController: largeFileController,
                similarImageController: similarImageController,
                selection: .constant(.similarImages)
            )
        }
        .frame(width: 1_040, height: 680)
        .environment(\.locale, AppLanguage.current.locale)
        .environment(\.colorScheme, .light)

        let image = try render(view: preview, size: CGSize(width: 1_040, height: 680))
        #expect(image.pixelsWide >= 1_040)
        #expect(image.pixelsHigh >= 680)

        if let captureDirectory = ProcessInfo.processInfo.environment["DISK_ANALYZER_CAPTURE_UI"] {
            try writePNG(
                image,
                to: URL(fileURLWithPath: captureDirectory)
                    .appendingPathComponent("similar-images.png")
            )
        }
    }

    @MainActor
    @Test("Disk status remains readable at the minimum window size")
    func diskStatusRendersAtMinimumWindowSize() throws {
        let capturedAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let volume = DiskVolumeMetrics(
            name: "Sample SSD",
            mountPath: "/",
            totalBytes: 500_000_000_000,
            availableBytes: 83_600_000_000,
            volumeBSDName: "disk3s1",
            physicalBSDName: "disk0"
        )
        let coverage = DiskIOCoverage(
            discoveredProcesses: 650,
            readableProcesses: 396,
            permissionDeniedProcesses: 246,
            vanishedProcesses: 7,
            unavailableProcesses: 1
        )
        let processRates = [
            previewProcessDiskRate(1, "Sample Browser", 2_900_000, 680_000),
            previewProcessDiskRate(2, "Video Editor", 1_250_000, 2_100_000),
            previewProcessDiskRate(3, "Developer Tools", 920_000, 410_000),
            previewProcessDiskRate(4, "Cloud Sync", 180_000, 840_000),
            previewProcessDiskRate(5, "Search Indexer", 610_000, 90_000),
            previewProcessDiskRate(6, "Notes", 120_000, 70_000)
        ]
        let snapshot = DiskIOSnapshot(
            capturedAt: capturedAt,
            scanDuration: 0.08,
            volume: volume,
            device: DiskDeviceCounters(
                bytesRead: 300_000_000_000,
                bytesWritten: 200_000_000_000
            ),
            processes: [],
            coverage: coverage
        )
        let rates = DiskIORates(
            interval: 1,
            deviceReadBytesPerSecond: 8_400_000,
            deviceWriteBytesPerSecond: 4_200_000,
            processes: processRates
        )
        let smartHealth = SMARTHealthSnapshot(
            capturedAt: capturedAt,
            deviceBSDName: "disk0",
            executablePath: "/opt/example/smartctl",
            overallPassed: true,
            criticalWarning: 0,
            temperatureCelsius: 32,
            availableSparePercent: 100,
            availableSpareThresholdPercent: 10,
            percentageUsed: 3,
            dataUnitsRead: 80_000_000,
            dataUnitsWritten: 48_000_000,
            hostReadCommands: 1_200_000_000,
            hostWriteCommands: 900_000_000,
            controllerBusyTimeMinutes: 120,
            powerCycles: 160,
            powerOnHours: 2_400,
            unsafeShutdowns: 2,
            mediaAndDataIntegrityErrors: 0,
            errorInformationLogEntries: 0
        )
        var history: [DiskIOHistoryPoint] = []
        for index in 0..<13 {
            let timestamp = capturedAt.addingTimeInterval(Double(index - 12) * 5)
            let readRate = Double((index * 791_113) % 16_000_000)
            let writeRate = Double((index * 431_177) % 9_000_000)
            history.append(DiskIOHistoryPoint(
                timestamp: timestamp,
                readBytesPerSecond: readRate,
                writeBytesPerSecond: writeRate
            ))
        }
        let monitor = DiskStatusMonitor(
            snapshot: snapshot,
            rates: rates,
            history: history,
            isMonitoring: true,
            smartHealth: smartHealth,
            isSMARTToolInstalled: true
        )
        let view = VStack(spacing: 0) {
            AnalysisNavigationBar(
                selection: .constant(.diskStatus),
                onShowHome: {},
                onShowSettings: {}
            )

            Divider()

            DiskStatusView(monitor: monitor, startsAutomatically: false)
        }
        .frame(width: 1_040, height: 680)
        .environment(\.locale, AppLanguage.current.locale)

        let image = try render(view: view, size: CGSize(width: 1_040, height: 680))
        #expect(image.pixelsWide >= 1_040)
        #expect(image.pixelsHigh >= 680)

        let smartDetails = SMARTHealthDetailsView(
            snapshot: smartHealth,
            errorMessage: nil
        )
        .frame(width: 720, height: 320)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.locale, AppLanguage.current.locale)
        .environment(\.colorScheme, .light)
        let smartDetailsImage = try render(
            view: smartDetails,
            size: CGSize(width: 720, height: 320)
        )
        #expect(smartDetailsImage.pixelsWide >= 720)
        #expect(smartDetailsImage.pixelsHigh >= 320)

        let noSMARTMonitor = DiskStatusMonitor(
            snapshot: snapshot,
            rates: rates,
            history: history,
            isMonitoring: true,
            smartHealth: nil,
            isSMARTToolInstalled: false
        )
        let noSMARTView = VStack(spacing: 0) {
            AnalysisNavigationBar(
                selection: .constant(.diskStatus),
                onShowHome: {},
                onShowSettings: {}
            )

            Divider()

            DiskStatusView(monitor: noSMARTMonitor, startsAutomatically: false)
        }
        .frame(width: 1_040, height: 680)
        .environment(\.locale, AppLanguage.current.locale)
        let noSMARTImage = try render(
            view: noSMARTView,
            size: CGSize(width: 1_040, height: 680)
        )
        #expect(noSMARTImage.pixelsWide >= 1_040)
        #expect(noSMARTImage.pixelsHigh >= 680)

        let installHelp = SMARTInstallHelpView(onRecheck: { false })
            .frame(width: 420, height: 270)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.locale, AppLanguage.current.locale)
            .environment(\.colorScheme, .light)
        let installHelpImage = try render(
            view: installHelp,
            size: CGSize(width: 420, height: 270)
        )
        #expect(installHelpImage.pixelsWide >= 420)
        #expect(installHelpImage.pixelsHigh >= 270)

        if let captureDirectory = ProcessInfo.processInfo.environment["DISK_ANALYZER_CAPTURE_UI"] {
            try writePNG(
                image,
                to: URL(fileURLWithPath: captureDirectory)
                    .appendingPathComponent("disk-status.png")
            )
            try writePNG(
                smartDetailsImage,
                to: URL(fileURLWithPath: captureDirectory)
                    .appendingPathComponent("smart-health-details.png")
            )
            try writePNG(
                noSMARTImage,
                to: URL(fileURLWithPath: captureDirectory)
                    .appendingPathComponent("disk-status-no-smartctl.png")
            )
            try writePNG(
                installHelpImage,
                to: URL(fileURLWithPath: captureDirectory)
                    .appendingPathComponent("smart-install-help.png")
            )
        }
    }

    @MainActor
    @Test("Swap analysis remains readable at the minimum window size")
    func swapAnalysisRendersAtMinimumWindowSize() throws {
        let groupSpecs: [(String, UInt64, UInt64, UInt64)] = [
            ("Sample Browser", 1_100_000_000, 2_400_000_000, 1_200_000_000),
            ("Creative Studio Helper", 700_000_000, 1_500_000_000, 900_000_000),
            ("Chat Client", 500_000_000, 1_100_000_000, 720_000_000),
            ("Developer Tools", 300_000_000, 680_000_000, 610_000_000),
            ("Background Service", 200_000_000, 440_000_000, 300_000_000),
            ("Notes", 100_000_000, 220_000_000, 180_000_000),
            ("Small Utility", 50_000_000, 110_000_000, 90_000_000)
        ]
        let groups = groupSpecs.enumerated().map { index, spec in
            let bundlePath = "/Applications/\(spec.0).app"
            let process = ProcessMemorySample(
                id: Int32(42 + index),
                parentPID: 1,
                processName: "\(spec.0) Helper",
                executablePath: "\(bundlePath)/Contents/MacOS/\(spec.0)",
                applicationKey: "app:\(bundlePath)",
                applicationName: spec.0,
                applicationBundlePath: bundlePath,
                compressorBackedBytes: spec.2,
                residentBytes: spec.3,
                virtualBytes: 8_000_000_000,
                regionCount: 320,
                usesTranslatedArchitecture: false
            )
            return ApplicationMemoryGroup(
                id: process.applicationKey,
                name: process.applicationName,
                bundlePath: process.applicationBundlePath,
                estimatedSwapBytes: spec.1,
                compressorBackedBytes: process.compressorBackedBytes,
                residentBytes: process.residentBytes,
                processes: [process]
            )
        }
        let attributedSwapBytes = groups.reduce(UInt64(0)) {
            $0 + $1.estimatedSwapBytes
        }
        let capturedAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let snapshot = SwapSnapshot(
            capturedAt: capturedAt,
            scanDuration: 1.24,
            system: SystemMemoryMetrics(
                physicalMemoryBytes: 32_000_000_000,
                swapTotalBytes: 8_000_000_000,
                swapUsedBytes: 3_200_000_000,
                swapFreeBytes: 4_800_000_000,
                compressorStorageBytes: 4_000_000_000,
                compressorUncompressedBytes: 6_000_000_000,
                swapInsPages: 10_000,
                swapOutsPages: 12_000,
                kernelPageSize: 16_384
            ),
            coverage: ScanCoverage(
                discoveredProcesses: 650,
                readableProcesses: 430,
                permissionDeniedProcesses: 210,
                vanishedProcesses: 8,
                unavailableProcesses: 2,
                regionLimitProcesses: 0
            ),
            groups: groups,
            attributedSwapBytes: attributedSwapBytes,
            unattributedSwapBytes: 3_200_000_000 - attributedSwapBytes
        )
        let history = [
            // Swap capacity can shrink between samples. Keep an older value above
            // the current total to exercise the chart's history-aware scale.
            SwapHistoryPoint(timestamp: capturedAt.addingTimeInterval(-90), usedBytes: 9_400_000_000),
            SwapHistoryPoint(timestamp: capturedAt.addingTimeInterval(-60), usedBytes: 9_200_000_000),
            SwapHistoryPoint(timestamp: capturedAt.addingTimeInterval(-30), usedBytes: 5_000_000_000),
            SwapHistoryPoint(timestamp: capturedAt, usedBytes: 3_200_000_000)
        ]
        let monitor = SwapMonitor(snapshot: snapshot, history: history)
        monitor.selectedGroupID = groups.first?.id
        let view = VStack(spacing: 0) {
            AnalysisNavigationBar(
                selection: .constant(.swapSpace),
                onShowHome: {},
                onShowSettings: {}
            )

            Divider()

            SwapAnalysisView(
                monitor: monitor,
                startsAutomatically: false
            )
        }
        .frame(width: 1_040, height: 680)
        .environment(\.locale, AppLanguage.current.locale)

        let image = try render(view: view, size: CGSize(width: 1_040, height: 680))
        #expect(image.pixelsWide >= 1_040)
        #expect(image.pixelsHigh >= 680)

        if let captureDirectory = ProcessInfo.processInfo.environment["DISK_ANALYZER_CAPTURE_UI"] {
            try writePNG(
                image,
                to: URL(fileURLWithPath: captureDirectory)
                    .appendingPathComponent("swap-analysis.png")
            )
        }
    }

    @MainActor
    @Test("Cleanup Collector renders compact and expanded review states")
    func cleanupCollectorRendersAsFloatingReviewPanel() throws {
        let result = makeRepositoryPreviewResult()
        let controller = ScanController()
        controller.result = result
        controller.metric = .allocated
        let modelTraining = try #require(findNode(named: "Model Training", in: result.root))
        let downloads = try #require(findNode(named: "Downloads", in: result.root))
        controller.addToCleanup(modelTraining)
        controller.addToCleanup(downloads)

        let preview = ResultsView(
            controller: controller,
            result: result,
            onRescan: {},
            initialSunburstSegments: SunburstLayout.layout(
                root: result.root,
                metric: .allocated,
                isDarkMode: false
            )
        )
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(width: 1_040, height: 680)
        .environment(\.locale, AppLanguage.simplifiedChinese.locale)
        .environment(\.colorScheme, .light)

        let compactImage = try render(view: preview, size: CGSize(width: 1_040, height: 680))
        #expect(compactImage.pixelsWide >= 1_040)
        #expect(compactImage.pixelsHigh >= 680)
        #expect(controller.cleanupItems.count == 2)

        controller.isCleanupCollectorExpanded = true
        let expandedImage = try render(view: preview, size: CGSize(width: 1_040, height: 680))
        #expect(expandedImage.pixelsWide >= 1_040)
        #expect(expandedImage.pixelsHigh >= 680)

        controller.isCleanupCollectorExpanded = false
        controller.beginCleanupCountdown()
        let countdownImage = try render(view: preview, size: CGSize(width: 1_040, height: 680))
        controller.cancelCleanupCountdown()
        #expect(countdownImage.pixelsWide >= 1_040)
        #expect(controller.cleanupPhase == .idle)

        if let captureDirectory = ProcessInfo.processInfo.environment["DISK_ANALYZER_CAPTURE_UI"] {
            try writePNG(
                compactImage,
                to: URL(fileURLWithPath: captureDirectory)
                    .appendingPathComponent("cleanup-collector-compact.png")
            )
            try writePNG(
                expandedImage,
                to: URL(fileURLWithPath: captureDirectory)
                    .appendingPathComponent("cleanup-collector-expanded.png")
            )
            try writePNG(
                countdownImage,
                to: URL(fileURLWithPath: captureDirectory)
                    .appendingPathComponent("cleanup-collector-countdown.png")
            )
        }
    }

    @MainActor
    @Test("Repository home preview renders with privacy-safe sample data")
    func repositoryHomePreviewRendersWithSampleData() throws {
        let controller = ScanController()

        let preview = VStack(spacing: 0) {
            AnalysisNavigationBar(
                selection: .constant(nil),
                onShowHome: {},
                onShowSettings: {}
            )

            Divider()

            EmptyStateView(
                controller: controller,
                fullDiskAccessConfirmationStatus: .confirmed,
                onShowPermissionGuide: {},
                onShowLatestResult: {},
                onScanStartupDisk: {},
                onScanHomeDirectory: {},
                onChooseDirectory: {},
                onShowSwapAnalysis: {},
                homeDirectoryPath: "/Users/Sample"
            )
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(width: 1_440, height: 1_024)
        .environment(\.locale, AppLanguage.current.locale)
        .environment(\.colorScheme, .light)

        let image = try render(view: preview, size: CGSize(width: 1_440, height: 1_024))
        #expect(image.pixelsWide >= 1_440)
        #expect(image.pixelsHigh >= 1_024)

        if let captureDirectory = ProcessInfo.processInfo.environment["DISK_ANALYZER_CAPTURE_UI"] {
            try writePNG(
                image,
                to: URL(fileURLWithPath: captureDirectory)
                    .appendingPathComponent("disk-analyzer-home.png")
            )
        }
    }

    @MainActor
    @Test("Language settings render at their intended size")
    func languageSettingsRender() throws {
        let view = LanguageSettingsView(
            languageCode: .constant(AppLanguage.current.rawValue)
        )
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(width: 460, height: 280)
        .environment(\.colorScheme, .light)

        let image = try render(view: view, size: CGSize(width: 460, height: 280))
        #expect(image.pixelsWide >= 460)
        #expect(image.pixelsHigh >= 280)

        if let captureDirectory = ProcessInfo.processInfo.environment["DISK_ANALYZER_CAPTURE_UI"] {
            try writePNG(
                image,
                to: URL(fileURLWithPath: captureDirectory)
                    .appendingPathComponent("language-settings.png")
            )
        }
    }

    @MainActor
    private func render<V: View>(
        view: V,
        size: CGSize
    ) throws -> NSBitmapImageRep {
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()
        guard let image = hostingView.bitmapImageRepForCachingDisplay(
            in: hostingView.bounds
        ) else {
            throw FixtureError.cannotRenderView
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: image)
        return image
    }

    @MainActor
    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants)
    }

    @MainActor
    private func navigationToolbar(for controller: ScanController) -> some View {
        ScanControlView(
            controller: controller,
            onChooseDirectory: {},
            onRescan: {}
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(width: 1_040, height: 60)
        .environment(\.colorScheme, .light)
    }

    private func makeRepositoryPreviewResult() -> DiskScanResult {
        func gb(_ whole: Int64, _ megabytes: Int64 = 0) -> Int64 {
            whole * 1_000_000_000 + megabytes * 1_000_000
        }

        func directory(
            _ name: String,
            path: String,
            allocated: Int64,
            logical: Int64? = nil,
            children: [FileNode] = [],
            files: Int = 0,
            directories: Int = 0
        ) -> FileNode {
            FileNode(
                path: path,
                name: name,
                kind: .directory,
                logicalBytes: logical ?? allocated + allocated / 24,
                allocatedBytes: allocated,
                children: children,
                fileCount: files,
                directoryCount: directories
            )
        }

        let workspaces = directory(
            "Workspaces",
            path: "/Users/Sample/Workspaces",
            allocated: gb(154),
            children: [
                directory("Model Training", path: "/Users/Sample/Workspaces/Model Training", allocated: gb(58)),
                directory("Source Code", path: "/Users/Sample/Workspaces/Source Code", allocated: gb(36)),
                directory("Builds", path: "/Users/Sample/Workspaces/Builds", allocated: gb(32)),
                directory("Archives", path: "/Users/Sample/Workspaces/Archives", allocated: gb(28))
            ]
        )
        let caches = directory(
            "Caches",
            path: "/Users/Sample/Caches",
            allocated: gb(52),
            children: [
                directory("Browser", path: "/Users/Sample/Caches/Browser", allocated: gb(18)),
                directory("Package Managers", path: "/Users/Sample/Caches/Package Managers", allocated: gb(14)),
                directory("Model Cache", path: "/Users/Sample/Caches/Model Cache", allocated: gb(12)),
                directory("Thumbnails", path: "/Users/Sample/Caches/Thumbnails", allocated: gb(8))
            ]
        )
        let userLibrary = directory(
            "Library",
            path: "/Users/Sample/Library",
            allocated: gb(48),
            children: [
                directory("Application Support", path: "/Users/Sample/Library/Application Support", allocated: gb(19)),
                directory("Containers", path: "/Users/Sample/Library/Containers", allocated: gb(12)),
                directory("Developer", path: "/Users/Sample/Library/Developer", allocated: gb(10)),
                directory("Logs", path: "/Users/Sample/Library/Logs", allocated: gb(7))
            ]
        )
        let photos = directory(
            "Photos",
            path: "/Users/Sample/Photos",
            allocated: gb(42),
            children: [
                directory("Originals", path: "/Users/Sample/Photos/Originals", allocated: gb(22)),
                directory("Videos", path: "/Users/Sample/Photos/Videos", allocated: gb(12)),
                directory("Edits", path: "/Users/Sample/Photos/Edits", allocated: gb(8))
            ]
        )
        let downloads = directory(
            "Downloads",
            path: "/Users/Sample/Downloads",
            allocated: gb(28),
            children: [
                directory("Installers", path: "/Users/Sample/Downloads/Installers", allocated: gb(11)),
                directory("Archives", path: "/Users/Sample/Downloads/Archives", allocated: gb(9)),
                directory("Media", path: "/Users/Sample/Downloads/Media", allocated: gb(8))
            ]
        )
        let documents = directory(
            "Documents",
            path: "/Users/Sample/Documents",
            allocated: gb(24),
            children: [
                directory("Design", path: "/Users/Sample/Documents/Design", allocated: gb(10)),
                directory("Reports", path: "/Users/Sample/Documents/Reports", allocated: gb(8)),
                directory("Notes", path: "/Users/Sample/Documents/Notes", allocated: gb(6))
            ]
        )
        let movies = directory(
            "Movies",
            path: "/Users/Sample/Movies",
            allocated: gb(18),
            children: [
                directory("Clips", path: "/Users/Sample/Movies/Clips", allocated: gb(11)),
                directory("Exports", path: "/Users/Sample/Movies/Exports", allocated: gb(7))
            ]
        )
        let sampleUser = directory(
            "Sample",
            path: "/Users/Sample",
            allocated: gb(366),
            children: [workspaces, caches, userLibrary, photos, downloads, documents, movies]
        )
        let users = directory(
            "Users",
            path: "/Users",
            allocated: gb(378, 180),
            children: [
                sampleUser,
                directory("Shared", path: "/Users/Shared", allocated: gb(8)),
                directory("Guest", path: "/Users/Guest", allocated: gb(4, 180))
            ]
        )

        let applications = directory(
            "Applications",
            path: "/Applications",
            allocated: gb(17, 910),
            children: [
                directory("Creative", path: "/Applications/Creative", allocated: gb(6, 200), children: [
                    directory("Image Tools", path: "/Applications/Creative/Image Tools", allocated: gb(2, 700)),
                    directory("Video Tools", path: "/Applications/Creative/Video Tools", allocated: gb(2, 100)),
                    directory("Design Tools", path: "/Applications/Creative/Design Tools", allocated: gb(1, 400))
                ]),
                directory("Developer", path: "/Applications/Developer", allocated: gb(5, 400), children: [
                    directory("IDEs", path: "/Applications/Developer/IDEs", allocated: gb(3, 400)),
                    directory("Simulators", path: "/Applications/Developer/Simulators", allocated: gb(2))
                ]),
                directory("Productivity", path: "/Applications/Productivity", allocated: gb(4, 100)),
                directory("Utilities", path: "/Applications/Utilities", allocated: gb(2, 210))
            ]
        )
        let system = directory(
            "System",
            path: "/System",
            allocated: gb(17, 360),
            children: [
                directory("Library", path: "/System/Library", allocated: gb(10, 400), children: [
                    directory("Frameworks", path: "/System/Library/Frameworks", allocated: gb(4, 800)),
                    directory("Private Frameworks", path: "/System/Library/PrivateFrameworks", allocated: gb(3, 600)),
                    directory("Extensions", path: "/System/Library/Extensions", allocated: gb(2))
                ]),
                directory("CoreServices", path: "/System/Library/CoreServices", allocated: gb(4, 960)),
                directory("Assets", path: "/System/Library/AssetsV2", allocated: gb(2))
            ]
        )
        let privateDirectory = directory(
            "private",
            path: "/private",
            allocated: gb(11, 630),
            children: [
                directory("var", path: "/private/var", allocated: gb(10, 200), children: [
                    directory("folders", path: "/private/var/folders", allocated: gb(4, 800)),
                    directory("db", path: "/private/var/db", allocated: gb(3, 200)),
                    directory("log", path: "/private/var/log", allocated: gb(2, 200))
                ]),
                directory("etc", path: "/private/etc", allocated: gb(1, 430))
            ]
        )
        let opt = directory(
            "opt",
            path: "/opt",
            allocated: gb(8, 990),
            children: [
                directory("Local Tools", path: "/opt/local-tools", allocated: gb(4, 300)),
                directory("Packages", path: "/opt/packages", allocated: gb(2, 800)),
                directory("Runtimes", path: "/opt/runtimes", allocated: gb(1, 890))
            ]
        )
        let rootLibrary = directory(
            "Library",
            path: "/Library",
            allocated: gb(6, 600),
            children: [
                directory("Frameworks", path: "/Library/Frameworks", allocated: gb(3)),
                directory("Audio", path: "/Library/Audio", allocated: gb(2)),
                directory("Fonts", path: "/Library/Fonts", allocated: gb(1, 600))
            ]
        )
        let usr = directory(
            "usr",
            path: "/usr",
            allocated: gb(0, 821),
            children: [
                directory("local", path: "/usr/local", allocated: gb(0, 530)),
                directory("share", path: "/usr/share", allocated: gb(0, 291))
            ]
        )
        let topLevel = [
            users,
            applications,
            system,
            privateDirectory,
            opt,
            rootLibrary,
            usr,
            directory("bin", path: "/bin", allocated: gb(0, 4)),
            directory("sbin", path: "/sbin", allocated: gb(0, 3))
        ]
        let root = directory(
            "Macintosh HD",
            path: "/",
            allocated: gb(441, 500),
            logical: gb(460, 110),
            children: topLevel,
            files: 3_366_345,
            directories: 572_655
        )

        let skippedVolumes = [
            SkippedVolumeInfo(name: "dev", path: "/dev", kind: .system),
            SkippedVolumeInfo(name: "Hardware", path: "/System/Volumes/Hardware", kind: .system),
            SkippedVolumeInfo(name: "iSCPreboot", path: "/System/Volumes/iSCPreboot", kind: .system),
            SkippedVolumeInfo(name: "Preboot", path: "/System/Volumes/Preboot", kind: .system),
            SkippedVolumeInfo(name: "Recovery", path: "/System/Volumes/Recovery", kind: .system),
            SkippedVolumeInfo(name: "Update", path: "/System/Volumes/Update", kind: .system),
            SkippedVolumeInfo(name: "VM", path: "/System/Volumes/VM", kind: .system),
            SkippedVolumeInfo(name: "xART", path: "/System/Volumes/xarts", kind: .system),
            SkippedVolumeInfo(name: "Sample Backup", path: "/Volumes/Sample Backup", kind: .externalOrDiskImage),
            SkippedVolumeInfo(name: "Sample Installer", path: "/Volumes/Sample Installer", kind: .externalOrDiskImage),
            SkippedVolumeInfo(name: "Sample Network", path: "/Volumes/Sample Network", kind: .network)
        ]
        let issues = [
            ScanIssue(kind: .unreadableDirectory, path: "/Users/Sample/Library/Mail", errorCode: EPERM),
            ScanIssue(kind: .unreadableDirectory, path: "/Users/Sample/Library/Messages", errorCode: EACCES),
            ScanIssue(kind: .unreadableDirectory, path: "/System/Volumes/Data/.Spotlight-V100", errorCode: EPERM),
            ScanIssue(kind: .metadataUnavailable, path: "/private/var/folders/sample-item", errorCode: ENOENT)
        ]
        let largestFiles = [
            FileNode(path: "/Users/Sample/Workspaces/Models/model-checkpoint.bin", name: "model-checkpoint.bin", kind: .file, logicalBytes: gb(14), allocatedBytes: gb(14)),
            FileNode(path: "/Users/Sample/Photos/Videos/sample-film.mov", name: "sample-film.mov", kind: .file, logicalBytes: gb(9), allocatedBytes: gb(9)),
            FileNode(path: "/Users/Sample/Downloads/sample-archive.zip", name: "sample-archive.zip", kind: .file, logicalBytes: gb(6), allocatedBytes: gb(6))
        ]

        return DiskScanResult(
            root: root,
            rootURL: URL(fileURLWithPath: "/", isDirectory: true),
            volume: VolumeCapacity(
                name: "Macintosh HD",
                totalBytes: gb(494, 380),
                availableBytes: gb(38, 820)
            ),
            isVolumeRoot: true,
            elapsedSeconds: 325.7,
            diagnostics: ScanDiagnostics(
                unreadableDirectoryCount: 242,
                metadataErrorCount: 32,
                skippedVolumes: skippedVolumes,
                duplicateDirectoryCount: 88,
                duplicateFileCount: 1_204,
                issues: issues
            ),
            largestDirectories: topLevel,
            largestFiles: largestFiles
        )
    }

    private func previewProcessDiskRate(
        _ pid: Int32,
        _ name: String,
        _ read: Double,
        _ write: Double
    ) -> ProcessDiskIORate {
        let bundlePath = "/Applications/\(name).app"
        return ProcessDiskIORate(
            id: pid,
            processName: name,
            executablePath: "\(bundlePath)/Contents/MacOS/\(name)",
            applicationKey: "app:\(bundlePath)",
            applicationName: name,
            applicationBundlePath: bundlePath,
            bytesReadPerSecond: read,
            bytesWrittenPerSecond: write
        )
    }

    private func previewThumbnailRGBA(
        red: UInt8,
        green: UInt8,
        blue: UInt8
    ) -> Data {
        let size = 32
        var bytes = [UInt8](repeating: 255, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                let offset = (y * size + x) * 4
                let highlight = UInt8(min((x + y) * 2, 80))
                bytes[offset] = red &+ highlight / 4
                bytes[offset + 1] = green &+ highlight / 5
                bytes[offset + 2] = blue
                bytes[offset + 3] = 255
            }
        }
        return Data(bytes)
    }

    private func writePNG(_ image: NSBitmapImageRep, to url: URL) throws {
        guard let data = image.representation(using: .png, properties: [:]) else {
            throw FixtureError.cannotRenderView
        }
        try data.write(to: url)
    }

    private func writeFixtureImage(
        to url: URL,
        width: Int,
        height: Int,
        style: FixtureImageStyle,
        type: UTType,
        quality: Double = 1
    ) throws {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
            ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                | CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw FixtureError.cannotWriteImage
        }

        let canvas = CGRect(x: 0, y: 0, width: width, height: height)
        switch style {
        case .reference:
            context.setFillColor(CGColor(red: 0.96, green: 0.97, blue: 0.99, alpha: 1))
            context.fill(canvas)
            context.setFillColor(CGColor(red: 0.08, green: 0.42, blue: 0.93, alpha: 1))
            context.fill(CGRect(
                x: Double(width) * 0.08,
                y: Double(height) * 0.1,
                width: Double(width) * 0.4,
                height: Double(height) * 0.78
            ))
            context.setFillColor(CGColor(red: 1, green: 0.48, blue: 0.08, alpha: 1))
            context.fillEllipse(in: CGRect(
                x: Double(width) * 0.56,
                y: Double(height) * 0.18,
                width: Double(width) * 0.34,
                height: Double(height) * 0.55
            ))
            context.setStrokeColor(CGColor(gray: 0.12, alpha: 1))
            context.setLineWidth(CGFloat(width) * 0.035)
            context.move(to: CGPoint(x: Double(width) * 0.15, y: Double(height) * 0.2))
            context.addLine(to: CGPoint(x: Double(width) * 0.85, y: Double(height) * 0.82))
            context.strokePath()
        case .different:
            context.setFillColor(CGColor(red: 0.12, green: 0.72, blue: 0.32, alpha: 1))
            context.fill(canvas)
            context.setFillColor(CGColor(red: 0.52, green: 0.05, blue: 0.64, alpha: 1))
            for band in 0..<4 {
                context.fill(CGRect(
                    x: 0,
                    y: Double(height) * (Double(band) * 0.24 + 0.06),
                    width: Double(width),
                    height: Double(height) * 0.1
                ))
            }
        }

        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(
                url as CFURL,
                type.identifier as CFString,
                1,
                nil
              ) else {
            throw FixtureError.cannotWriteImage
        }
        let options = [
            kCGImageDestinationLossyCompressionQuality: quality
        ] as CFDictionary
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination) else {
            throw FixtureError.cannotWriteImage
        }
    }

    private func makeFixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskAnalyzerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func findNode(named name: String, in root: FileNode) -> FileNode? {
        var stack = [root]
        while let node = stack.popLast() {
            if node.name == name { return node }
            stack.append(contentsOf: node.children)
        }
        return nil
    }

    private func expectedTotals(at root: URL) throws -> (logical: Int64, allocated: Int64) {
        var logical: Int64 = 0
        var allocated: Int64 = 0
        var seen: Set<FileIdentity> = []

        func visit(_ url: URL) throws {
            guard let info = fileStat(at: url) else {
                throw FixtureError.cannotReadMetadata
            }
            logical += max(Int64(info.st_size), 0)

            let identity = FileIdentity(info)
            if seen.insert(identity).inserted {
                allocated += allocatedBytes(info)
            }

            guard (info.st_mode & S_IFMT) == S_IFDIR else { return }
            let entries = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil
            ).sorted { $0.path < $1.path }
            for entry in entries {
                try visit(entry)
            }
        }

        try visit(root)
        return (logical, allocated)
    }

    private func fileStat(at url: URL) -> stat? {
        var info = Darwin.stat()
        let result: Int32 = url.withUnsafeFileSystemRepresentation { pointer in
            guard let pointer else { return -1 }
            return Darwin.lstat(pointer, &info)
        }
        return result == 0 ? info : nil
    }

    private func allocatedBytes(_ info: stat) -> Int64 {
        max(Int64(info.st_blocks) * 512, 0)
    }

    private func duAllocatedBytes(at url: URL) throws -> Int64 {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        process.arguments = ["-sk", url.path]
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw FixtureError.duFailed }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8),
              let firstField = text.split(whereSeparator: \.isWhitespace).first,
              let kibibytes = Int64(firstField) else {
            throw FixtureError.duFailed
        }
        return kibibytes * 1_024
    }
}

private enum FixtureError: Error {
    case cannotCreateSparseFile
    case cannotReadMetadata
    case cannotChangePermissions
    case duFailed
    case cannotRenderView
    case cannotWriteImage
}

private enum FixtureImageStyle {
    case reference
    case different
}

private struct FileIdentity: Hashable {
    let device: UInt64
    let inode: UInt64

    init(_ info: stat) {
        device = UInt64(info.st_dev)
        inode = UInt64(info.st_ino)
    }
}
