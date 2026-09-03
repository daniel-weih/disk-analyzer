import SwiftUI

@MainActor
final class LargeFileScanController: ObservableObject {
    @Published var rootURL: URL
    @Published var thresholdMegabytes: Int
    @Published var selectedFileID: String?
    @Published private(set) var progress: LargeFileScanProgress?
    @Published private(set) var result: LargeFileScanResult?
    @Published private(set) var isScanning = false
    @Published private(set) var isCancelling = false
    @Published private(set) var errorMessage: String?

    private let scanner: LargeFileScanner
    private var scanTask: Task<Void, Never>?
    private var activeScanID: UUID?

    init(
        rootURL: URL = URL(fileURLWithPath: "/", isDirectory: true),
        thresholdMegabytes: Int = LargeFileThreshold.defaultMegabytes,
        result: LargeFileScanResult? = nil,
        scanner: LargeFileScanner = LargeFileScanner()
    ) {
        self.rootURL = rootURL
        self.thresholdMegabytes = LargeFileThreshold.clampedMegabytes(
            thresholdMegabytes
        )
        self.result = result
        self.scanner = scanner
    }

    var thresholdBytes: Int64 {
        LargeFileThreshold.bytes(forMegabytes: thresholdMegabytes)
    }

    func chooseDirectory() {
        guard !isScanning,
              let url = FinderBridge.chooseLargeFileScanDirectory(
                startingAt: rootURL
              ) else {
            return
        }
        rootURL = url.standardizedFileURL
        clearResult()
    }

    func invalidateResultIfConfigurationChanged() {
        guard !isScanning, let result else { return }
        let configuredThreshold = LargeFileThreshold.bytes(
            forMegabytes: thresholdMegabytes
        )
        if result.rootURL.standardizedFileURL != rootURL.standardizedFileURL
            || result.thresholdBytes != configuredThreshold {
            clearResult()
        }
    }

    func startScan() {
        let normalizedThreshold = LargeFileThreshold.clampedMegabytes(
            thresholdMegabytes
        )
        thresholdMegabytes = normalizedThreshold
        let thresholdBytes = LargeFileThreshold.bytes(
            forMegabytes: normalizedThreshold
        )
        let scanRootURL = rootURL.standardizedFileURL

        scanTask?.cancel()
        let scanID = UUID()
        activeScanID = scanID
        selectedFileID = nil
        result = nil
        progress = LargeFileScanProgress(
            scannedFileCount: 0,
            scannedDirectoryCount: 0,
            matchCount: 0,
            currentPath: scanRootURL.path,
            phase: .scanning
        )
        errorMessage = nil
        isScanning = true
        isCancelling = false

        scanTask = Task { [weak self] in
            guard let self else { return }
            let operation = await scanner.scan(
                from: scanRootURL,
                thresholdBytes: thresholdBytes
            )
            let progressTask = Task { @MainActor [weak self] in
                for await update in operation.stream {
                    guard let self, activeScanID == scanID else { return }
                    progress = update
                }
            }

            do {
                let scanResult = try await operation.task.value
                await progressTask.value
                guard activeScanID == scanID else { return }
                result = scanResult
                progress = nil
                isScanning = false
                isCancelling = false
                activeScanID = nil
                scanTask = nil
            } catch is CancellationError {
                progressTask.cancel()
                guard activeScanID == scanID else { return }
                progress = nil
                isScanning = false
                isCancelling = false
                activeScanID = nil
                scanTask = nil
            } catch {
                progressTask.cancel()
                guard activeScanID == scanID else { return }
                errorMessage = error.localizedDescription
                progress = nil
                isScanning = false
                isCancelling = false
                activeScanID = nil
                scanTask = nil
            }
        }
    }

    func cancel() {
        guard isScanning, activeScanID != nil else { return }
        activeScanID = nil
        scanTask?.cancel()
        scanTask = nil
        progress = nil
        isCancelling = true
        Task { [weak self] in
            guard let self else { return }
            await scanner.cancel()
            guard activeScanID == nil else { return }
            isScanning = false
            isCancelling = false
        }
    }

    func clearError() {
        errorMessage = nil
    }

    private func clearResult() {
        result = nil
        selectedFileID = nil
        errorMessage = nil
    }
}

struct LargeFileToolView: View {
    @ObservedObject var controller: LargeFileScanController
    @State private var searchText = ""

    private var filteredFiles: [LargeFileMatch] {
        guard let files = controller.result?.files else { return [] }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return files }
        return files.filter { file in
            file.url.lastPathComponent.localizedCaseInsensitiveContains(query)
                || file.url.path.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            configurationArea
            Divider()

            if let errorMessage = controller.errorMessage {
                errorBanner(errorMessage)
            }

            if controller.isScanning {
                scanningState
            } else if let result = controller.result {
                resultContent(result)
            } else {
                initialState
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: controller.thresholdMegabytes) { _ in
            controller.invalidateResultIfConfigurationChanged()
        }
        .onChange(of: controller.rootURL) { _ in
            controller.invalidateResultIfConfigurationChanged()
        }
    }

    private var configurationArea: some View {
        HStack(spacing: 12) {
            HStack(spacing: 9) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.text("large_files.scope"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(controller.rootURL.path)
                        .font(.callout.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(controller.rootURL.path)
                }
                Spacer(minLength: 8)
                Button(L10n.text("large_files.choose")) {
                    controller.chooseDirectory()
                }
                .buttonStyle(.bordered)
                .disabled(controller.isScanning)
            }
            .frame(maxWidth: .infinity)

            Divider()
                .frame(height: 34)

            HStack(spacing: 7) {
                Text(L10n.text("large_files.threshold.prefix"))
                    .fontWeight(.medium)

                TextField(
                    L10n.text("large_files.threshold.placeholder"),
                    value: $controller.thresholdMegabytes,
                    format: .number.grouping(.never)
                )
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 82)
                .disabled(controller.isScanning)

                Stepper(
                    "",
                    value: $controller.thresholdMegabytes,
                    in: LargeFileThreshold.minimumMegabytes...LargeFileThreshold.maximumMegabytes,
                    step: 50
                )
                .labelsHidden()
                .disabled(controller.isScanning)

                Text("MB")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: true, vertical: false)

            Divider()
                .frame(height: 34)

            if controller.isScanning {
                Button(
                    controller.isCancelling
                        ? L10n.text("large_files.cancelling")
                        : L10n.text("large_files.cancel")
                ) {
                    controller.cancel()
                }
                .buttonStyle(.bordered)
                .disabled(controller.isCancelling)
            } else {
                Button {
                    controller.startScan()
                } label: {
                    Label(
                        controller.result == nil
                            ? L10n.text("large_files.start")
                            : L10n.text("large_files.rescan"),
                        systemImage: "play.fill"
                    )
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [])
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var scanningState: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                ProgressView()
                    .progressViewStyle(.linear)

                HStack(spacing: 8) {
                    Text(L10n.text(
                        "large_files.scanning.counts",
                        (controller.progress?.scannedFileCount ?? 0).formatted(),
                        (controller.progress?.matchCount ?? 0).formatted()
                    ))
                    Spacer()
                    Text(controller.progress?.currentPath ?? controller.rootURL.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 560, alignment: .trailing)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)

            Spacer()

            VStack(spacing: 12) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(Color.accentColor)

                Text(L10n.text("large_files.scanning.title"))
                    .font(.headline)

                Text(L10n.text("large_files.scanning.detail"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }

    @ViewBuilder
    private func resultContent(_ result: LargeFileScanResult) -> some View {
        VStack(spacing: 0) {
            resultSummary(result)

            if result.diagnostics.hasCoverageWarning {
                coverageWarning(result.diagnostics)
            }
            if result.diagnostics.skippedVolumeCount > 0 {
                skippedVolumesNotice(result.diagnostics.skippedVolumeCount)
            }

            if result.files.isEmpty {
                emptyResult(result)
            } else {
                resultList
            }
        }
    }

    private func resultSummary(_ result: LargeFileScanResult) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text(
                    "large_files.result.summary",
                    result.files.count.formatted(),
                    SizeFormatter.shared.string(fromByteCount: result.thresholdBytes)
                ))
                .font(.headline)

                Text(L10n.text(
                    "large_files.result.stats",
                    result.scannedFileCount.formatted(),
                    result.scannedDirectoryCount.formatted(),
                    result.elapsedSeconds.formatted(
                        .number.precision(.fractionLength(2))
                    )
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            if !result.files.isEmpty {
                TextField(L10n.text("large_files.search"), text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var resultList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(L10n.text("large_files.column.file"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(L10n.text("large_files.column.logical"))
                    .frame(width: 112, alignment: .trailing)
                Text(L10n.text("large_files.column.allocated"))
                    .frame(width: 112, alignment: .trailing)
                Color.clear.frame(width: 28, height: 1)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 18)
            .padding(.vertical, 7)
            .background(Color.primary.opacity(0.035))

            Divider()

            if filteredFiles.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text(L10n.text("large_files.search.empty"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredFiles) { file in
                            LargeFileResultRow(
                                file: file,
                                isSelected: controller.selectedFileID == file.id,
                                onSelect: { controller.selectedFileID = file.id },
                                onReveal: { FinderBridge.reveal(file.url) }
                            )

                            Divider()
                                .padding(.leading, 56)
                        }
                    }
                }
            }
        }
    }

    private var initialState: some View {
        VStack(spacing: 13) {
            Image(systemName: "externaldrive.badge.magnifyingglass")
                .font(.system(size: 40, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 82, height: 82)
                .background(Color.secondary.opacity(0.07), in: Circle())

            Text(L10n.text("large_files.empty.title"))
                .font(.title3.bold())

            Text(L10n.text(
                "large_files.empty.detail",
                controller.thresholdMegabytes.formatted()
            ))
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func emptyResult(_ result: LargeFileScanResult) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 38))
                .foregroundStyle(.green)
            Text(L10n.text("large_files.result.empty.title"))
                .font(.headline)
            Text(L10n.text(
                "large_files.result.empty.detail",
                SizeFormatter.shared.string(fromByteCount: result.thresholdBytes)
            ))
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func coverageWarning(_ diagnostics: LargeFileScanDiagnostics) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(L10n.text(
                "large_files.coverage.warning",
                diagnostics.unreadableDirectoryCount.formatted(),
                diagnostics.metadataErrorCount.formatted()
            ))
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 18)
        .padding(.vertical, 7)
        .background(Color.orange.opacity(0.09))
    }

    private func skippedVolumesNotice(_ count: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "externaldrive")
                .foregroundStyle(Color.accentColor)
            Text(L10n.text("large_files.volumes.skipped", count.formatted()))
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 18)
        .padding(.vertical, 7)
        .background(Color.blue.opacity(0.07))
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message)
                .lineLimit(2)
            Spacer()
            Button(L10n.text("common.ok")) {
                controller.clearError()
            }
            .buttonStyle(.link)
        }
        .font(.callout)
        .foregroundStyle(.red)
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.08))
    }
}

private struct LargeFileResultRow: View {
    let file: LargeFileMatch
    let isSelected: Bool
    let onSelect: () -> Void
    let onReveal: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.fill")
                .font(.system(size: 18))
                .foregroundStyle(Color.accentColor)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(file.url.lastPathComponent)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(file.url.deletingLastPathComponent().path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(SizeFormatter.shared.string(fromByteCount: file.logicalBytes))
                .font(.callout.weight(.semibold).monospacedDigit())
                .frame(width: 112, alignment: .trailing)

            Text(SizeFormatter.shared.string(fromByteCount: file.allocatedBytes))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 112, alignment: .trailing)

            Button(action: onReveal) {
                Image(systemName: "finder")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)
            .help(L10n.text("common.reveal_finder"))
            .opacity(isHovering || isSelected ? 1 : 0.58)
        }
        .padding(.horizontal, 18)
        .frame(height: 56)
        .background(isSelected ? Color.accentColor.opacity(0.11) : .clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onReveal)
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button(L10n.text("common.reveal_finder"), action: onReveal)
        }
    }
}
