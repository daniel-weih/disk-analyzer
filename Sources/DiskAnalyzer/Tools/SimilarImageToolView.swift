import CoreGraphics
import SwiftUI

@MainActor
final class SimilarImageScanController: ObservableObject {
    @Published var rootURL: URL
    @Published var comparisonMethod: SimilarImageComparisonMethod
    @Published var similarityPercent: Int
    @Published var visionMaximumDistance: Double
    @Published var selectedImageID: String?
    @Published private(set) var progress: SimilarImageScanProgress?
    @Published private(set) var result: SimilarImageScanResult?
    @Published private(set) var isScanning = false
    @Published private(set) var isCancelling = false
    @Published private(set) var errorMessage: String?

    private let scanner: SimilarImageScanner
    private var scanTask: Task<Void, Never>?
    private var activeScanID: UUID?

    init(
        rootURL: URL = URL(fileURLWithPath: "/", isDirectory: true),
        comparisonMethod: SimilarImageComparisonMethod = .perceptualDuplicate,
        similarityPercent: Int = ImageSimilarityThreshold.defaultPercent,
        visionMaximumDistance: Double = VisionFeatureDistanceThreshold.defaultValue,
        result: SimilarImageScanResult? = nil,
        scanner: SimilarImageScanner = SimilarImageScanner()
    ) {
        let configuration = result?.configuration ?? SimilarImageScanConfiguration(
            method: comparisonMethod,
            perceptualSimilarityPercent: similarityPercent,
            visionMaximumDistance: visionMaximumDistance
        )
        self.rootURL = rootURL
        self.comparisonMethod = configuration.method
        self.similarityPercent = configuration.perceptualSimilarityPercent
        self.visionMaximumDistance = configuration.visionMaximumDistance
        self.result = result
        self.scanner = scanner
    }

    var configuration: SimilarImageScanConfiguration {
        SimilarImageScanConfiguration(
            method: comparisonMethod,
            perceptualSimilarityPercent: similarityPercent,
            visionMaximumDistance: visionMaximumDistance
        )
    }

    func chooseDirectory() {
        guard !isScanning,
              let url = FinderBridge.chooseSimilarImageScanDirectory(
                startingAt: rootURL
              ) else {
            return
        }
        rootURL = url.standardizedFileURL
        clearResult()
    }

    func invalidateResultIfConfigurationChanged() {
        guard !isScanning, let result else { return }
        if result.rootURL.standardizedFileURL != rootURL.standardizedFileURL
            || !result.configuration.hasSameActiveThreshold(as: configuration) {
            clearResult()
        }
    }

    func startScan() {
        let normalizedPercent = ImageSimilarityThreshold.clampedPercent(
            similarityPercent
        )
        let normalizedVisionDistance = VisionFeatureDistanceThreshold.clamped(
            visionMaximumDistance
        )
        similarityPercent = normalizedPercent
        visionMaximumDistance = normalizedVisionDistance
        let scanConfiguration = SimilarImageScanConfiguration(
            method: comparisonMethod,
            perceptualSimilarityPercent: normalizedPercent,
            visionMaximumDistance: normalizedVisionDistance
        )
        let scanRootURL = rootURL.standardizedFileURL

        scanTask?.cancel()
        let scanID = UUID()
        activeScanID = scanID
        selectedImageID = nil
        result = nil
        progress = SimilarImageScanProgress(
            scannedFileCount: 0,
            candidateImageCount: 0,
            analyzedImageCount: 0,
            comparedImageCount: 0,
            groupCount: 0,
            currentPath: scanRootURL.path,
            phase: .scanningFiles
        )
        errorMessage = nil
        isScanning = true
        isCancelling = false

        scanTask = Task { [weak self] in
            guard let self else { return }
            let operation = await scanner.scan(
                from: scanRootURL,
                configuration: scanConfiguration
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
        selectedImageID = nil
        errorMessage = nil
    }
}

struct SimilarImageToolView: View {
    @ObservedObject var controller: SimilarImageScanController
    @State private var searchText = ""

    private var filteredGroups: [SimilarImageGroup] {
        guard let groups = controller.result?.groups else { return [] }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return groups }
        return groups.filter { group in
            group.members.contains { member in
                member.item.url.lastPathComponent.localizedCaseInsensitiveContains(query)
                    || member.item.url.path.localizedCaseInsensitiveContains(query)
            }
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
        .onChange(of: controller.similarityPercent) { _ in
            controller.invalidateResultIfConfigurationChanged()
        }
        .onChange(of: controller.visionMaximumDistance) { _ in
            controller.invalidateResultIfConfigurationChanged()
        }
        .onChange(of: controller.comparisonMethod) { _ in
            controller.invalidateResultIfConfigurationChanged()
        }
        .onChange(of: controller.rootURL) { _ in
            controller.invalidateResultIfConfigurationChanged()
        }
    }

    private var configurationArea: some View {
        VStack(spacing: 9) {
            HStack(spacing: 12) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.text("similar_images.scope"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(controller.rootURL.path)
                        .font(.callout.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(controller.rootURL.path)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button(L10n.text("similar_images.choose")) {
                    controller.chooseDirectory()
                }
                .buttonStyle(.bordered)
                .disabled(controller.isScanning)

                Divider()
                    .frame(height: 30)

                scanActionButton
            }

            HStack(spacing: 10) {
                Text(L10n.text("similar_images.method.label"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Picker("", selection: $controller.comparisonMethod) {
                    Text(L10n.text("similar_images.method.perceptual"))
                        .tag(SimilarImageComparisonMethod.perceptualDuplicate)
                    Text(L10n.text("similar_images.method.vision"))
                        .tag(SimilarImageComparisonMethod.appleVision)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 250)
                .disabled(controller.isScanning)
                .accessibilityLabel(L10n.text("similar_images.method.label"))

                Divider()
                    .frame(height: 24)

                activeThresholdControl

                Spacer(minLength: 8)

                Text(activeMethodHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(activeMethodHint)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.bar)
    }

    @ViewBuilder
    private var activeThresholdControl: some View {
        switch controller.comparisonMethod {
        case .perceptualDuplicate:
            HStack(spacing: 6) {
                Text(L10n.text("similar_images.threshold.prefix"))
                    .fontWeight(.medium)
                TextField(
                    L10n.text("similar_images.threshold.placeholder"),
                    value: $controller.similarityPercent,
                    format: .number.grouping(.never)
                )
                .frame(width: 52)
                Stepper(
                    "",
                    value: $controller.similarityPercent,
                    in: ImageSimilarityThreshold.minimumPercent...ImageSimilarityThreshold.maximumPercent,
                    step: 1
                )
                .labelsHidden()
                Text("%")
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: true, vertical: false)
            .disabled(controller.isScanning)

        case .appleVision:
            HStack(spacing: 6) {
                Text(L10n.text("similar_images.vision.threshold.prefix"))
                    .fontWeight(.medium)
                TextField(
                    L10n.text("similar_images.vision.threshold.placeholder"),
                    value: visionSimilarityPercent,
                    format: .number.grouping(.never)
                )
                .frame(width: 52)
                Stepper(
                    "",
                    value: visionSimilarityPercent,
                    in: VisionFeatureSimilarityScale.minimumPercent...VisionFeatureSimilarityScale.maximumPercent,
                    step: 1
                )
                .labelsHidden()
                Text("%")
                    .foregroundStyle(.secondary)
                Text(L10n.text("similar_images.vision.threshold.hint"))
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: true, vertical: false)
            .disabled(controller.isScanning)
        }
    }

    private var visionSimilarityPercent: Binding<Int> {
        Binding(
            get: {
                VisionFeatureSimilarityScale.similarityPercent(
                    forDistance: controller.visionMaximumDistance
                )
            },
            set: { newValue in
                controller.visionMaximumDistance =
                    VisionFeatureSimilarityScale.distance(
                        forSimilarityPercent: newValue
                    )
            }
        )
    }

    @ViewBuilder
    private var scanActionButton: some View {
        if controller.isScanning {
            Button(
                controller.isCancelling
                    ? L10n.text("similar_images.cancelling")
                    : L10n.text("similar_images.cancel")
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
                        ? L10n.text("similar_images.start")
                        : L10n.text("similar_images.rescan"),
                    systemImage: "play.fill"
                )
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: [])
        }
    }

    private var activeMethodHint: String {
        switch controller.comparisonMethod {
        case .perceptualDuplicate:
            L10n.text("similar_images.method.perceptual.hint")
        case .appleVision:
            L10n.text("similar_images.method.vision.hint")
        }
    }

    private var scanningState: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                if controller.progress?.phase == .comparing {
                    ProgressView(
                        value: Double(controller.progress?.comparedImageCount ?? 0),
                        total: Double(max(controller.progress?.analyzedImageCount ?? 0, 1))
                    )
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                }

                HStack(spacing: 8) {
                    if controller.progress?.phase == .comparing {
                        Text(L10n.text(
                            "similar_images.comparing.counts",
                            (controller.progress?.comparedImageCount ?? 0).formatted(),
                            (controller.progress?.analyzedImageCount ?? 0).formatted(),
                            (controller.progress?.groupCount ?? 0).formatted()
                        ))
                    } else {
                        Text(L10n.text(
                            "similar_images.scanning.counts",
                            (controller.progress?.scannedFileCount ?? 0).formatted(),
                            (controller.progress?.candidateImageCount ?? 0).formatted(),
                            (controller.progress?.analyzedImageCount ?? 0).formatted()
                        ))
                    }
                    Spacer()
                    Text(controller.progress?.currentPath ?? controller.rootURL.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 520, alignment: .trailing)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)

            Spacer()

            VStack(spacing: 12) {
                Image(systemName: "photo.stack")
                    .font(.system(size: 36, weight: .medium))
                    .foregroundStyle(Color.accentColor)

                Text(
                    controller.progress?.phase == .comparing
                        ? L10n.text("similar_images.comparing.title")
                        : L10n.text("similar_images.scanning.title")
                )
                .font(.headline)

                Text(
                    controller.progress?.phase == .comparing
                        ? L10n.text("similar_images.comparing.detail")
                        : L10n.text("similar_images.scanning.detail")
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }

            Spacer()
        }
    }

    @ViewBuilder
    private func resultContent(_ result: SimilarImageScanResult) -> some View {
        VStack(spacing: 0) {
            resultSummary(result)

            if result.diagnostics.hasCoverageWarning {
                coverageWarning(result.diagnostics)
            }
            if result.diagnostics.skippedVolumeCount > 0 {
                skippedVolumesNotice(result.diagnostics.skippedVolumeCount)
            }

            if result.groups.isEmpty {
                emptyResult(result)
            } else if filteredGroups.isEmpty {
                emptySearchResult
            } else {
                groupList
            }
        }
    }

    private func resultSummary(_ result: SimilarImageScanResult) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(L10n.text(
                        "similar_images.result.summary",
                        result.groups.count.formatted(),
                        result.groupedImageCount.formatted()
                    ))
                    .font(.headline)

                    Text(resultCriteria(result.configuration))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.09), in: Capsule())
                }

                Text(L10n.text(
                    "similar_images.result.stats",
                    result.scannedFileCount.formatted(),
                    result.candidateImageCount.formatted(),
                    result.analyzedImageCount.formatted(),
                    result.elapsedSeconds.formatted(
                        .number.precision(.fractionLength(2))
                    )
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            if !result.groups.isEmpty {
                TextField(L10n.text("similar_images.search"), text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 250)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    private var groupList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(Array(filteredGroups.enumerated()), id: \.element.id) { index, group in
                    SimilarImageGroupView(
                        index: index + 1,
                        group: group,
                        selectedImageID: $controller.selectedImageID
                    )
                }
            }
            .padding(18)
        }
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.36))
    }

    private var initialState: some View {
        VStack(spacing: 13) {
            Image(systemName: "photo.stack")
                .font(.system(size: 38, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 82, height: 82)
                .background(Color.secondary.opacity(0.07), in: Circle())

            Text(L10n.text("similar_images.empty.title"))
                .font(.title3.bold())

            Text(initialDetail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Label(
                L10n.text("similar_images.empty.note"),
                systemImage: "lock.shield"
            )
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func emptyResult(_ result: SimilarImageScanResult) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 38))
                .foregroundStyle(.green)
            Text(L10n.text("similar_images.result.empty.title"))
                .font(.headline)
            Text(emptyResultDetail(result.configuration))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var initialDetail: String {
        switch controller.comparisonMethod {
        case .perceptualDuplicate:
            L10n.text(
                "similar_images.empty.detail",
                controller.similarityPercent.formatted()
            )
        case .appleVision:
            L10n.text(
                "similar_images.empty.vision.detail",
                VisionFeatureSimilarityScale.similarityPercent(
                    forDistance: controller.visionMaximumDistance
                ).formatted()
            )
        }
    }

    private func emptyResultDetail(_ configuration: SimilarImageScanConfiguration) -> String {
        switch configuration.method {
        case .perceptualDuplicate:
            L10n.text(
                "similar_images.result.empty.detail",
                configuration.perceptualSimilarityPercent.formatted()
            )
        case .appleVision:
            L10n.text(
                "similar_images.result.empty.vision.detail",
                configuration.visionSimilarityPercent.formatted()
            )
        }
    }

    private func resultCriteria(_ configuration: SimilarImageScanConfiguration) -> String {
        switch configuration.method {
        case .perceptualDuplicate:
            L10n.text(
                "similar_images.result.criteria.perceptual",
                configuration.perceptualSimilarityPercent.formatted()
            )
        case .appleVision:
            L10n.text(
                "similar_images.result.criteria.vision",
                configuration.visionSimilarityPercent.formatted()
            )
        }
    }

    private var emptySearchResult: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(L10n.text("similar_images.search.empty"))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func coverageWarning(_ diagnostics: SimilarImageScanDiagnostics) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(L10n.text(
                "similar_images.coverage.warning",
                diagnostics.unreadableDirectoryCount.formatted(),
                diagnostics.metadataErrorCount.formatted(),
                diagnostics.imageDecodeErrorCount.formatted()
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
            Text(L10n.text("similar_images.volumes.skipped", count.formatted()))
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

private struct SimilarImageGroupView: View {
    let index: Int
    let group: SimilarImageGroup
    @Binding var selectedImageID: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.up.fill")
                    .foregroundStyle(Color.accentColor)
                Text(L10n.text("similar_images.group.title", index.formatted()))
                    .font(.callout.weight(.semibold))
                Text(L10n.text(
                    "similar_images.group.count",
                    group.members.count.formatted()
                ))
                .font(.caption)
                .foregroundStyle(.secondary)

                Spacer()

                groupScoreSummary
                    .foregroundStyle(.secondary)
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(SizeFormatter.shared.string(fromByteCount: group.totalBytes))
                    .monospacedDigit()
            }
            .font(.caption)
            .padding(.horizontal, 14)
            .frame(height: 38)
            .background(Color.primary.opacity(0.035))

            Divider()

            ForEach(group.members) { member in
                SimilarImageResultRow(
                    member: member,
                    isSelected: selectedImageID == member.id,
                    onSelect: { selectedImageID = member.id },
                    onReveal: { FinderBridge.reveal(member.item.url) }
                )

                if member.id != group.members.last?.id {
                    Divider()
                        .padding(.leading, 76)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var groupScoreSummary: some View {
        if let minimum = group.minimumPerceptualSimilarity {
            Text(L10n.text(
                "similar_images.group.minimum",
                Int((minimum * 100).rounded()).formatted()
            ))
        } else if let minimum = group.minimumVisionSimilarityPercent {
            Text(L10n.text(
                "similar_images.group.minimum_vision_similarity",
                minimum.formatted()
            ))
        }
    }
}

private struct SimilarImageResultRow: View {
    let member: SimilarImageMember
    let isSelected: Bool
    let onSelect: () -> Void
    let onReveal: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 12) {
            SimilarImageThumbnail(data: member.item.thumbnailRGBA)
                .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(member.item.url.lastPathComponent)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)

                    if member.isReference {
                        Text(L10n.text("similar_images.reference"))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Color.accentColor.opacity(0.1),
                                in: Capsule()
                            )
                    }
                }

                Text(member.item.url.deletingLastPathComponent().path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text("\(member.item.pixelWidth) × \(member.item.pixelHeight)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .trailing)

            Text(SizeFormatter.shared.string(fromByteCount: member.item.logicalBytes))
                .font(.callout.monospacedDigit())
                .frame(width: 92, alignment: .trailing)

            Text(scoreText)
                .font(.callout.weight(.semibold).monospacedDigit())
                .foregroundStyle(member.isReference ? .secondary : Color.accentColor)
                .frame(width: 82, alignment: .trailing)
                .help(scoreHelp)

            Button(action: onReveal) {
                Image(systemName: "finder")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)
            .help(L10n.text("common.reveal_finder"))
            .opacity(isHovering || isSelected ? 1 : 0.58)
        }
        .padding(.horizontal, 14)
        .frame(height: 62)
        .background(isSelected ? Color.accentColor.opacity(0.11) : .clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onReveal)
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button(L10n.text("common.reveal_finder"), action: onReveal)
        }
    }

    private var scoreText: String {
        guard !member.isReference else { return "—" }
        switch member.score {
        case let .perceptualSimilarity(value):
            return L10n.text(
                "similar_images.similarity.value",
                Int((value * 100).rounded()).formatted()
            )
        case let .visionDistance(value):
            return L10n.text(
                "similar_images.vision.similarity.value",
                VisionFeatureSimilarityScale.similarityPercent(
                    forDistance: value
                ).formatted()
            )
        }
    }

    private var scoreHelp: String {
        if member.isReference {
            return L10n.text("similar_images.reference")
        }
        switch member.score {
        case .perceptualSimilarity:
            return L10n.text("similar_images.similarity.help")
        case .visionDistance:
            return L10n.text("similar_images.vision.similarity.help")
        }
    }
}

private struct SimilarImageThumbnail: View {
    let data: Data

    var body: some View {
        Group {
            if let image = makeImage() {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private func makeImage() -> CGImage? {
        let size = 32
        guard data.count == size * size * 4,
              let provider = CGDataProvider(data: data as CFData) else {
            return nil
        }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
            ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(
            rawValue: CGBitmapInfo.byteOrder32Big.rawValue
                | CGImageAlphaInfo.premultipliedLast.rawValue
        )
        return CGImage(
            width: size,
            height: size,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: size * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
}
