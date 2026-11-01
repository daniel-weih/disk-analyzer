import AppKit
import SwiftUI

@MainActor
final class VideoScanController: ObservableObject {
    @Published var rootURL: URL
    @Published var method: VideoComparisonMethod
    @Published var similarityPercent: Int
    @Published private(set) var result: VideoScanResult?
    @Published private(set) var progress: VideoScanProgress?
    @Published private(set) var isScanning = false
    @Published private(set) var isCancelling = false
    @Published private(set) var errorMessage: String?
    private let scanner = VideoDuplicateScanner()
    private var scanTask: Task<Void, Never>?

    init(rootURL: URL = URL(fileURLWithPath: "/", isDirectory: true),
         result: VideoScanResult? = nil) {
        self.rootURL = result?.rootURL ?? rootURL
        self.result = result
        method = result?.configuration.method ?? .exact
        similarityPercent = result?.configuration.similarityPercent ?? VideoScanConfiguration.defaultSimilarityPercent
    }

    var configuration: VideoScanConfiguration {
        VideoScanConfiguration(method: method, similarityPercent: similarityPercent).normalized
    }

    func chooseDirectory() {
        guard !isScanning, let url = FinderBridge.chooseVideoScanDirectory(startingAt: rootURL) else { return }
        rootURL = url.standardizedFileURL
        invalidateResultIfConfigurationChanged()
    }

    func invalidateResultIfConfigurationChanged() {
        guard !isScanning else { return }
        if let result, result.rootURL != rootURL.standardizedFileURL
            || result.configuration.method != method
            || (method == .similar && result.configuration.similarityPercent != configuration.similarityPercent) {
            self.result = nil
        }
        errorMessage = nil
    }

    func startScan() {
        guard !isScanning else { return }
        let configuration = configuration
        similarityPercent = configuration.similarityPercent
        let root = rootURL.standardizedFileURL
        result = nil
        errorMessage = nil
        isScanning = true
        isCancelling = false
        progress = nil
        scanTask = Task { [weak self] in
            guard let self else { return }
            let operation = await scanner.scan(from: root, configuration: configuration)
            let progressTask = Task { @MainActor [weak self] in
                for await update in operation.stream {
                    guard !Task.isCancelled else { return }
                    self?.progress = update
                }
            }
            defer {
                progressTask.cancel()
                progress = nil
                isScanning = false
                isCancelling = false
                scanTask = nil
            }
            do {
                let value = try await withTaskCancellationHandler {
                    try Task.checkCancellation()
                    return try await operation.task.value
                } onCancel: { operation.task.cancel() }
                try Task.checkCancellation()
                result = value
            } catch {
                if !Task.isCancelled && !(error is CancellationError) {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    func cancel() {
        guard isScanning else { return }
        isCancelling = true
        scanTask?.cancel()
    }

    func clearError() { errorMessage = nil }
}

struct DuplicateVideoToolView: View {
    @ObservedObject var controller: VideoScanController
    @State private var searchText = ""

    private var filteredGroups: [DuplicateVideoGroup] {
        let groups = controller.result?.groups ?? []
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return groups }
        return groups.filter { $0.members.contains { $0.item.url.path.localizedCaseInsensitiveContains(query) } }
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            if let error = controller.errorMessage {
                HStack {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Spacer()
                    Button(L10n.text("common.ok")) { controller.clearError() }
                }
                .font(.callout)
                .padding(12)
            }
            if controller.isScanning {
                scanningState
            } else if let result = controller.result {
                results(result)
            } else {
                message(
                    "film.stack", title: L10n.text("videos.empty.title"),
                    detail: L10n.text("videos.empty.detail")
                )
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: controller.method) { _ in controller.invalidateResultIfConfigurationChanged() }
        .onChange(of: controller.similarityPercent) { _ in controller.invalidateResultIfConfigurationChanged() }
        .onChange(of: controller.rootURL) { _ in controller.invalidateResultIfConfigurationChanged() }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "folder.fill").foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("large_files.scope")).font(.caption2).foregroundStyle(.secondary)
                    Text(controller.rootURL.path)
                        .font(.callout).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
                Spacer()
                Button(L10n.text("large_files.choose")) { controller.chooseDirectory() }
                    .disabled(controller.isScanning)
            }
            HStack(spacing: 14) {
                Picker(L10n.text("videos.method"), selection: $controller.method) {
                    ForEach(VideoComparisonMethod.allCases) { method in
                        Text(method.title).tag(method)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 250)
                .disabled(controller.isScanning)

                if controller.method == .similar {
                    Stepper(value: $controller.similarityPercent, in: 70...100, step: 1) {
                        Text(L10n.text("videos.threshold", controller.similarityPercent.formatted()))
                            .monospacedDigit()
                    }
                    .fixedSize()
                    .help(L10n.text("videos.score.help"))
                    .disabled(controller.isScanning)
                }
                Spacer()
                if controller.isScanning {
                    Button(L10n.text(controller.isCancelling ? "large_files.cancelling" : "large_files.cancel")) {
                        controller.cancel()
                    }
                    .disabled(controller.isCancelling)
                } else {
                    Button(L10n.text(controller.result == nil ? "large_files.start" : "large_files.rescan")) {
                        searchText = ""
                        controller.startScan()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            Text(L10n.text(controller.method == .exact ? "videos.exact.note" : "videos.similar.note"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var scanningState: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text(L10n.text("videos.phase.\(controller.progress?.phase.rawValue ?? "discovering")"))
                .font(.headline)
            if let progress = controller.progress {
                Text(L10n.text("videos.progress", progress.scannedFileCount.formatted(), progress.candidateVideoCount.formatted()))
                    .font(.callout).foregroundStyle(.secondary)
                if progress.totalCount > 0 {
                    ProgressView(value: Double(progress.completedCount), total: Double(progress.totalCount))
                        .frame(width: 320)
                    Text("\(progress.completedCount) / \(progress.totalCount)")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Text(progress.currentPath)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).frame(maxWidth: 650)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func results(_ result: VideoScanResult) -> some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.text("videos.summary", result.groups.count.formatted(), result.groupedVideoCount.formatted()))
                        .font(.headline)
                    Text(L10n.text(
                        "videos.stats", result.candidateVideoCount.formatted(), result.analyzedVideoCount.formatted(),
                        result.elapsedSeconds.formatted(.number.precision(.fractionLength(1)))
                    ))
                    .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !result.groups.isEmpty {
                    TextField(L10n.text("videos.search"), text: $searchText)
                        .textFieldStyle(.roundedBorder).frame(width: 260)
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            diagnostics(result.diagnostics)
            Divider()
            if result.groups.isEmpty {
                message(
                    result.diagnostics.hasCoverageWarning ? "exclamationmark.magnifyingglass" : "film.stack",
                    title: L10n.text(result.diagnostics.hasCoverageWarning ? "videos.incomplete.title" : "videos.no_matches"),
                    detail: L10n.text(result.configuration.method == .exact ? "videos.no_matches.exact" : "videos.no_matches.similar")
                )
            } else if filteredGroups.isEmpty {
                message("magnifyingglass", title: L10n.text("videos.search.empty"), detail: "")
            } else {
                ScrollView {
                    LazyVStack(spacing: 14) {
                        ForEach(Array(filteredGroups.enumerated()), id: \.element.id) { index, group in
                            DuplicateVideoGroupView(index: index + 1, group: group, method: result.configuration.method)
                        }
                    }
                    .padding(18)
                }
            }
        }
    }

    @ViewBuilder
    private func diagnostics(_ value: VideoScanDiagnostics) -> some View {
        if value.hasCoverageWarning {
            notice(L10n.text(
                "videos.coverage", value.unreadableDirectoryCount.formatted(), value.metadataErrorCount.formatted(),
                value.readErrorCount.formatted(), value.changedFileCount.formatted()
            ), warning: true)
        }
        if value.skippedVolumeCount > 0 {
            notice(L10n.text("large_files.volumes.skipped", value.skippedVolumeCount.formatted()))
        }
        if value.linkedFileCount > 0 {
            notice(L10n.text("videos.links", value.linkedFileCount.formatted()))
        }
        if value.previewErrorCount > 0 {
            notice(L10n.text("videos.preview.errors", value.previewErrorCount.formatted()))
        }
    }

    private func notice(_ text: String, warning: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: warning ? "exclamationmark.triangle.fill" : "info.circle")
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(warning ? Color.orange : .secondary)
        .padding(.horizontal, 18).padding(.vertical, 7)
        .background(warning ? Color.orange.opacity(0.08) : Color.primary.opacity(0.03))
    }

    private func message(_ symbol: String, title: String, detail: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 38)).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 540)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DuplicateVideoGroupView: View {
    let index: Int
    let group: DuplicateVideoGroup
    let method: VideoComparisonMethod

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "film.stack.fill").foregroundStyle(Color.accentColor)
                Text(L10n.text("videos.group", index.formatted(), group.members.count.formatted()))
                    .fontWeight(.semibold)
                Spacer()
                Text(method.title).foregroundStyle(.secondary)
                Text("·").foregroundStyle(.tertiary)
                Text(SizeFormatter.shared.string(fromByteCount: group.totalBytes)).monospacedDigit()
            }
            .font(.caption)
            .padding(.horizontal, 14).frame(height: 36)
            .background(Color.primary.opacity(0.035))
            ForEach(group.members) { member in
                Divider()
                DuplicateVideoRow(member: member, method: method)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }
}

private struct DuplicateVideoRow: View {
    let member: DuplicateVideoMember
    let method: VideoComparisonMethod
    private var item: DuplicateVideoItem { member.item }

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(item.url.lastPathComponent).font(.callout.weight(.medium)).lineLimit(1)
                    if member.isReference {
                        Text(L10n.text("similar_images.reference"))
                            .font(.caption2.weight(.semibold)).foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.1), in: Capsule())
                    }
                }
                Text(item.url.deletingLastPathComponent().path)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Text(metadata).font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                Text(SizeFormatter.shared.string(fromByteCount: item.logicalBytes))
                    .font(.caption.weight(.medium).monospacedDigit())
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                if item.previews.isEmpty {
                    VStack(spacing: 5) {
                        Image(systemName: "film").font(.title2)
                        Text(L10n.text("videos.preview.unavailable")).font(.caption2)
                    }
                    .foregroundStyle(.secondary).frame(width: 264, height: 66)
                } else {
                    ForEach(Array(item.previews.enumerated()), id: \.offset) { _, frame in
                        VStack(spacing: 3) {
                            if let image = NSImage(data: frame.jpeg) {
                                Image(nsImage: image).resizable().scaledToFit()
                                    .frame(width: 84, height: 50)
                                    .background(.black.opacity(0.9), in: RoundedRectangle(cornerRadius: 4))
                            }
                            Text(VideoDisplay.timestamp(frame.seconds))
                                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(width: 264)
            Text(score)
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(Color.accentColor).frame(width: 80)
                .help(L10n.text(method == .exact ? "videos.exact.note" : "videos.score.help"))
            Button { FinderBridge.reveal(item.url) } label: {
                Image(systemName: "finder").frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless).help(L10n.text("common.reveal_finder"))
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { FinderBridge.reveal(item.url) }
        .contextMenu {
            Button(L10n.text("common.reveal_finder")) { FinderBridge.reveal(item.url) }
        }
    }

    private var metadata: String {
        guard let duration = item.duration, let width = item.pixelWidth, let height = item.pixelHeight else {
            return L10n.text("videos.metadata.unavailable")
        }
        return "\(VideoDisplay.timestamp(duration)) · \(width) × \(height) · "
            + L10n.text("videos.audio_tracks", (item.audioTrackCount ?? 0).formatted())
    }

    private var score: String {
        if method == .exact { return L10n.text("videos.identical") }
        guard let distance = member.maximumFrameDistance else { return "—" }
        return "\(VisionFeatureSimilarityScale.similarityPercent(forDistance: distance))%"
    }
}

enum VideoDisplay {
    static func timestamp(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else { return "—" }
        let total = Int(seconds)
        if total >= 3_600 { return String(format: "%d:%02d:%02d", total / 3_600, total / 60 % 60, total % 60) }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
