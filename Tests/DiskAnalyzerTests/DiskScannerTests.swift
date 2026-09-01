import Darwin
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import DiskAnalyzer

@Suite("Disk scanner accuracy")
struct DiskScannerTests {
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
        #expect(L10n.text("app.title", language: .simplifiedChinese) == "磁盘空间分析")
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
    @Test("Home navigation controls remain visible at the minimum window width")
    func homeNavigationControlsRemainVisible() throws {
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

        controller.showHome()

        let homeToolbar = navigationToolbar(for: controller)
        let homeImage = try render(
            view: homeToolbar,
            size: CGSize(width: 1_040, height: 60)
        )

        #expect(resultImage.pixelsWide >= 1_040)
        #expect(homeImage.pixelsWide >= 1_040)

        if let captureDirectory = ProcessInfo.processInfo.environment["DISK_ANALYZER_CAPTURE_UI"] {
            let directory = URL(fileURLWithPath: captureDirectory)
            try writePNG(resultImage, to: directory.appendingPathComponent("result-toolbar.png"))
            try writePNG(homeImage, to: directory.appendingPathComponent("home-toolbar.png"))
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
            ScanControlView(
                controller: controller,
                onShowHome: {},
                onShowLatestResult: {},
                onScanStartupDisk: {},
                onScanHomeDirectory: {},
                onChooseDirectory: {},
                onRescan: {},
                onShowSettings: {}
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
        controller.result = makeRepositoryPreviewResult()
        controller.showHome()

        let preview = VStack(spacing: 0) {
            ScanControlView(
                controller: controller,
                onShowHome: {},
                onShowLatestResult: {},
                onScanStartupDisk: {},
                onScanHomeDirectory: {},
                onChooseDirectory: {},
                onRescan: {},
                onShowSettings: {}
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)

            Divider()
            EmptyStateView(
                controller: controller,
                fullDiskAccessConfirmationStatus: .confirmed,
                onShowPermissionGuide: {},
                onScanStartupDisk: {},
                onScanHomeDirectory: {},
                onChooseDirectory: {},
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
            onShowHome: controller.showHome,
            onShowLatestResult: controller.showLatestResult,
            onScanStartupDisk: {},
            onScanHomeDirectory: {},
            onChooseDirectory: {},
            onRescan: {},
            onShowSettings: {}
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

    private func writePNG(_ image: NSBitmapImageRep, to url: URL) throws {
        guard let data = image.representation(using: .png, properties: [:]) else {
            throw FixtureError.cannotRenderView
        }
        try data.write(to: url)
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
}

private struct FileIdentity: Hashable {
    let device: UInt64
    let inode: UInt64

    init(_ info: stat) {
        device = UInt64(info.st_dev)
        inode = UInt64(info.st_ino)
    }
}
