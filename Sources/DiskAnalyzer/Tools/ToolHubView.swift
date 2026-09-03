import SwiftUI

enum DiskUtilityTool: String, CaseIterable, Identifiable {
    case largeFiles
    case similarImages

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .largeFiles: "large_files.title"
        case .similarImages: "similar_images.title"
        }
    }

    var subtitleKey: String {
        switch self {
        case .largeFiles: "large_files.selector.detail"
        case .similarImages: "similar_images.selector.detail"
        }
    }

    var symbolName: String {
        switch self {
        case .largeFiles: "doc.text.magnifyingglass"
        case .similarImages: "photo.stack"
        }
    }
}

struct ToolsView: View {
    @ObservedObject var largeFileController: LargeFileScanController
    @ObservedObject var similarImageController: SimilarImageScanController
    @Binding var selection: DiskUtilityTool

    init(
        largeFileController: LargeFileScanController,
        similarImageController: SimilarImageScanController,
        selection: Binding<DiskUtilityTool>
    ) {
        self.largeFileController = largeFileController
        self.similarImageController = similarImageController
        _selection = selection
    }

    var body: some View {
        VStack(spacing: 0) {
            toolSelector
            Divider()

            switch selection {
            case .largeFiles:
                LargeFileToolView(controller: largeFileController)
            case .similarImages:
                SimilarImageToolView(controller: similarImageController)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var toolSelector: some View {
        HStack(spacing: 10) {
            ForEach(DiskUtilityTool.allCases) { tool in
                Button {
                    selection = tool
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: tool.symbolName)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(
                                selection == tool ? Color.accentColor : .secondary
                            )
                            .frame(width: 34, height: 34)
                            .background(
                                selection == tool
                                    ? Color.accentColor.opacity(0.12)
                                    : Color.secondary.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                            )

                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.text(tool.titleKey))
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text(L10n.text(tool.subtitleKey))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 10)

                        if isScanning(tool) {
                            ProgressView()
                                .controlSize(.small)
                        } else if selection == tool {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color.accentColor)
                                .accessibilityHidden(true)
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(maxWidth: 360, minHeight: 52)
                    .background(
                        selection == tool
                            ? Color.accentColor.opacity(0.08)
                            : Color(nsColor: .controlBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .stroke(
                                selection == tool
                                    ? Color.accentColor.opacity(0.75)
                                    : Color.primary.opacity(0.08),
                                lineWidth: selection == tool ? 1.5 : 1
                            )
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.text(tool.titleKey))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func isScanning(_ tool: DiskUtilityTool) -> Bool {
        switch tool {
        case .largeFiles:
            largeFileController.isScanning
        case .similarImages:
            similarImageController.isScanning
        }
    }
}
