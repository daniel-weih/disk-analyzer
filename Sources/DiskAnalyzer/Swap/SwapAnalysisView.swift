import SwapAnalysisCore
import SwiftUI

struct SwapAnalysisView: View {
    @ObservedObject var monitor: SwapMonitor
    var startsAutomatically = true
    @State private var searchText = ""
    @State private var sortMetric: GroupSortMetric = .estimatedSwap

    private var matchingGroups: [ApplicationMemoryGroup] {
        let occupied = monitor.snapshot.groups.filter { $0.compressorBackedBytes > 0 }
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return occupied
        }

        return occupied.filter { group in
            group.name.localizedCaseInsensitiveContains(searchText)
                || group.processes.contains(where: {
                    $0.processName.localizedCaseInsensitiveContains(searchText)
                        || $0.executablePath.localizedCaseInsensitiveContains(searchText)
                })
        }
    }

    private var sortedGroups: [ApplicationMemoryGroup] {
        matchingGroups.sorted { lhs, rhs in
            let lhsValue: UInt64
            let rhsValue: UInt64
            switch sortMetric {
            case .estimatedSwap:
                lhsValue = lhs.estimatedSwapBytes
                rhsValue = rhs.estimatedSwapBytes
            case .compressorBacked:
                lhsValue = lhs.compressorBackedBytes
                rhsValue = rhs.compressorBackedBytes
            case .resident:
                lhsValue = lhs.residentBytes
                rhsValue = rhs.residentBytes
            }
            if lhsValue != rhsValue { return lhsValue > rhsValue }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private var rankingGroups: [ApplicationMemoryGroup] {
        matchingGroups.sorted {
            if $0.estimatedSwapBytes != $1.estimatedSwapBytes {
                return $0.estimatedSwapBytes > $1.estimatedSwapBytes
            }
            return $0.compressorBackedBytes > $1.compressorBackedBytes
        }
    }

    private var selectedGroup: ApplicationMemoryGroup? {
        guard let id = monitor.selectedGroupID else { return nil }
        return monitor.snapshot.groups.first(where: { $0.id == id })
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()

            if let errorMessage = monitor.errorMessage {
                errorBanner(errorMessage)
            }

            if monitor.snapshot == .empty {
                initialState
            } else {
                dashboard
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            if startsAutomatically { monitor.start() }
        }
        .onDisappear {
            if startsAutomatically { monitor.stop() }
        }
        .onChange(of: sortedGroups.map(\.id)) { ids in
            guard !ids.isEmpty else {
                monitor.selectedGroupID = nil
                return
            }
            if let selected = monitor.selectedGroupID, ids.contains(selected) {
                return
            }
            monitor.selectedGroupID = ids.first
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            TextField(L10n.text("swap.search"), text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 180, idealWidth: 260, maxWidth: 320)

            HStack(spacing: 6) {
                Text(L10n.text("swap.sort"))
                    .fontWeight(.medium)
                Picker("", selection: $sortMetric) {
                    ForEach(GroupSortMetric.allCases) { metric in
                        Text(metric.label).tag(metric)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 128)
            }

            HStack(spacing: 6) {
                Text(L10n.text("swap.refresh.title"))
                    .fontWeight(.medium)
                Picker("", selection: $monitor.autoRefresh) {
                    ForEach(AutoRefreshInterval.allCases) { interval in
                        Text(interval.label).tag(interval)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 128)
            }

            Spacer(minLength: 8)

            if monitor.snapshot != .empty {
                samplingStatus
            }

            Button {
                monitor.refresh()
            } label: {
                if monitor.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 16, height: 16)
                } else {
                    Label(L10n.text("swap.refresh.now"), systemImage: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderedProminent)
            .help(L10n.text("swap.refresh.help"))
            .disabled(monitor.isRefreshing)
            .keyboardShortcut("r", modifiers: .command)

        }
        .controlSize(.small)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    private var samplingStatus: some View {
        HStack(spacing: 9) {
            Label {
                Text(L10n.text(
                    "swap.header.readable",
                    monitor.snapshot.coverage.readableProcesses.formatted(),
                    monitor.snapshot.coverage.discoveredProcesses.formatted()
                ))
                .lineLimit(1)
            } icon: {
                Image(systemName: monitor.snapshot.coverage.permissionDeniedProcesses > 0
                    ? "lock.trianglebadge.exclamationmark"
                    : "checkmark.shield")
            }
            .foregroundStyle(
                monitor.snapshot.coverage.permissionDeniedProcesses > 0
                    ? Color.orange
                    : Color.secondary
            )

            Divider()
                .frame(height: 22)

            VStack(alignment: .trailing, spacing: 1) {
                Text(L10n.text(
                    "swap.header.updated",
                    DisplayFormat.timestamp(monitor.snapshot.capturedAt)
                ))
                Text(L10n.text(
                    "swap.header.duration",
                    monitor.snapshot.scanDuration.formatted(
                        .number.precision(.fractionLength(2))
                    )
                ))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: true, vertical: false)
        }
        .font(.caption)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var initialState: some View {
        VStack(spacing: 14) {
            if monitor.isRefreshing {
                ProgressView()
                    .controlSize(.large)
                Text(L10n.text("swap.loading.title"))
                    .font(.headline)
                Text(L10n.text("swap.loading.detail"))
                    .foregroundStyle(.secondary)
            } else {
                SwapEmptyStateView(
                    title: L10n.text("swap.empty.title"),
                    detail: monitor.errorMessage ?? L10n.text("swap.empty.detail")
                )
                Button(L10n.text("common.rescan")) {
                    monitor.refresh()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var dashboard: some View {
        VStack(spacing: 0) {
            SystemOverviewView(
                snapshot: monitor.snapshot,
                history: monitor.history,
                swapInRate: monitor.swapInRateBytes,
                swapOutRate: monitor.swapOutRateBytes
            )
            .padding(14)

            HStack(spacing: 8) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(.blue)
                Text(L10n.text("swap.accounting.notice"))
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 18)
            .padding(.bottom, 10)

            if monitor.snapshot.coverage.permissionDeniedProcesses > 0 {
                HStack(spacing: 8) {
                    Image(systemName: "lock.fill")
                    Text(L10n.text(
                        "swap.permission_limited",
                        monitor.snapshot.coverage.permissionDeniedProcesses.formatted()
                    ))
                    Spacer()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 18)
                .padding(.bottom, 10)
            }

            Divider()

            HSplitView {
                VStack(spacing: 0) {
                    RankingChartView(
                        groups: rankingGroups,
                        selectedGroupID: $monitor.selectedGroupID
                    )
                    .frame(minHeight: 220, idealHeight: 240, maxHeight: 270)

                    Divider()

                    ApplicationListView(
                        groups: sortedGroups,
                        selectedGroupID: $monitor.selectedGroupID
                    )
                }
                .frame(minWidth: 690)

                ApplicationInspectorView(group: selectedGroup)
                    .frame(minWidth: 310, idealWidth: 350, maxWidth: 430)
            }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message)
            Spacer()
            Button(L10n.text("swap.retry")) {
                monitor.refresh()
            }
            .buttonStyle(.link)
        }
        .font(.callout)
        .foregroundStyle(.red)
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.08))
    }

    private struct SwapEmptyStateView: View {
        let title: String
        let detail: String

        var body: some View {
            VStack(spacing: 10) {
                Image(systemName: "memorychip")
                    .font(.system(size: 34))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.headline)
                Text(detail)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
