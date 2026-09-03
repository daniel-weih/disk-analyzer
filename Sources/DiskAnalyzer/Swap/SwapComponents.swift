import AppKit
import Charts
import SwapAnalysisCore
import SwiftUI

enum GroupSortMetric: String, CaseIterable, Identifiable {
    case estimatedSwap
    case compressorBacked
    case resident

    var id: String { rawValue }

    var label: String {
        switch self {
        case .estimatedSwap: return L10n.text("swap.metric.estimated")
        case .compressorBacked: return L10n.text("swap.metric.compressor")
        case .resident: return L10n.text("swap.metric.resident")
        }
    }
}

enum DisplayFormat {
    static func bytes(_ value: UInt64) -> String {
        guard value > 0 else { return L10n.text("swap.zero_size") }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.isAdaptive = true
        formatter.includesUnit = true
        formatter.includesCount = true
        return formatter.string(fromByteCount: value > UInt64(Int64.max) ? Int64.max : Int64(value))
    }

    static func rate(_ value: Double) -> String {
        let bounded = value.isFinite && value > 0
            ? UInt64(min(value, Double(UInt64.max)))
            : 0
        return L10n.text("swap.rate", bytes(bounded))
    }

    static func timestamp(_ date: Date) -> String {
        guard date != .distantPast else { return L10n.text("swap.not_scanned") }
        let formatter = DateFormatter()
        formatter.locale = AppLanguage.current.locale
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}

struct SystemOverviewView: View {
    let snapshot: SwapSnapshot
    let history: [SwapHistoryPoint]
    let swapInRate: Double
    let swapOutRate: Double

    private let columns = Array(
        repeating: GridItem(.flexible(minimum: 220), spacing: 12),
        count: 4
    )

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            SwapUsageCard(system: snapshot.system)
            SwapHistoryCard(
                system: snapshot.system,
                history: history,
                swapInRate: swapInRate,
                swapOutRate: swapOutRate
            )
            AttributionCard(snapshot: snapshot)
            ScanCoverageCard(snapshot: snapshot)
        }
        .frame(height: 154)
    }
}

private struct SwapUsageCard: View {
    let system: SystemMemoryMetrics

    private var usageFraction: Double {
        guard system.swapTotalBytes > 0 else { return 0 }
        return min(1, Double(system.swapUsedBytes) / Double(system.swapTotalBytes))
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.18), lineWidth: 10)
                Circle()
                    .trim(from: 0, to: usageFraction)
                    .stroke(
                        usageFraction > 0.8 ? Color.orange : Color.accentColor,
                        style: StrokeStyle(lineWidth: 10, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 1) {
                    Text(usageFraction, format: .percent.precision(.fractionLength(0)))
                        .font(.headline.monospacedDigit())
                    Text(L10n.text("swap.used"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 76, height: 76)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.text(
                "swap.usage.accessibility",
                usageFraction.formatted(.percent)
            ))

            VStack(alignment: .leading, spacing: 6) {
                Label(L10n.text("swap.usage.title"), systemImage: "internaldrive")
                    .font(.subheadline.weight(.semibold))
                Text(DisplayFormat.bytes(system.swapUsedBytes))
                    .font(.title2.bold().monospacedDigit())
                Text(L10n.text(
                    "swap.usage.total",
                    DisplayFormat.bytes(system.swapTotalBytes)
                ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .cardStyle()
    }
}

private struct SwapHistoryCard: View {
    let system: SystemMemoryMetrics
    let history: [SwapHistoryPoint]
    let swapInRate: Double
    let swapOutRate: Double

    private var yMaximum: Double {
        let historicalMaximum = history.reduce(0.0) { partialResult, point in
            max(partialResult, Double(point.usedBytes))
        }
        let observedMaximum = max(Double(system.swapTotalBytes), historicalMaximum)
        return max(1, observedMaximum * 1.05)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(L10n.text("swap.history.title"), systemImage: "chart.xyaxis.line")
                    .font(.headline)
                Spacer()
                Text(L10n.text("swap.history.count", history.count.formatted()))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Chart(history) { point in
                AreaMark(
                    x: .value(L10n.text("swap.chart.time"), point.timestamp),
                    y: .value(L10n.text("swap.chart.usage"), Double(point.usedBytes))
                )
                .foregroundStyle(Color.accentColor.opacity(0.12))
                LineMark(
                    x: .value(L10n.text("swap.chart.time"), point.timestamp),
                    y: .value(L10n.text("swap.chart.usage"), Double(point.usedBytes))
                )
                .foregroundStyle(Color.accentColor)
                .interpolationMethod(.monotone)
                PointMark(
                    x: .value(L10n.text("swap.chart.time"), point.timestamp),
                    y: .value(L10n.text("swap.chart.usage"), Double(point.usedBytes))
                )
                .foregroundStyle(Color.accentColor)
                .symbolSize(history.count == 1 ? 24 : 0)
            }
            .chartYScale(domain: 0...yMaximum)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 65)
            .clipped()
            .accessibilityLabel(L10n.text("swap.history.accessibility"))

            HStack(spacing: 16) {
                Label(
                    L10n.text("swap.rate.in", DisplayFormat.rate(swapInRate)),
                    systemImage: "arrow.down"
                )
                Label(
                    L10n.text("swap.rate.out", DisplayFormat.rate(swapOutRate)),
                    systemImage: "arrow.up"
                )
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .cardStyle()
    }
}

private struct AttributionCard: View {
    let snapshot: SwapSnapshot

    private var fraction: Double {
        guard snapshot.system.swapUsedBytes > 0 else { return 0 }
        return min(1, Double(snapshot.attributedSwapBytes) / Double(snapshot.system.swapUsedBytes))
    }

    private var occupiedGroupCount: Int {
        snapshot.groups.lazy.filter { $0.compressorBackedBytes > 0 }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(L10n.text("swap.attributed.title"), systemImage: "square.stack.3d.up")
                .font(.headline)
            Text(DisplayFormat.bytes(snapshot.attributedSwapBytes))
                .font(.title2.bold().monospacedDigit())
            ProgressView(value: fraction)
                .tint(.accentColor)
            Text(L10n.text(
                "swap.attributed.detail",
                occupiedGroupCount.formatted(),
                DisplayFormat.bytes(snapshot.unattributedSwapBytes)
            ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .cardStyle()
    }
}

private struct ScanCoverageCard: View {
    let snapshot: SwapSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(L10n.text("swap.coverage.title"), systemImage: "scope")
                .font(.headline)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(snapshot.coverage.readableProcesses)")
                    .font(.title2.bold().monospacedDigit())
                Text(L10n.text(
                    "swap.coverage.total",
                    snapshot.coverage.discoveredProcesses.formatted()
                ))
                    .foregroundStyle(.secondary)
            }
            Text(L10n.text(
                "swap.coverage.detail",
                snapshot.coverage.permissionDeniedProcesses.formatted(),
                snapshot.coverage.vanishedProcesses.formatted()
            ))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Text(L10n.text(
                "swap.coverage.duration",
                snapshot.scanDuration.formatted(.number.precision(.fractionLength(2)))
            ))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            if snapshot.coverage.regionLimitProcesses > 0 {
                Label(
                    L10n.text("swap.coverage.region_limit"),
                    systemImage: "exclamationmark.triangle.fill"
                )
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .cardStyle()
    }
}

struct RankingChartView: View {
    let groups: [ApplicationMemoryGroup]
    @Binding var selectedGroupID: String?

    private var displayedGroups: [ApplicationMemoryGroup] {
        Array(groups.filter { $0.compressorBackedBytes > 0 }.prefix(5))
    }

    private var maximumEstimate: UInt64 {
        displayedGroups.map(\.estimatedSwapBytes).max() ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("swap.ranking.title"))
                        .font(.headline)
                    Text(L10n.text("swap.ranking.detail"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if displayedGroups.isEmpty {
                SwapUnavailableView(
                    title: L10n.text("swap.ranking.empty"),
                    detail: L10n.text("swap.ranking.empty_detail"),
                    systemImage: "memorychip"
                )
            } else {
                VStack(spacing: 6) {
                    ForEach(Array(displayedGroups.enumerated()), id: \.element.id) { index, group in
                        RankingBarRow(
                            rank: index + 1,
                            group: group,
                            maximumEstimate: maximumEstimate,
                            isSelected: group.id == selectedGroupID
                        ) {
                            selectedGroupID = group.id
                        }
                    }
                }
                .accessibilityLabel(L10n.text("swap.ranking.accessibility"))
            }
        }
        .padding(16)
    }
}

private struct RankingBarRow: View {
    let rank: Int
    let group: ApplicationMemoryGroup
    let maximumEstimate: UInt64
    let isSelected: Bool
    let action: () -> Void

    private var fraction: Double {
        guard maximumEstimate > 0 else { return 0 }
        return min(1, Double(group.estimatedSwapBytes) / Double(maximumEstimate))
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(rank.formatted())
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 16, alignment: .trailing)

                ApplicationIconView(path: group.bundlePath, size: 22)

                Text(group.name)
                    .font(.subheadline.weight(isSelected ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: 150, alignment: .leading)

                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.secondary.opacity(0.12))
                        Capsule()
                            .fill(Color.accentColor.opacity(isSelected ? 0.92 : 0.5))
                            .frame(width: proxy.size.width * fraction)
                    }
                }
                .frame(height: 8)

                Text(DisplayFormat.bytes(group.estimatedSwapBytes))
                    .font(.callout.weight(.medium).monospacedDigit())
                    .frame(width: 88, alignment: .trailing)
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.text(
            "swap.application.accessibility",
            group.name,
            DisplayFormat.bytes(group.estimatedSwapBytes),
            group.processes.count.formatted()
        ))
    }
}

struct ApplicationListView: View {
    let groups: [ApplicationMemoryGroup]
    @Binding var selectedGroupID: String?

    private var maximumEstimate: UInt64 {
        groups.map(\.estimatedSwapBytes).max() ?? 0
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(L10n.text("swap.application"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(L10n.text("swap.metric.estimated"))
                    .frame(width: 132, alignment: .trailing)
                Text(L10n.text("swap.metric.compressor"))
                    .frame(width: 118, alignment: .trailing)
                Text(L10n.text("swap.metric.resident"))
                    .frame(width: 108, alignment: .trailing)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            if groups.isEmpty {
                SwapUnavailableView(
                    title: L10n.text("swap.list.empty"),
                    detail: L10n.text("swap.list.empty_detail"),
                    systemImage: "magnifyingglass"
                )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(groups) { group in
                            ApplicationRow(
                                group: group,
                                maximumEstimate: maximumEstimate,
                                isSelected: selectedGroupID == group.id
                            ) {
                                selectedGroupID = group.id
                            }
                            Divider()
                                .padding(.leading, 54)
                        }
                    }
                }
            }
        }
    }
}

private struct ApplicationRow: View {
    let group: ApplicationMemoryGroup
    let maximumEstimate: UInt64
    let isSelected: Bool
    let action: () -> Void

    private var estimateFraction: Double {
        guard maximumEstimate > 0 else { return 0 }
        return Double(group.estimatedSwapBytes) / Double(maximumEstimate)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ApplicationIconView(path: group.bundlePath, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.name)
                        .lineLimit(1)
                    Text(L10n.text(
                        "swap.process.count",
                        group.processes.count.formatted()
                    ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .trailing, spacing: 4) {
                    Text(DisplayFormat.bytes(group.estimatedSwapBytes))
                        .monospacedDigit()
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.secondary.opacity(0.12))
                            Capsule()
                                .fill(Color.accentColor.opacity(isSelected ? 0.9 : 0.55))
                                .frame(width: proxy.size.width * estimateFraction)
                        }
                    }
                    .frame(height: 4)
                }
                .frame(width: 132, alignment: .trailing)

                Text(DisplayFormat.bytes(group.compressorBackedBytes))
                    .monospacedDigit()
                    .frame(width: 118, alignment: .trailing)
                Text(DisplayFormat.bytes(group.residentBytes))
                    .monospacedDigit()
                    .frame(width: 108, alignment: .trailing)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        .accessibilityLabel(
            L10n.text(
                "swap.application.accessibility",
                group.name,
                DisplayFormat.bytes(group.estimatedSwapBytes),
                group.processes.count.formatted()
            )
        )
    }
}

struct ApplicationInspectorView: View {
    let group: ApplicationMemoryGroup?

    var body: some View {
        Group {
            if let group {
                selectedGroupView(group)
            } else {
                explanationView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
    }

    private func selectedGroupView(_ group: ApplicationMemoryGroup) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    ApplicationIconView(path: group.bundlePath, size: 48)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(group.name)
                            .font(.title3.bold())
                            .lineLimit(2)
                        Text(L10n.text(
                            "swap.process.count",
                            group.processes.count.formatted()
                        ))
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(spacing: 8) {
                    InspectorMetric(
                        title: L10n.text("swap.metric.estimated"),
                        value: DisplayFormat.bytes(group.estimatedSwapBytes),
                        color: .accentColor
                    )
                    InspectorMetric(
                        title: L10n.text("swap.metric.compressor_pages"),
                        value: DisplayFormat.bytes(group.compressorBackedBytes),
                        color: .orange
                    )
                    InspectorMetric(
                        title: L10n.text("swap.metric.resident"),
                        value: DisplayFormat.bytes(group.residentBytes),
                        color: .green
                    )
                }

                Label {
                    Text(L10n.text("swap.estimate.disclaimer"))
                } icon: {
                    Image(systemName: "info.circle.fill")
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                Divider()

                Text(L10n.text("swap.process.details"))
                    .font(.headline)

                LazyVStack(spacing: 0) {
                    ForEach(group.processes) { process in
                        ProcessDetailRow(
                            process: process,
                            estimatedSwapBytes: processEstimate(process, in: group)
                        )
                        Divider()
                    }
                }

                if let targetPath = group.bundlePath ?? group.processes.first?.executablePath,
                   !targetPath.isEmpty {
                    Button {
                        NSWorkspace.shared.selectFile(
                            targetPath,
                            inFileViewerRootedAtPath: ""
                        )
                    } label: {
                        Label(L10n.text("common.reveal_finder"), systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(18)
        }
    }

    private var explanationView: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "memorychip")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text(L10n.text("swap.inspector.title"))
                .font(.title3.bold())
            Text(L10n.text("swap.inspector.detail"))
                .foregroundStyle(.secondary)
            Text(L10n.text("swap.inspector.permission"))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(24)
    }

    private func processEstimate(
        _ process: ProcessMemorySample,
        in group: ApplicationMemoryGroup
    ) -> UInt64 {
        guard group.compressorBackedBytes > 0 else { return 0 }
        let fraction = Double(process.compressorBackedBytes) / Double(group.compressorBackedBytes)
        let estimate = Double(group.estimatedSwapBytes) * fraction
        return estimate.isFinite ? UInt64(max(0, estimate)) : 0
    }
}

private struct InspectorMetric: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        HStack {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.semibold)
                .monospacedDigit()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}

private struct ProcessDetailRow: View {
    let process: ProcessMemorySample
    let estimatedSwapBytes: UInt64

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(process.processName)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text("PID \(process.id)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if process.usesTranslatedArchitecture {
                    Text("Rosetta")
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                }
                Spacer()
                Text(DisplayFormat.bytes(estimatedSwapBytes))
                    .font(.callout.weight(.semibold).monospacedDigit())
            }
            HStack {
                Text(L10n.text(
                    "swap.process.compressor",
                    DisplayFormat.bytes(process.compressorBackedBytes)
                ))
                Spacer()
                Text(L10n.text(
                    "swap.process.resident",
                    DisplayFormat.bytes(process.residentBytes)
                ))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            if !process.executablePath.isEmpty {
                Text(process.executablePath)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 9)
    }
}

struct ApplicationIconView: View {
    let path: String?
    let size: CGFloat

    var body: some View {
        Group {
            if let path, !path.isEmpty {
                Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "terminal")
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.16)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private extension View {
    func cardStyle() -> some View {
        self
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
            }
    }
}

private struct SwapUnavailableView: View {
    let title: String
    let detail: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 9) {
            Image(systemName: systemImage)
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding()
    }
}
