import SwiftUI

struct RankingListView: View {
    let nodes: [FileNode]
    let displayRoot: FileNode
    let metric: SizeMetric
    @Binding var scope: RankingScope
    @Binding var sortOption: SortOption
    @Binding var searchText: String
    @Binding var selectedNodeID: String?
    let cleanupNodeIDs: Set<String>
    let isCleanupActive: Bool
    let onRevealInFinder: (FileNode) -> Void
    let onDrillDown: (FileNode) -> Void
    let onAddToCleanup: (FileNode) -> Void
    let onRemoveFromCleanup: (FileNode) -> Void

    private var referenceBytes: Int64 {
        if scope == .current {
            return max(displayRoot.bytes(for: metric), 1)
        }
        return max(nodes.map { $0.bytes(for: metric) }.max() ?? 1, 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 9) {
                Picker(L10n.text("ranking.scope"), selection: $scope) {
                    ForEach(RankingScope.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)

                HStack(spacing: 8) {
                    TextField(L10n.text("ranking.search"), text: $searchText)
                        .textFieldStyle(.roundedBorder)

                    Picker(L10n.text("ranking.sort"), selection: $sortOption) {
                        ForEach(SortOption.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
                    .accessibilityLabel(L10n.text("ranking.sort"))
                    .help(L10n.text("ranking.sort.help"))
                }
            }
            .padding(12)

            Divider()

            if nodes.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text(L10n.text(searchText.isEmpty ? "ranking.empty" : "ranking.no_match"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List(selection: $selectedNodeID) {
                    ForEach(Array(nodes.enumerated()), id: \.element.id) { index, node in
                        RankingRowView(
                            node: node,
                            metric: metric,
                            fraction: Double(node.bytes(for: metric)) / Double(referenceBytes),
                            hue: nodes.count > 1 ? Double(index) / Double(nodes.count) : 0,
                            isInCleanup: cleanupNodeIDs.contains(node.id)
                        )
                        .contentShape(Rectangle())
                        .tag(node.id)
                        .simultaneousGesture(TapGesture(count: 1).onEnded {
                            selectedNodeID = node.id
                        })
                        .simultaneousGesture(TapGesture(count: 2).onEnded {
                            if node.isDirectory {
                                onDrillDown(node)
                            } else if node.canRevealInFinder {
                                onRevealInFinder(node)
                            }
                        })
                        .contextMenu {
                            if node.isDirectory {
                                Button(L10n.text("common.enter_directory")) { onDrillDown(node) }
                            }
                            if node.canRevealInFinder {
                                Button(L10n.text("common.reveal_finder")) { onRevealInFinder(node) }
                            }
                            if node.canMoveToTrash {
                                Divider()
                                if cleanupNodeIDs.contains(node.id) {
                                    Button(L10n.text("collector.remove_item")) {
                                        onRemoveFromCleanup(node)
                                    }
                                    .disabled(isCleanupActive)
                                } else {
                                    Button(L10n.text("collector.add")) {
                                        onAddToCleanup(node)
                                    }
                                    .disabled(isCleanupActive)
                                }
                            }
                        }
                    }
                }
                .onChange(of: nodes.map(\.id)) { visibleIDs in
                    if let selectedNodeID, !visibleIDs.contains(selectedNodeID) {
                        self.selectedNodeID = nil
                    }
                }
                .listStyle(.plain)
            }

            Divider()

            HStack {
                Text(L10n.text("ranking.footer.count", nodes.count.formatted()))
                Spacer()
                Text(L10n.text("ranking.footer.help"))
            }
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 12)
            .frame(height: 28)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.22))
    }
}

private struct RankingRowView: View {
    let node: FileNode
    let metric: SizeMetric
    let fraction: Double
    let hue: Double
    let isInCleanup: Bool

    @Environment(\.colorScheme) private var colorScheme

    private var accentColor: Color {
        Color(
            hue: hue,
            saturation: colorScheme == .dark ? 0.72 : 0.68,
            brightness: colorScheme == .dark ? 0.84 : 0.76
        )
    }

    private var symbol: String {
        switch node.kind {
        case .directory: return node.isUnreadable ? "folder.badge.questionmark" : "folder.fill"
        case .file: return "doc.fill"
        case .symbolicLink: return "link"
        case .otherFiles: return "ellipsis.circle.fill"
        case .skippedVolume: return "externaldrive.badge.xmark"
        }
    }

    private var secondaryText: String {
        switch node.kind {
        case .otherFiles:
            return L10n.text("ranking.aggregate")
        case .skippedVolume:
            return L10n.text("ranking.skipped_volume")
        default:
            return node.path ?? ""
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(accentColor)
                .frame(width: 24, height: 24)
                .background(accentColor.opacity(0.11), in: RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(node.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if node.isSharedReference {
                        Image(systemName: "link.circle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .help(L10n.text("ranking.shared.help"))
                    }

                    if node.isUnreadable {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.orange)
                            .help(L10n.text("ranking.unreadable.help"))
                    }

                    if isInCleanup {
                        Image(systemName: "tray.full.fill")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.orange)
                            .help(L10n.text("collector.queued"))
                    }
                }

                Text(secondaryText)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 5) {
                Text(node.formattedSize(for: metric))
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())

                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color(nsColor: .separatorColor).opacity(0.55))
                        Capsule()
                            .fill(accentColor.opacity(0.85))
                            .frame(
                                width: geometry.size.width * max(0, min(fraction, 1))
                            )
                    }
                }
                .frame(width: 72, height: 4)
            }
        }
        .padding(.vertical, 5)
        .help(L10n.text(
            "ranking.row.help",
            node.path ?? node.name,
            node.formattedSize(for: .allocated),
            node.formattedSize(for: .logical)
        ))
    }
}
