import SwiftUI

struct ScanControlView: View {
    @ObservedObject var controller: ScanController
    let onShowHome: () -> Void
    let onShowLatestResult: () -> Void
    let onScanStartupDisk: () -> Void
    let onScanHomeDirectory: () -> Void
    let onChooseDirectory: () -> Void
    let onRescan: () -> Void
    let onShowSettings: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(
                        AngularGradient(
                            colors: [.blue, .cyan, .green, .yellow, .orange, .pink, .purple, .blue],
                            center: .center
                        )
                    )
                Circle()
                    .fill(.background)
                    .padding(6)
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 0) {
                Text(L10n.text("app.title"))
                    .font(.system(size: 13, weight: .semibold))
                Text(controller.toolbarScanURL?.path ?? L10n.text("toolbar.no_location"))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 290, alignment: .leading)
            }

            if controller.isPresentingResult {
                Button(action: onShowHome) {
                    Label(L10n.text("toolbar.home"), systemImage: "house")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(L10n.text("toolbar.home.help"))
            }

            Button(L10n.text("toolbar.choose_directory"), action: onChooseDirectory)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(controller.isScanning)

            Divider()
                .frame(height: 22)

            Picker(L10n.text("toolbar.metric"), selection: $controller.metric) {
                ForEach(SizeMetric.allCases) { metric in
                    Text(metric.title).tag(metric)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 190)
            .help(controller.metric.shortExplanation)

            Spacer()

            if controller.isScanning {
                ProgressView()
                    .controlSize(.small)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(L10n.text(
                        "toolbar.items",
                        controller.progress.scannedItems.formatted()
                    ))
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                    Text(
                        SizeFormatter.shared.string(
                            fromByteCount: controller.progress.allocatedBytes
                        )
                    )
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(.secondary)
                }
                Button(L10n.text("toolbar.cancel"), action: controller.cancelScan)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            } else if controller.isPresentingResult {
                Button(action: onRescan) {
                    Label(L10n.text("toolbar.rescan"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            } else {
                if controller.result != nil {
                    Button(action: onShowLatestResult) {
                        Label(L10n.text("toolbar.return_results"), systemImage: "chart.pie.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Menu {
                    Button(L10n.text("toolbar.startup_disk"), action: onScanStartupDisk)
                    Button(L10n.text("toolbar.home_directory"), action: onScanHomeDirectory)
                    Divider()
                    Button(L10n.text("toolbar.choose_other"), action: onChooseDirectory)
                } label: {
                    Label(L10n.text("toolbar.start_scan"), systemImage: "play.fill")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            Divider()
                .frame(height: 22)

            Button(action: onShowSettings) {
                Label(L10n.text("toolbar.settings"), systemImage: "gearshape")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(L10n.text("toolbar.settings.help"))
        }
    }
}
