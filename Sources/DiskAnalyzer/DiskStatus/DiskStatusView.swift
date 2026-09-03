import AppKit
import Charts
import DiskStatusCore
import SwiftUI

struct DiskStatusView: View {
    @ObservedObject var monitor: DiskStatusMonitor
    var startsAutomatically = true

    var body: some View {
        VStack(spacing: 0) {
            if let errorMessage = monitor.errorMessage {
                errorBanner(errorMessage)
            }

            if let snapshot = monitor.snapshot {
                dashboard(snapshot: snapshot)
            } else {
                loadingState
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            if startsAutomatically { monitor.start() }
        }
        .onDisappear {
            if startsAutomatically { monitor.stop() }
        }
    }

    private func dashboard(snapshot: DiskIOSnapshot) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                DiskCapacityCard(
                    volume: snapshot.volume,
                    smartHealth: monitor.smartHealth,
                    isSMARTToolInstalled: monitor.isSMARTToolInstalled,
                    isSMARTLoading: monitor.isSMARTLoading,
                    smartErrorMessage: monitor.smartErrorMessage,
                    onRecheckSMART: monitor.recheckSMARTInstallation
                )
                    .frame(width: 310)
                DiskThroughputCard(
                    rates: monitor.rates,
                    history: monitor.history,
                    hasMeasuredRates: monitor.hasMeasuredRates,
                    capturedAt: snapshot.capturedAt,
                    isMonitoring: monitor.isMonitoring
                )
            }
            .frame(height: 206)
            .padding(14)

            HStack(spacing: 7) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(.blue)
                Text(L10n.text("disk_status.accounting_notice"))
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 18)
            .padding(.bottom, 10)

            Divider()

            ProcessDiskIOList(
                activities: monitor.activities,
                coverage: snapshot.coverage,
                hasMeasuredRates: monitor.hasMeasuredRates
            )
        }
    }

    private var loadingState: some View {
        VStack(spacing: 13) {
            ProgressView()
                .controlSize(.large)
            Text(L10n.text("disk_status.loading.title"))
                .font(.headline)
            Text(L10n.text("disk_status.loading.detail"))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message)
            Spacer()
            Button(L10n.text("disk_status.retry")) {
                monitor.restart()
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

private struct DiskCapacityCard: View {
    let volume: DiskVolumeMetrics
    let smartHealth: SMARTHealthSnapshot?
    let isSMARTToolInstalled: Bool
    let isSMARTLoading: Bool
    let smartErrorMessage: String?
    let onRecheckSMART: () -> Bool

    private var usedFraction: Double {
        guard volume.totalBytes > 0 else { return 0 }
        return min(1, Double(volume.usedBytes) / Double(volume.totalBytes))
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .stroke(Color.secondary.opacity(0.16), lineWidth: 10)
                    Circle()
                        .trim(from: 0, to: usedFraction)
                        .stroke(
                            usedFraction >= 0.9 ? Color.orange : Color.accentColor,
                            style: StrokeStyle(lineWidth: 10, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 1) {
                        Text(usedFraction, format: .percent.precision(.fractionLength(0)))
                            .font(.title3.bold().monospacedDigit())
                        Text(L10n.text("disk_status.volume.used"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 90, height: 90)

                VStack(alignment: .leading, spacing: 7) {
                    Label(volume.name, systemImage: "internaldrive.fill")
                        .font(.headline)
                        .lineLimit(1)
                    Text(L10n.text(
                        "disk_status.volume.available",
                        DiskIOFormat.bytes(volume.availableBytes)
                    ))
                        .font(.title2.bold().monospacedDigit())
                    Text(L10n.text(
                        "disk_status.volume.total",
                        DiskIOFormat.bytes(volume.totalBytes)
                    ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(L10n.text(
                        "disk_status.volume.device",
                        volume.physicalBSDName
                    ))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }

            Divider()
            if isSMARTToolInstalled {
                SMARTCompactSummary(
                    snapshot: smartHealth,
                    isLoading: isSMARTLoading,
                    errorMessage: smartErrorMessage
                )
            } else {
                SMARTInstallPrompt(onRecheck: onRecheckSMART)
            }
        }
        .diskStatusCardStyle()
    }
}

private struct SMARTInstallPrompt: View {
    let onRecheck: () -> Bool
    @State private var isShowingHelp = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "heart.text.square")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text("smart.install.title"))
                    .font(.caption.weight(.semibold))
                Text(L10n.text("smart.install.summary"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 4)

            Button(L10n.text("smart.install.action")) {
                isShowingHelp = true
            }
            .buttonStyle(.link)
            .font(.caption)
            .popover(isPresented: $isShowingHelp, arrowEdge: .trailing) {
                SMARTInstallHelpView(onRecheck: onRecheck)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SMARTInstallHelpView: View {
    let onRecheck: () -> Bool
    @State private var copiedCommand: String?
    @State private var didFailRecheck = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                L10n.text("smart.install.help.title"),
                systemImage: "arrow.down.circle.fill"
            )
            .font(.headline)

            Text(L10n.text("smart.install.help.detail"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            installCommand(
                name: L10n.text("smart.install.homebrew"),
                command: "brew install smartmontools"
            )
            installCommand(
                name: L10n.text("smart.install.macports"),
                command: "sudo port install smartmontools"
            )

            Text(L10n.text("smart.install.help.note"))
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Divider()

            HStack {
                if didFailRecheck {
                    Text(L10n.text("smart.install.not_found"))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Spacer()
                Button(L10n.text("smart.install.recheck")) {
                    didFailRecheck = !onRecheck()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(16)
        .frame(width: 420)
    }

    private func installCommand(name: String, command: String) -> some View {
        HStack(spacing: 8) {
            Text(name)
                .font(.caption.weight(.semibold))
                .frame(width: 64, alignment: .leading)
            Text(command)
                .font(.caption.monospaced())
                .lineLimit(1)
                .textSelection(.enabled)
            Spacer(minLength: 4)
            Button(
                copiedCommand == command
                    ? L10n.text("smart.install.copied")
                    : L10n.text("smart.install.copy")
            ) {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(command, forType: .string)
                copiedCommand = command
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
    }
}

private struct SMARTCompactSummary: View {
    let snapshot: SMARTHealthSnapshot?
    let isLoading: Bool
    let errorMessage: String?
    @State private var isShowingDetails = false

    private var healthColor: Color {
        guard let snapshot else { return errorMessage == nil ? .secondary : .orange }
        if snapshot.overallPassed == false || (snapshot.criticalWarning ?? 0) != 0 {
            return .red
        }
        if snapshot.overallPassed == true { return .green }
        return .orange
    }

    private var healthLabel: String {
        guard let snapshot else {
            return errorMessage == nil
                ? L10n.text("smart.loading")
                : L10n.text("smart.health.unavailable")
        }
        if snapshot.overallPassed == false || (snapshot.criticalWarning ?? 0) != 0 {
            return L10n.text("smart.health.attention")
        }
        if snapshot.overallPassed == true { return L10n.text("smart.health.passed") }
        return L10n.text("smart.health.unknown")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: "heart.text.square.fill")
                    .foregroundStyle(healthColor)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(L10n.text("smart.title"))
                            .font(.caption.weight(.semibold))
                        if isLoading {
                            ProgressView()
                                .controlSize(.mini)
                        }
                    }

                    HStack(spacing: 6) {
                        Text(healthLabel)
                            .foregroundStyle(healthColor)
                        if let temperature = snapshot?.temperatureCelsius {
                            Text("·")
                            Text(L10n.text(
                                "smart.value.celsius",
                                temperature.formatted()
                            ))
                        }
                        if let healthPercent = snapshot?.estimatedRemainingLifePercent {
                            Text("·")
                            Text(L10n.text(
                                "smart.summary.health",
                                healthPercent.formatted()
                            ))
                        }
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }

                Spacer(minLength: 0)

                if snapshot != nil || errorMessage != nil {
                    Button(L10n.text("smart.details")) {
                        isShowingDetails = true
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    .popover(isPresented: $isShowingDetails, arrowEdge: .trailing) {
                        SMARTHealthDetailsView(
                            snapshot: snapshot,
                            errorMessage: errorMessage
                        )
                    }
                }
            }

            if let snapshot,
               snapshot.dataBytesRead != nil || snapshot.dataBytesWritten != nil {
                HStack(spacing: 10) {
                    SMARTLifetimeDataMetric(
                        title: L10n.text("smart.metric.data_read"),
                        value: snapshot.dataBytesRead.map(DiskIOFormat.bytes) ?? "—",
                        color: .blue
                    )

                    Divider()
                        .frame(height: 28)

                    SMARTLifetimeDataMetric(
                        title: L10n.text("smart.metric.data_written"),
                        value: snapshot.dataBytesWritten.map(DiskIOFormat.bytes) ?? "—",
                        color: .pink
                    )
                }
                .padding(.leading, 22)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SMARTLifetimeDataMetric: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SMARTHealthDetailsView: View {
    let snapshot: SMARTHealthSnapshot?
    let errorMessage: String?

    private let columns = Array(
        repeating: GridItem(.flexible(minimum: 120), spacing: 8),
        count: 4
    )

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Label(L10n.text("smart.details.title"), systemImage: "heart.text.square.fill")
                    .font(.headline)
                Spacer()
                if let snapshot {
                    Text(L10n.text("smart.device", snapshot.deviceBSDName))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            if let errorMessage, snapshot == nil {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, minHeight: 72)
            } else if let snapshot {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                    metric(
                        "smart.metric.overall_health",
                        healthValue(snapshot),
                        color: healthColor(snapshot)
                    )
                    metric(
                        "smart.metric.critical_warning",
                        snapshot.criticalWarning.map { String(format: "0x%02llX", $0) }
                    )
                    metric(
                        "smart.metric.temperature",
                        snapshot.temperatureCelsius.map {
                            L10n.text("smart.value.celsius", $0.formatted())
                        }
                    )
                    metric(
                        "smart.metric.percentage_used",
                        percent(snapshot.percentageUsed)
                    )
                    metric(
                        "smart.metric.available_spare",
                        percent(snapshot.availableSparePercent)
                    )
                    metric(
                        "smart.metric.spare_threshold",
                        percent(snapshot.availableSpareThresholdPercent)
                    )
                    metric(
                        "smart.metric.data_read",
                        snapshot.dataBytesRead.map(DiskIOFormat.bytes),
                        detail: dataUnits(snapshot.dataUnitsRead)
                    )
                    metric(
                        "smart.metric.data_written",
                        snapshot.dataBytesWritten.map(DiskIOFormat.bytes),
                        detail: dataUnits(snapshot.dataUnitsWritten)
                    )
                    metric(
                        "smart.metric.host_read_commands",
                        number(snapshot.hostReadCommands)
                    )
                    metric(
                        "smart.metric.host_write_commands",
                        number(snapshot.hostWriteCommands)
                    )
                    metric(
                        "smart.metric.controller_busy_time",
                        snapshot.controllerBusyTimeMinutes.map {
                            L10n.text("smart.value.minutes", $0.formatted())
                        }
                    )
                    metric("smart.metric.power_cycles", number(snapshot.powerCycles))
                    metric(
                        "smart.metric.power_on_hours",
                        snapshot.powerOnHours.map {
                            L10n.text("smart.value.hours", $0.formatted())
                        }
                    )
                    metric("smart.metric.unsafe_shutdowns", number(snapshot.unsafeShutdowns))
                    metric(
                        "smart.metric.media_errors",
                        number(snapshot.mediaAndDataIntegrityErrors)
                    )
                    metric(
                        "smart.metric.error_log_entries",
                        number(snapshot.errorInformationLogEntries)
                    )
                }

                Divider()

                HStack {
                    Text(L10n.text("smart.details.note"))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer()
                    Text(L10n.text(
                        "smart.updated",
                        DisplayFormat.timestamp(snapshot.capturedAt)
                    ))
                        .monospacedDigit()
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 720)
    }

    @ViewBuilder
    private func metric(
        _ titleKey: String,
        _ value: String?,
        detail: String? = nil,
        color: Color = .primary
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L10n.text(titleKey))
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value ?? "—")
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(color)
                .lineLimit(1)
            if let detail {
                Text(detail)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .topLeading)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 6))
    }

    private func healthValue(_ snapshot: SMARTHealthSnapshot) -> String {
        if snapshot.overallPassed == false || (snapshot.criticalWarning ?? 0) != 0 {
            return L10n.text("smart.health.attention")
        }
        if snapshot.overallPassed == true { return L10n.text("smart.health.passed") }
        return L10n.text("smart.health.unknown")
    }

    private func healthColor(_ snapshot: SMARTHealthSnapshot) -> Color {
        if snapshot.overallPassed == false || (snapshot.criticalWarning ?? 0) != 0 {
            return .red
        }
        return snapshot.overallPassed == true ? .green : .orange
    }

    private func percent(_ value: Int?) -> String? {
        value.map { L10n.text("smart.value.percent", $0.formatted()) }
    }

    private func number(_ value: UInt64?) -> String? {
        value?.formatted(.number.grouping(.automatic))
    }

    private func dataUnits(_ value: UInt64?) -> String? {
        value.map {
            L10n.text(
                "smart.value.data_units",
                $0.formatted(.number.grouping(.automatic))
            )
        }
    }
}

private struct DiskThroughputCard: View {
    let rates: DiskIORates
    let history: [DiskIOHistoryPoint]
    let hasMeasuredRates: Bool
    let capturedAt: Date
    let isMonitoring: Bool

    private var peakRead: Double {
        history.map(\.readBytesPerSecond).max() ?? 0
    }

    private var peakWrite: Double {
        history.map(\.writeBytesPerSecond).max() ?? 0
    }

    private var chartMaximum: Double {
        let maximum = max(peakRead, peakWrite)
        return max(1, maximum * 1.08)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(L10n.text("disk_status.io.title"), systemImage: "chart.bar.xaxis")
                    .font(.headline)
                Spacer()
                HStack(spacing: 6) {
                    Circle()
                        .fill(isMonitoring ? Color.green : Color.secondary)
                        .frame(width: 7, height: 7)
                    Text(L10n.text(
                        isMonitoring
                            ? "disk_status.live"
                            : "disk_status.paused"
                    ))
                        .fontWeight(.semibold)
                    Text(L10n.text(
                        "disk_status.updated",
                        DisplayFormat.timestamp(capturedAt)
                    ))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            }

            HStack(spacing: 28) {
                ThroughputMetric(
                    title: L10n.text("disk_status.io.read"),
                    value: hasMeasuredRates
                        ? DiskIOFormat.rate(rates.deviceReadBytesPerSecond)
                        : "—",
                    color: .blue
                )
                ThroughputMetric(
                    title: L10n.text("disk_status.io.write"),
                    value: hasMeasuredRates
                        ? DiskIOFormat.rate(rates.deviceWriteBytesPerSecond)
                        : "—",
                    color: .pink
                )
                Spacer(minLength: 0)
            }

            Chart {
                RuleMark(y: .value("zero", 0))
                    .foregroundStyle(Color.secondary.opacity(0.3))

                ForEach(history) { point in
                    BarMark(
                        x: .value(L10n.text("disk_status.chart.time"), point.timestamp),
                        yStart: .value("zero", 0),
                        yEnd: .value(
                            L10n.text("disk_status.io.read"),
                            point.readBytesPerSecond
                        ),
                        width: 4
                    )
                    .foregroundStyle(Color.blue)

                    BarMark(
                        x: .value(L10n.text("disk_status.chart.time"), point.timestamp),
                        yStart: .value("zero", 0),
                        yEnd: .value(
                            L10n.text("disk_status.io.write"),
                            -point.writeBytesPerSecond
                        ),
                        width: 4
                    )
                    .foregroundStyle(Color.pink)
                }
            }
            .chartXScale(domain: chartTimeDomain)
            .chartYScale(domain: -chartMaximum...chartMaximum)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 76)
            .clipped()
            .overlay {
                if !hasMeasuredRates {
                    HStack(spacing: 7) {
                        ProgressView()
                            .controlSize(.small)
                        Text(L10n.text("disk_status.sampling"))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .accessibilityLabel(L10n.text("disk_status.chart.accessibility"))

            HStack {
                Text(L10n.text(
                    "disk_status.io.peak_read",
                    DiskIOFormat.rate(peakRead)
                ))
                Spacer()
                Text(L10n.text("disk_status.io.window"))
                Spacer()
                Text(L10n.text(
                    "disk_status.io.peak_write",
                    DiskIOFormat.rate(peakWrite)
                ))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .diskStatusCardStyle()
    }

    private var chartTimeDomain: ClosedRange<Date> {
        let end = history.last?.timestamp ?? Date()
        return end.addingTimeInterval(-60)...end
    }
}

private struct ThroughputMetric: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.title2.monospacedDigit())
            HStack(spacing: 5) {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                Text(title)
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
        }
    }
}

private struct ProcessDiskIOList: View {
    let activities: [ApplicationDiskIOActivity]
    let coverage: DiskIOCoverage
    let hasMeasuredRates: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("disk_status.process.title"))
                        .font(.headline)
                    Text(L10n.text("disk_status.process.detail"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(L10n.text(
                    "disk_status.process.coverage",
                    coverage.readableProcesses.formatted(),
                    coverage.discoveredProcesses.formatted()
                ))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(
                        coverage.permissionDeniedProcesses > 0
                            ? Color.orange
                            : Color.secondary
                    )
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)

            HStack {
                Text(L10n.text("disk_status.process.application"))
                Spacer()
                Text(L10n.text("disk_status.process.read"))
                    .frame(width: 140, alignment: .trailing)
                Text(L10n.text("disk_status.process.write"))
                    .frame(width: 140, alignment: .trailing)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 18)
            .padding(.vertical, 7)
            .background(Color.secondary.opacity(0.055))

            if !hasMeasuredRates {
                VStack(spacing: 10) {
                    ProgressView()
                    Text(L10n.text("disk_status.sampling"))
                        .font(.callout.weight(.medium))
                    Text(L10n.text("disk_status.loading.detail"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if activities.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "internaldrive")
                        .font(.system(size: 26))
                        .foregroundStyle(.secondary)
                    Text(L10n.text("disk_status.process.empty"))
                        .font(.headline)
                    Text(L10n.text("disk_status.process.empty_detail"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(activities.prefix(100)) { activity in
                            HStack(spacing: 10) {
                                ApplicationIconView(path: activity.bundlePath, size: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(activity.name)
                                        .font(.callout.weight(.medium))
                                        .lineLimit(1)
                                    Text(L10n.text(
                                        "disk_status.process.count",
                                        activity.processCount.formatted()
                                    ))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 12)
                                DiskIORateValue(
                                    value: activity.readBytesPerSecond,
                                    color: .blue
                                )
                                DiskIORateValue(
                                    value: activity.writeBytesPerSecond,
                                    color: .pink
                                )
                            }
                            .padding(.horizontal, 18)
                            .padding(.vertical, 8)

                            Divider()
                                .padding(.leading, 56)
                        }
                    }
                }
            }
        }
    }
}

private struct DiskIORateValue: View {
    let value: Double
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Capsule()
                .fill(color.opacity(value > 0 ? 0.85 : 0.12))
                .frame(width: 24, height: 4)
            Text(DiskIOFormat.rate(value))
                .font(.callout.monospacedDigit())
                .frame(width: 104, alignment: .trailing)
        }
        .frame(width: 140, alignment: .trailing)
    }
}

private enum DiskIOFormat {
    static func bytes(_ value: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.isAdaptive = true
        formatter.includesUnit = true
        formatter.includesCount = true
        let bounded = value > UInt64(Int64.max) ? Int64.max : Int64(value)
        return formatter.string(fromByteCount: bounded)
    }

    static func rate(_ value: Double) -> String {
        let bounded = value.isFinite && value > 0
            ? UInt64(min(value, Double(UInt64.max)))
            : 0
        return L10n.text("disk_status.rate", bytes(bounded))
    }
}

private extension View {
    func diskStatusCardStyle() -> some View {
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
