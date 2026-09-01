import AppKit
import SwiftUI

enum RankingScope: String, CaseIterable, Identifiable {
    case current
    case directories
    case files

    var id: String { rawValue }

    var title: String {
        switch self {
        case .current: return L10n.text("scope.current")
        case .directories: return L10n.text("scope.directories")
        case .files: return L10n.text("scope.files")
        }
    }
}

enum CleanupPhase: Equatable, Sendable {
    case idle
    case countdown(Int)
    case moving(completed: Int, total: Int)

    var isActive: Bool { self != .idle }

    var isMoving: Bool {
        if case .moving = self { return true }
        return false
    }
}

private struct TrashMover: @unchecked Sendable {
    let operation: (URL) throws -> TrashMoveOutcome

    func callAsFunction(_ url: URL) throws -> TrashMoveOutcome {
        try operation(url)
    }
}

private struct CleanupWorkResult: @unchecked Sendable {
    let update: SnapshotTrashUpdate?
    let wasAlreadyMissing: Bool
    let errorDescription: String?
}

@MainActor
final class ScanController: ObservableObject {
    @Published var progress: ScanProgress = .idle
    @Published var result: DiskScanResult?
    @Published var navigationPath: [FileNode] = []
    @Published var sortOption: SortOption = .sizeDescending
    @Published var metric: SizeMetric = .allocated
    @Published var rankingScope: RankingScope = .current
    @Published var searchText = ""
    @Published var selectedRankingNodeID: String?
    @Published private(set) var cleanupItems: [FileNode] = []
    @Published private(set) var cleanupPhase: CleanupPhase = .idle
    @Published var isCleanupCollectorExpanded = false
    @Published var alertMessage: String?
    @Published var noticeMessage: String?
    @Published private(set) var resultFreshness: ResultFreshness = .scanBacked
    @Published var isShowingHome = false
    @Published private var selectedScanURL: URL?

    private let scanner = DiskScanner()
    private let trashMover: TrashMover
    private var scanTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    private var activeScanID: UUID?
    private var suppressedPaths: Set<String> = []

    init(
        moveToTrash: @escaping (URL) throws -> TrashMoveOutcome = FinderBridge.moveToTrash
    ) {
        trashMover = TrashMover(operation: moveToTrash)
    }

    var displayRoot: FileNode? {
        navigationPath.last ?? result?.root
    }

    var currentScanURL: URL? {
        result?.rootURL ?? selectedScanURL
    }

    var isPresentingResult: Bool {
        result != nil && !isShowingHome
    }

    var toolbarScanURL: URL? {
        isShowingHome ? nil : currentScanURL
    }

    var isScanning: Bool {
        if case .scanning = progress.phase { return true }
        return false
    }

    var cleanupNodeIDs: Set<String> {
        Set(cleanupItems.map(\.id))
    }

    func cleanupBytes(for metric: SizeMetric) -> Int64 {
        cleanupItems.reduce(Int64(0)) { $0 + $1.bytes(for: metric) }
    }

    var breadcrumbNodes: [FileNode] {
        guard let root = result?.root else { return [] }
        return [root] + navigationPath
    }

    var rankedNodes: [FileNode] {
        let source: [FileNode]
        switch rankingScope {
        case .current:
            source = displayRoot?.children ?? []
        case .directories:
            source = result?.largestDirectories ?? []
        case .files:
            source = result?.largestFiles ?? []
        }

        let currentNodes = source.filter { node in
            guard let path = node.path else { return true }
            return !suppressedPaths.contains(path)
        }
        let filtered: [FileNode]
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            filtered = currentNodes
        } else {
            let query = searchText.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
            filtered = currentNodes.filter { node in
                let candidate = "\(node.name) \(node.path ?? "")".folding(
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: .current
                )
                return candidate.contains(query)
            }
        }

        return Array(filtered.sorted(by: sortComparator).prefix(100))
    }

    func scanStartupDisk() {
        startScan(from: URL(fileURLWithPath: "/", isDirectory: true))
    }

    func scanHomeDirectory() {
        startScan(from: FileManager.default.homeDirectoryForCurrentUser)
    }

    func chooseDirectory() {
        let startURL = currentScanURL ?? FileManager.default.homeDirectoryForCurrentUser
        guard let url = FinderBridge.chooseDirectory(startingAt: startURL) else { return }
        startScan(from: url)
    }

    func rescan(completionNotice: String? = nil) {
        guard let url = result?.rootURL else { return }
        startScan(
            from: url,
            completionNotice: completionNotice,
            preservingExistingResult: true
        )
    }

    func startScan(
        from url: URL,
        completionNotice: String? = nil,
        preservingExistingResult: Bool = false
    ) {
        guard !cleanupPhase.isActive else {
            alertMessage = L10n.text("collector.busy")
            return
        }
        guard cleanupItems.isEmpty else {
            alertMessage = L10n.text("collector.finish_before_scan")
            return
        }
        scanTask?.cancel()
        let scanID = UUID()
        let previousNavigationPaths = navigationPath.compactMap(\.path)
        let previousFreshness = resultFreshness
        activeScanID = scanID
        isShowingHome = false
        selectedScanURL = url
        if !preservingExistingResult {
            navigationPath = []
            result = nil
            resultFreshness = .scanBacked
            suppressedPaths.removeAll()
            selectedRankingNodeID = nil
        }
        dismissNotice()
        progress = ScanProgress(
            scannedItems: 0,
            scannedFiles: 0,
            scannedDirectories: 0,
            allocatedBytes: 0,
            currentPath: url.path,
            phase: .scanning
        )

        scanTask = Task { [weak self] in
            guard let self else { return }
            await scanner.cancel()
            guard !Task.isCancelled, activeScanID == scanID else { return }

            let operation = await scanner.scan(from: url)
            for await update in operation.stream {
                guard !Task.isCancelled, activeScanID == scanID else { break }
                progress = update
            }

            guard !Task.isCancelled, activeScanID == scanID else { return }
            do {
                let scanResult = try await operation.task.value
                guard activeScanID == scanID else { return }
                result = scanResult
                resultFreshness = .scanBacked
                suppressedPaths.removeAll()
                if preservingExistingResult {
                    navigationPath = reboundNavigationPath(
                        previousPaths: previousNavigationPaths,
                        root: scanResult.root
                    )
                    reconcileRankingSelection()
                } else {
                    rankingScope = .current
                    searchText = ""
                }
                if let completionNotice {
                    presentNotice(completionNotice)
                }
                progress = ScanProgress(
                    scannedItems: scanResult.root.fileCount + scanResult.root.directoryCount,
                    scannedFiles: scanResult.root.fileCount,
                    scannedDirectories: scanResult.root.directoryCount,
                    allocatedBytes: scanResult.root.allocatedBytes,
                    currentPath: scanResult.rootURL.path,
                    phase: .done
                )
            } catch is CancellationError {
                if activeScanID == scanID {
                    if preservingExistingResult, let existingResult = result {
                        resultFreshness = previousFreshness
                        publishDoneProgress(for: existingResult)
                    } else {
                        progress = .idle
                    }
                }
            } catch {
                if activeScanID == scanID {
                    alertMessage = error.localizedDescription
                    if preservingExistingResult, let existingResult = result {
                        resultFreshness = previousFreshness
                        publishDoneProgress(for: existingResult)
                    } else {
                        progress = ScanProgress(
                            scannedItems: 0,
                            scannedFiles: 0,
                            scannedDirectories: 0,
                            allocatedBytes: 0,
                            currentPath: url.path,
                            phase: .failed(error.localizedDescription)
                        )
                    }
                }
            }
        }
    }

    func cancelScan() {
        activeScanID = nil
        scanTask?.cancel()
        scanTask = nil
        Task { await scanner.cancel() }
        if let result {
            publishDoneProgress(for: result)
        } else {
            progress = .idle
        }
    }

    func showHome() {
        guard !isScanning, !cleanupPhase.isActive else { return }
        isShowingHome = true
    }

    func showLatestResult() {
        guard result != nil else { return }
        isShowingHome = false
    }

    func drillDown(into node: FileNode) {
        selectedRankingNodeID = nil
        guard node.isDirectory else {
            FinderBridge.reveal(node.url)
            return
        }
        guard let root = result?.root else { return }
        if let path = pathToNode(node.id, from: root) {
            navigationPath = Array(path.dropFirst())
        } else {
            navigationPath.append(node)
        }
        rankingScope = .current
        searchText = ""
    }

    func navigate(to node: FileNode) {
        selectedRankingNodeID = nil
        guard let root = result?.root else { return }
        if node.id == root.id {
            navigationPath = []
            return
        }
        if let index = navigationPath.firstIndex(where: { $0.id == node.id }) {
            navigationPath = Array(navigationPath.prefix(through: index))
        }
    }

    func navigateUp() {
        guard !navigationPath.isEmpty else { return }
        navigationPath.removeLast()
        selectedRankingNodeID = nil
    }

    func reveal(_ node: FileNode) {
        FinderBridge.reveal(node.url)
    }

    func addToCleanup(_ node: FileNode) {
        guard !isScanning, !cleanupPhase.isActive,
              node.canMoveToTrash,
              node.id != result?.root.id,
              let nodePath = node.path else {
            alertMessage = L10n.text("trash.protected")
            return
        }

        if cleanupItems.contains(where: { $0.id == node.id }) { return }
        if let containingItem = cleanupItems.first(where: {
            guard let existingPath = $0.path else { return false }
            return Self.isPath(nodePath, insideOrEqualTo: existingPath)
        }) {
            presentNotice(L10n.text("collector.already_included", containingItem.name))
            return
        }

        cleanupItems.removeAll { existing in
            guard let existingPath = existing.path else { return false }
            return Self.isPath(existingPath, insideOrEqualTo: nodePath)
        }
        cleanupItems.append(node)
        alertMessage = nil
    }

    func removeFromCleanup(_ node: FileNode) {
        guard !cleanupPhase.isActive else { return }
        cleanupItems.removeAll { $0.id == node.id }
        if cleanupItems.isEmpty { isCleanupCollectorExpanded = false }
    }

    func clearCleanup() {
        guard !cleanupPhase.isActive else { return }
        cleanupItems.removeAll()
        isCleanupCollectorExpanded = false
    }

    func beginCleanupCountdown(seconds: Int = 5) {
        guard !isScanning, cleanupPhase == .idle, !cleanupItems.isEmpty else { return }
        let initialSeconds = max(seconds, 1)
        cleanupPhase = .countdown(initialSeconds)
        cleanupTask?.cancel()
        cleanupTask = Task { [weak self] in
            guard let self else { return }
            for remaining in stride(from: initialSeconds, through: 1, by: -1) {
                guard !Task.isCancelled else { return }
                cleanupPhase = .countdown(remaining)
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            await moveCollectedItemsToTrash()
        }
    }

    func cancelCleanupCountdown() {
        guard case .countdown = cleanupPhase else { return }
        cleanupTask?.cancel()
        cleanupTask = nil
        cleanupPhase = .idle
        if cleanupItems.isEmpty { isCleanupCollectorExpanded = false }
    }

    func moveCollectedItemsToTrash() async {
        guard !isScanning, !cleanupPhase.isMoving,
              !cleanupItems.isEmpty, result != nil else { return }

        cleanupTask = nil
        let itemsToMove = cleanupItems
        let total = itemsToMove.count
        var successfulNames: [String] = []
        var missingCount = 0
        var firstError: String?
        cleanupPhase = .moving(completed: 0, total: total)

        for (index, node) in itemsToMove.enumerated() {
            guard let url = node.url, let currentResult = result else { continue }
            let mover = trashMover
            let work = await Task.detached(priority: .userInitiated) {
                do {
                    let outcome = try mover(url)
                    switch outcome {
                    case .moved(let destinationURL):
                        return CleanupWorkResult(
                            update: SnapshotTrashReconciler.moved(
                                node,
                                destinationURL: destinationURL,
                                in: currentResult
                            ),
                            wasAlreadyMissing: false,
                            errorDescription: nil
                        )
                    case .alreadyMissing:
                        return CleanupWorkResult(
                            update: SnapshotTrashReconciler.alreadyMissing(
                                node,
                                in: currentResult
                            ),
                            wasAlreadyMissing: true,
                            errorDescription: nil
                        )
                    }
                } catch {
                    return CleanupWorkResult(
                        update: nil,
                        wasAlreadyMissing: false,
                        errorDescription: error.localizedDescription
                    )
                }
            }.value

            if let errorDescription = work.errorDescription {
                firstError = firstError ?? errorDescription
            } else {
                alertMessage = nil
                suppressedPaths.insert(url.standardizedFileURL.path)
                applyTrashUpdate(work.update)
                if work.wasAlreadyMissing {
                    resultFreshness = .needsVerification
                    missingCount += 1
                }
                cleanupItems.removeAll { $0.id == node.id }
                successfulNames.append(node.name)
            }
            cleanupPhase = .moving(completed: index + 1, total: total)
            await Task.yield()
        }

        cleanupPhase = .idle
        if let firstError {
            alertMessage = L10n.text("trash.failed", firstError)
        }
        if !successfulNames.isEmpty {
            let message: String
            if successfulNames.count == 1, let name = successfulNames.first {
                message = L10n.text(
                    missingCount == 1 ? "collector.success.missing" : "collector.success.single",
                    name
                )
            } else {
                message = L10n.text("collector.success.multiple", successfulNames.count.formatted())
            }
            presentNotice(message)
        }
    }

    private func applyTrashUpdate(_ update: SnapshotTrashUpdate?) {
        guard let update else {
            resultFreshness = .needsVerification
            return
        }

        let wasAlreadyStale = resultFreshness.needsVerification
        let previousNavigationPaths = navigationPath.compactMap(\.path)
        result = update.result
        resultFreshness = wasAlreadyStale ? .needsVerification : update.freshness
        navigationPath = reboundNavigationPath(
            previousPaths: previousNavigationPaths,
            root: update.result.root,
            sourcePath: update.sourcePath,
            destinationPath: update.destinationPath
        )
        reconcileRankingSelection()
        publishDoneProgress(for: update.result)
    }

    private func reconcileRankingSelection() {
        guard let selectedRankingNodeID else { return }
        if !rankedNodes.contains(where: { $0.id == selectedRankingNodeID }) {
            self.selectedRankingNodeID = nil
        }
    }

    private func publishDoneProgress(for result: DiskScanResult) {
        progress = ScanProgress(
            scannedItems: result.root.fileCount + result.root.directoryCount,
            scannedFiles: result.root.fileCount,
            scannedDirectories: result.root.directoryCount,
            allocatedBytes: result.root.allocatedBytes,
            currentPath: result.rootURL.path,
            phase: .done
        )
    }

    func dismissNotice() {
        noticeTask?.cancel()
        noticeTask = nil
        noticeMessage = nil
    }

    private func presentNotice(_ message: String) {
        noticeTask?.cancel()
        noticeMessage = message
        noticeTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 4_000_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.noticeMessage = nil
            self?.noticeTask = nil
        }
    }

    private func reboundNavigationPath(
        previousPaths: [String],
        root: FileNode,
        sourcePath: String,
        destinationPath: String?
    ) -> [FileNode] {
        for previousPath in previousPaths.reversed() {
            guard let mappedPath = SnapshotTrashReconciler.mappedPath(
                previousPath,
                sourcePath: sourcePath,
                destinationPath: destinationPath
            ), let path = pathToNode(path: mappedPath, from: root) else {
                continue
            }
            return Array(path.dropFirst())
        }
        return []
    }

    private func reboundNavigationPath(
        previousPaths: [String],
        root: FileNode
    ) -> [FileNode] {
        for previousPath in previousPaths.reversed() {
            if let path = pathToNode(path: previousPath, from: root) {
                return Array(path.dropFirst())
            }
        }
        return []
    }

    private var sortComparator: (FileNode, FileNode) -> Bool {
        switch sortOption {
        case .sizeDescending:
            return {
                let left = $0.bytes(for: self.metric)
                let right = $1.bytes(for: self.metric)
                return left == right
                    ? $0.name.localizedStandardCompare($1.name) == .orderedAscending
                    : left > right
            }
        case .sizeAscending:
            return {
                let left = $0.bytes(for: self.metric)
                let right = $1.bytes(for: self.metric)
                return left == right
                    ? $0.name.localizedStandardCompare($1.name) == .orderedAscending
                    : left < right
            }
        case .nameAscending:
            return { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .nameDescending:
            return { $0.name.localizedStandardCompare($1.name) == .orderedDescending }
        }
    }

    private static func isPath(_ path: String, insideOrEqualTo rootPath: String) -> Bool {
        let pathComponents = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        let rootComponents = URL(fileURLWithPath: rootPath)
            .standardizedFileURL.pathComponents
        guard pathComponents.count >= rootComponents.count else { return false }
        return zip(pathComponents, rootComponents).allSatisfy(==)
    }

    private func pathToNode(_ id: String, from root: FileNode) -> [FileNode]? {
        var stack: [(node: FileNode, path: [FileNode])] = [(root, [root])]
        while let current = stack.popLast() {
            if current.node.id == id { return current.path }
            for child in current.node.children.reversed() where child.isDirectory {
                stack.append((child, current.path + [child]))
            }
        }
        return nil
    }

    private func pathToNode(path targetPath: String, from root: FileNode) -> [FileNode]? {
        var stack: [(node: FileNode, path: [FileNode])] = [(root, [root])]
        while let current = stack.popLast() {
            if current.node.path == targetPath { return current.path }
            for child in current.node.children.reversed() where child.isDirectory {
                stack.append((child, current.path + [child]))
            }
        }
        return nil
    }
}

private enum PendingScanAction {
    case startupDisk
    case homeDirectory
    case chooseDirectory
    case rescan
}

struct ContentView: View {
    @StateObject private var controller = ScanController()
    @AppStorage("fullDiskAccessOnboardingCompleted")
    private var fullDiskAccessOnboardingCompleted = false
    @AppStorage("fullDiskAccessConfirmedCodeIdentity")
    private var fullDiskAccessConfirmedCodeIdentity = ""
    @AppStorage(AppLanguage.storageKey)
    private var appLanguageCode = AppLanguage.simplifiedChinese.rawValue
    @State private var isPermissionGuidePresented = false
    @State private var isLanguageSettingsPresented = false
    @State private var hasPresentedInitialPermissionGuide = false
    @State private var pendingScanAction: PendingScanAction?
    @State private var fullDiskAccessProbeResult = FullDiskAccessProbe.check()
    @State private var didAttemptPermissionCheck = false

    private var fullDiskAccessConfirmationStatus: FullDiskAccessConfirmationStatus {
        .evaluate(
            probeResult: fullDiskAccessProbeResult,
            onboardingCompleted: fullDiskAccessOnboardingCompleted,
            confirmedCodeIdentity: fullDiskAccessConfirmedCodeIdentity,
            currentCodeIdentity: AppCodeIdentity.current
        )
    }

    private var appLanguage: AppLanguage {
        AppLanguage(rawValue: appLanguageCode) ?? .simplifiedChinese
    }

    var body: some View {
        VStack(spacing: 0) {
            ScanControlView(
                controller: controller,
                onShowHome: controller.showHome,
                onShowLatestResult: controller.showLatestResult,
                onScanStartupDisk: { requestScan(.startupDisk) },
                onScanHomeDirectory: { requestScan(.homeDirectory) },
                onChooseDirectory: { requestScan(.chooseDirectory) },
                onRescan: { requestScan(.rescan) },
                onShowSettings: { isLanguageSettingsPresented = true }
            )
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.bar)

            Divider()

            if let result = controller.result, controller.isPresentingResult {
                ResultsView(
                    controller: controller,
                    result: result,
                    onRescan: { requestScan(.rescan) }
                )
            } else {
                EmptyStateView(
                    controller: controller,
                    fullDiskAccessConfirmationStatus: fullDiskAccessConfirmationStatus,
                    onShowPermissionGuide: showPermissionGuide,
                    onScanStartupDisk: { requestScan(.startupDisk) },
                    onScanHomeDirectory: { requestScan(.homeDirectory) },
                    onChooseDirectory: { requestScan(.chooseDirectory) }
                )
            }
        }
        .id(appLanguageCode)
        .environment(\.locale, appLanguage.locale)
        .background(WindowTitleConfigurator(title: L10n.text("app.title")))
        .frame(minWidth: 1_040, minHeight: 680)
        .onAppear {
            if refreshFullDiskAccessStatus().isGranted { return }
            guard fullDiskAccessConfirmationStatus != .confirmed,
                  !hasPresentedInitialPermissionGuide else { return }
            hasPresentedInitialPermissionGuide = true
            showPermissionGuide()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            finishPermissionSetupIfGranted()
        }
        .sheet(
            isPresented: $isPermissionGuidePresented,
            onDismiss: { pendingScanAction = nil }
        ) {
            FullDiskAccessGuideView(
                hasPendingScan: pendingScanAction != nil,
                confirmationStatus: fullDiskAccessConfirmationStatus,
                probeResult: fullDiskAccessProbeResult,
                didAttemptPermissionCheck: didAttemptPermissionCheck,
                onOpenSettings: beginFullDiskAccessSetup,
                onRevealApplication: revealApplicationInFinder,
                onCheckPermission: checkFullDiskAccess,
                onContinueWithoutPermission: continueWithoutPermission,
                onCancel: cancelPermissionGuide
            )
        }
        .sheet(isPresented: $isLanguageSettingsPresented) {
            LanguageSettingsView(languageCode: $appLanguageCode)
                .id(appLanguageCode)
                .environment(\.locale, appLanguage.locale)
        }
        .alert(
            L10n.text("alert.title"),
            isPresented: Binding(
                get: { controller.alertMessage != nil },
                set: { if !$0 { controller.alertMessage = nil } }
            )
        ) {
            Button(L10n.text("common.ok")) { controller.alertMessage = nil }
        } message: {
            Text(controller.alertMessage ?? "")
        }
    }

    private func showPermissionGuide() {
        pendingScanAction = nil
        didAttemptPermissionCheck = false
        refreshFullDiskAccessStatus()
        isPermissionGuidePresented = true
    }

    private func requestScan(_ action: PendingScanAction) {
        guard !refreshFullDiskAccessStatus().isGranted else {
            perform(action)
            return
        }
        pendingScanAction = action
        didAttemptPermissionCheck = false
        refreshFullDiskAccessStatus()
        isPermissionGuidePresented = true
    }

    private func beginFullDiskAccessSetup() {
        didAttemptPermissionCheck = true
        FinderBridge.openFullDiskAccessSettings()
    }

    @discardableResult
    private func refreshFullDiskAccessStatus() -> FullDiskAccessProbeResult {
        let result = FullDiskAccessProbe.check()
        fullDiskAccessProbeResult = result
        if result.isGranted {
            fullDiskAccessOnboardingCompleted = true
            fullDiskAccessConfirmedCodeIdentity = AppCodeIdentity.current?.fingerprint ?? ""
        }
        return result
    }

    private func checkFullDiskAccess() {
        didAttemptPermissionCheck = true
        finishPermissionSetupIfGranted()
    }

    private func finishPermissionSetupIfGranted() {
        guard refreshFullDiskAccessStatus().isGranted else { return }
        let action = pendingScanAction
        pendingScanAction = nil
        isPermissionGuidePresented = false
        if let action { perform(action) }
    }

    private func revealApplicationInFinder() {
        FinderBridge.reveal(Bundle.main.bundleURL)
    }

    private func continueWithoutPermission() {
        let action = pendingScanAction
        pendingScanAction = nil
        isPermissionGuidePresented = false
        if let action { perform(action) }
    }

    private func cancelPermissionGuide() {
        pendingScanAction = nil
        isPermissionGuidePresented = false
    }

    private func perform(_ action: PendingScanAction) {
        switch action {
        case .startupDisk:
            controller.scanStartupDisk()
        case .homeDirectory:
            controller.scanHomeDirectory()
        case .chooseDirectory:
            controller.chooseDirectory()
        case .rescan:
            controller.rescan()
        }
    }
}

struct ResultsView: View {
    @ObservedObject var controller: ScanController
    let result: DiskScanResult
    let onRescan: () -> Void
    let initialSunburstSegments: [SunburstSegment]

    init(
        controller: ScanController,
        result: DiskScanResult,
        onRescan: @escaping () -> Void,
        initialSunburstSegments: [SunburstSegment] = []
    ) {
        self.controller = controller
        self.result = result
        self.onRescan = onRescan
        self.initialSunburstSegments = initialSunburstSegments
    }

    var body: some View {
        VStack(spacing: 0) {
            ResultSummaryView(
                result: result,
                metric: controller.metric,
                freshness: controller.resultFreshness
            )
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

            if result.isVolumeRoot && !controller.resultFreshness.needsVerification {
                VolumeReconciliationView(result: result)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            if result.diagnostics.hasCoverageWarning {
                ScanCoverageBannerView(diagnostics: result.diagnostics)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            if result.diagnostics.skippedVolumeCount > 0 {
                SkippedVolumesBannerView(diagnostics: result.diagnostics)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            if controller.resultFreshness.needsVerification {
                FreshnessBannerView(onRescan: onRescan)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            Divider()

            if let displayRoot = controller.displayRoot {
                HSplitView {
                    VStack(spacing: 0) {
                        NavigationBar(controller: controller)
                        Divider()

                        SunburstView(
                            node: displayRoot,
                            metric: controller.metric,
                            onDrillDown: controller.drillDown,
                            onRevealInFinder: controller.reveal,
                            initialSegments: ObjectIdentifier(displayRoot)
                                == ObjectIdentifier(result.root)
                                ? initialSunburstSegments
                                : []
                        )
                        .id(SunburstPresentationIdentity(
                            root: ObjectIdentifier(displayRoot),
                            metric: controller.metric.rawValue
                        ))
                        .padding(14)
                    }
                    .frame(minWidth: 560)

                    RankingListView(
                        nodes: controller.rankedNodes,
                        displayRoot: displayRoot,
                        metric: controller.metric,
                        scope: $controller.rankingScope,
                        sortOption: $controller.sortOption,
                        searchText: $controller.searchText,
                        selectedNodeID: $controller.selectedRankingNodeID,
                        cleanupNodeIDs: controller.cleanupNodeIDs,
                        isCleanupActive: controller.cleanupPhase.isActive,
                        onRevealInFinder: controller.reveal,
                        onDrillDown: controller.drillDown,
                        onAddToCleanup: controller.addToCleanup,
                        onRemoveFromCleanup: controller.removeFromCleanup
                    )
                    .frame(minWidth: 360, idealWidth: 420, maxWidth: 520)
                }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            VStack(alignment: .trailing, spacing: 10) {
                if let notice = controller.noticeMessage {
                    CleanupToastView(
                        message: notice,
                        onDismiss: controller.dismissNotice
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                if !controller.cleanupItems.isEmpty {
                    CleanupCollectorView(controller: controller)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(16)
            .animation(.easeInOut(duration: 0.2), value: controller.noticeMessage)
            .animation(.easeInOut(duration: 0.2), value: controller.cleanupItems.map(\.id))
        }
    }
}

private struct SunburstPresentationIdentity: Hashable {
    let root: ObjectIdentifier
    let metric: String
}

private struct NavigationBar: View {
    @ObservedObject var controller: ScanController

    var body: some View {
        HStack(spacing: 10) {
            Button(action: controller.navigateUp) {
                Image(systemName: "chevron.left")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)
            .disabled(controller.navigationPath.isEmpty)
            .help(L10n.text("navigation.up.help"))

            BreadcrumbView(
                path: controller.breadcrumbNodes,
                onNavigate: controller.navigate
            )

            Spacer()

            Text(controller.metric.shortExplanation)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .help(controller.metric.shortExplanation)
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }
}

private struct ResultSummaryView: View {
    let result: DiskScanResult
    let metric: SizeMetric
    let freshness: ResultFreshness

    var body: some View {
        let otherMetric: SizeMetric = metric == .allocated ? .logical : .allocated

        HStack(spacing: 10) {
            SummaryCard(
                title: metric.title,
                value: result.root.formattedSize(for: metric),
                detail: L10n.text("summary.current_metric"),
                icon: "scope",
                tint: .indigo
            )
            SummaryCard(
                title: otherMetric.title,
                value: result.root.formattedSize(for: otherMetric),
                detail: L10n.text(
                    otherMetric == .allocated
                        ? "summary.allocated_detail"
                        : "summary.logical_detail"
                ),
                icon: "internaldrive",
                tint: .blue
            )
            SummaryCard(
                title: L10n.text("summary.item_count"),
                value: result.root.fileCount.formatted(),
                detail: L10n.text(
                    "summary.directory_count",
                    result.root.directoryCount.formatted()
                ),
                icon: "doc.on.doc",
                tint: .teal
            )

            if let volume = result.volume {
                SummaryCard(
                    title: volume.name,
                    value: SizeFormatter.shared.string(fromByteCount: volume.availableBytes),
                    detail: L10n.text(
                        "summary.volume_available",
                        SizeFormatter.shared.string(fromByteCount: volume.totalBytes)
                    ),
                    icon: "chart.pie.fill",
                    tint: .orange
                )
            }

            SummaryCard(
                title: L10n.text("summary.elapsed"),
                value: L10n.text(
                    "summary.seconds",
                    result.elapsedSeconds.formatted(.number.precision(.fractionLength(1)))
                ),
                detail: L10n.text(
                    freshness.needsVerification
                        ? "summary.needs_refresh"
                        : result.diagnostics.hasCoverageWarning
                            ? "summary.coverage_warning"
                            : "summary.complete"
                ),
                icon: freshness.needsVerification
                    ? "exclamationmark.triangle.fill"
                    : "timer",
                tint: freshness.needsVerification || result.diagnostics.hasCoverageWarning
                    ? .orange
                    : .green
            )
        }
    }
}

private struct VolumeReconciliationView: View {
    let result: DiskScanResult

    private var difference: Int64 {
        result.volumeReconciliationDifference ?? 0
    }

    private var message: String {
        guard let volume = result.volume else { return "" }
        let used = SizeFormatter.shared.string(fromByteCount: volume.usedBytes)
        let scanned = SizeFormatter.shared.string(fromByteCount: result.scannedAllocatedBytes)
        if difference >= 0 {
            let remaining = SizeFormatter.shared.string(fromByteCount: difference)
            return L10n.text(
                "volume.reconciliation.positive",
                used,
                scanned,
                remaining
            )
        }
        let overlap = SizeFormatter.shared.string(fromByteCount: abs(difference))
        return L10n.text(
            "volume.reconciliation.negative",
            scanned,
            used,
            overlap
        )
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "equal.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text("volume.reconciliation.title"))
                    .font(.system(size: 11, weight: .semibold))
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(9)
        .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct SummaryCard: View {
    let title: String
    let value: String
    let detail: String
    let icon: String
    let tint: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(value)
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(detail)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(nsColor: .controlBackgroundColor).opacity(0.75),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 0.5)
        }
    }
}

struct EmptyStateView: View {
    @ObservedObject var controller: ScanController
    let fullDiskAccessConfirmationStatus: FullDiskAccessConfirmationStatus
    let onShowPermissionGuide: () -> Void
    let onScanStartupDisk: () -> Void
    let onScanHomeDirectory: () -> Void
    let onChooseDirectory: () -> Void
    var homeDirectoryPath = FileManager.default.homeDirectoryForCurrentUser.path

    var body: some View {
        VStack(spacing: 22) {
            Spacer()

            ZStack {
                Circle()
                    .fill(
                        AngularGradient(
                            colors: [.blue, .cyan, .green, .yellow, .orange, .pink, .purple, .blue],
                            center: .center
                        )
                    )
                    .frame(width: 118, height: 118)
                Circle()
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .frame(width: 54, height: 54)
                Image(systemName: "internaldrive.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .shadow(color: .blue.opacity(0.16), radius: 18, y: 8)

            VStack(spacing: 8) {
                Text(L10n.text(
                    controller.isScanning ? "home.scanning.title" : "home.title"
                ))
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                Text(
                    controller.isScanning
                        ? controller.progress.currentPath
                        : L10n.text("home.detail")
                )
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 620)
            }

            if !controller.isScanning {
                FullDiskAccessSetupCard(
                    status: fullDiskAccessConfirmationStatus,
                    onShowGuide: onShowPermissionGuide
                )
                .frame(maxWidth: 720)
            }

            if controller.isScanning {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.small)

                    HStack(spacing: 16) {
                        Label(
                            L10n.text(
                                "home.progress.items",
                                controller.progress.scannedItems.formatted()
                            ),
                            systemImage: "doc.on.doc"
                        )
                        Label(
                            SizeFormatter.shared.string(
                                fromByteCount: controller.progress.allocatedBytes
                            ),
                            systemImage: "internaldrive"
                        )
                    }
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)

                    Button(L10n.text("home.cancel_scan"), action: controller.cancelScan)
                        .buttonStyle(.bordered)
                }
            } else {
                HStack(spacing: 12) {
                    ScanChoiceButton(
                        title: L10n.text("home.startup.title"),
                        subtitle: L10n.text("home.startup.detail"),
                        icon: "internaldrive.fill",
                        tint: .blue,
                        action: onScanStartupDisk
                    )
                    ScanChoiceButton(
                        title: L10n.text("home.user.title"),
                        subtitle: homeDirectoryPath,
                        icon: "person.crop.circle",
                        tint: .teal,
                        action: onScanHomeDirectory
                    )
                    ScanChoiceButton(
                        title: L10n.text("home.other.title"),
                        subtitle: L10n.text("home.other.detail"),
                        icon: "folder.badge.plus",
                        tint: .purple,
                        action: onChooseDirectory
                    )
                }
                .frame(maxWidth: 720)
            }

            Label(
                L10n.text("home.safety"),
                systemImage: "checkmark.shield"
            )
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)

            Spacer()
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ScanChoiceButton: View {
    let title: String
    let subtitle: String
    let icon: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .leading)
            .background(
                Color(nsColor: .controlBackgroundColor).opacity(0.75),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(tint.opacity(0.22), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct FreshnessBannerView: View {
    let onRescan: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(L10n.text("freshness.needs_verification"))
                .font(.system(size: 11))
            Spacer()
            Button(L10n.text("common.rescan"), action: onRescan)
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .controlSize(.small)
        }
        .padding(9)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct CleanupCollectorView: View {
    @ObservedObject var controller: ScanController

    private var listHeight: CGFloat {
        min(CGFloat(controller.cleanupItems.count) * 46, 150)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "tray.full.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.text("collector.title"))
                        .font(.system(size: 12, weight: .semibold))
                    Text(L10n.text(
                        "collector.summary",
                        controller.cleanupItems.count.formatted(),
                        SizeFormatter.shared.string(
                            fromByteCount: controller.cleanupBytes(for: controller.metric)
                        )
                    ))
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    controller.isCleanupCollectorExpanded.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Text(L10n.text(
                            controller.isCleanupCollectorExpanded
                                ? "collector.hide"
                                : "common.view"
                        ))
                        Image(systemName: controller.isCleanupCollectorExpanded
                            ? "chevron.down"
                            : "chevron.up")
                    }
                }
                .buttonStyle(.borderless)
                .controlSize(.small)

                if controller.isCleanupCollectorExpanded {
                    Button(L10n.text("collector.clear"), action: controller.clearCleanup)
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .disabled(controller.cleanupPhase.isActive)
                }
            }

            if controller.isCleanupCollectorExpanded {
                Text(L10n.text("collector.review_detail"))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(controller.cleanupItems) { node in
                            CleanupCollectorRowView(
                                node: node,
                                metric: controller.metric,
                                isCleanupActive: controller.cleanupPhase.isActive,
                                onReveal: { controller.reveal(node) },
                                onRemove: { controller.removeFromCleanup(node) }
                            )

                            if node.id != controller.cleanupItems.last?.id {
                                Divider()
                            }
                        }
                    }
                }
                .frame(height: listHeight)
            }

            Divider()

            switch controller.cleanupPhase {
            case .idle:
                HStack {
                    Text(L10n.text("collector.recoverable"))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(action: { controller.beginCleanupCountdown() }) {
                        Label(L10n.text("collector.move_action"), systemImage: "trash")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.small)
                }
            case .countdown(let seconds):
                HStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundStyle(.orange)
                    Text(L10n.text("collector.countdown", seconds.formatted()))
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    Spacer()
                    Button(L10n.text("common.cancel"), action: controller.cancelCleanupCountdown)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            case .moving(let completed, let total):
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(L10n.text(
                        "collector.moving",
                        min(completed + 1, total).formatted(),
                        total.formatted()
                    ))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    Spacer()
                    Text(L10n.text("collector.keep_open"))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .frame(width: 390)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.16), radius: 16, y: 6)
        .animation(
            .easeInOut(duration: 0.18),
            value: controller.isCleanupCollectorExpanded
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("collector.title"))
    }
}

private struct CleanupCollectorRowView: View {
    let node: FileNode
    let metric: SizeMetric
    let isCleanupActive: Bool
    let onReveal: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: node.isDirectory ? "folder.fill" : "doc.fill")
                .foregroundStyle(.orange)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(node.name)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(node.path ?? "")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 6)
            Text(node.formattedSize(for: metric))
                .font(.system(size: 10, weight: .medium).monospacedDigit())
            Button(action: onReveal) {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help(L10n.text("common.reveal_finder"))
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(L10n.text("collector.remove_item"))
            .disabled(isCleanupActive)
        }
        .frame(height: 44)
    }
}

private struct CleanupToastView: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(message)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(2)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: 390)
        .background(.regularMaterial, in: Capsule())
        .overlay {
            Capsule()
                .stroke(Color.green.opacity(0.32), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
