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

@MainActor
final class ScanController: ObservableObject {
    @Published var progress: ScanProgress = .idle
    @Published var result: DiskScanResult?
    @Published var navigationPath: [FileNode] = []
    @Published var sortOption: SortOption = .sizeDescending
    @Published var metric: SizeMetric = .allocated
    @Published var rankingScope: RankingScope = .current
    @Published var searchText = ""
    @Published var pendingTrashNode: FileNode?
    @Published var alertMessage: String?
    @Published var noticeMessage: String?
    @Published var isShowingHome = false
    @Published private var selectedScanURL: URL?

    private let scanner = DiskScanner()
    private var scanTask: Task<Void, Never>?
    private var activeScanID: UUID?

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

        let filtered: [FileNode]
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            filtered = source
        } else {
            let query = searchText.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
            filtered = source.filter { node in
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

    func rescan() {
        guard let url = result?.rootURL else { return }
        startScan(from: url)
    }

    func startScan(from url: URL) {
        scanTask?.cancel()
        let scanID = UUID()
        activeScanID = scanID
        isShowingHome = false
        selectedScanURL = url
        navigationPath = []
        result = nil
        noticeMessage = nil
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
                rankingScope = .current
                searchText = ""
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
                    progress = .idle
                }
            } catch {
                if activeScanID == scanID {
                    alertMessage = error.localizedDescription
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

    func cancelScan() {
        activeScanID = nil
        scanTask?.cancel()
        scanTask = nil
        Task { await scanner.cancel() }
        progress = .idle
    }

    func showHome() {
        guard !isScanning else { return }
        isShowingHome = true
    }

    func showLatestResult() {
        guard result != nil else { return }
        isShowingHome = false
    }

    func drillDown(into node: FileNode) {
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
    }

    func reveal(_ node: FileNode) {
        FinderBridge.reveal(node.url)
    }

    func requestMoveToTrash(_ node: FileNode) {
        guard node.canMoveToTrash else {
            alertMessage = L10n.text("trash.protected")
            return
        }
        pendingTrashNode = node
    }

    func confirmMoveToTrash(_ node: FileNode) {
        guard let url = node.url, node.canMoveToTrash else { return }
        do {
            try FinderBridge.moveToTrash(url)
            noticeMessage = L10n.text("trash.moved", node.name)
        } catch {
            alertMessage = L10n.text("trash.failed", error.localizedDescription)
        }
        pendingTrashNode = nil
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
        .confirmationDialog(
            L10n.text("trash.dialog.title"),
            isPresented: Binding(
                get: { controller.pendingTrashNode != nil },
                set: { if !$0 { controller.pendingTrashNode = nil } }
            ),
            titleVisibility: .visible,
            presenting: controller.pendingTrashNode
        ) { node in
            Button(L10n.text("trash.dialog.action"), role: .destructive) {
                controller.confirmMoveToTrash(node)
            }
            Button(L10n.text("common.cancel"), role: .cancel) {
                controller.pendingTrashNode = nil
            }
        } message: { node in
            Text(L10n.text("trash.dialog.message", node.name))
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
            ResultSummaryView(result: result, metric: controller.metric)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

            if result.isVolumeRoot {
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

            if let notice = controller.noticeMessage {
                NoticeBannerView(
                    message: notice,
                    onRescan: onRescan,
                    onDismiss: { controller.noticeMessage = nil }
                )
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
                            initialSegments: initialSunburstSegments
                        )
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
                        onRevealInFinder: controller.reveal,
                        onDrillDown: controller.drillDown,
                        onMoveToTrash: controller.requestMoveToTrash
                    )
                    .frame(minWidth: 360, idealWidth: 420, maxWidth: 520)
                }
            }
        }
    }
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
                    result.diagnostics.hasCoverageWarning
                        ? "summary.coverage_warning"
                        : "summary.complete"
                ),
                icon: "timer",
                tint: result.diagnostics.hasCoverageWarning ? .orange : .green
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

private struct NoticeBannerView: View {
    let message: String
    let onRescan: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(message)
                .font(.system(size: 11))
            Spacer()
            Button(L10n.text("common.rescan"), action: onRescan)
                .buttonStyle(.bordered)
                .controlSize(.small)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
        }
        .padding(9)
        .background(Color.green.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
