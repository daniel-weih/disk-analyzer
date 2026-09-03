import SwiftUI

struct ScanControlView: View {
    @ObservedObject var controller: ScanController
    let onChooseDirectory: () -> Void
    let onRescan: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 8) {
                Label {
                    Text(controller.toolbarScanURL?.path ?? L10n.text("toolbar.no_location"))
                        .lineLimit(1)
                        .truncationMode(.middle)
                } icon: {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 11))
                .frame(maxWidth: 320, alignment: .leading)
                .help(controller.toolbarScanURL?.path ?? L10n.text("toolbar.no_location"))

                Button(L10n.text("toolbar.choose_directory"), action: onChooseDirectory)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(controller.cleanupPhase.isActive)
            }

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                Text(L10n.text("toolbar.metric"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)

                Picker(L10n.text("toolbar.metric"), selection: $controller.metric) {
                    ForEach(SizeMetric.allCases) { metric in
                        Text(metric.title).tag(metric)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 190)
                .help(controller.metric.shortExplanation)

                Button(action: onRescan) {
                    Label(L10n.text("toolbar.rescan"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(controller.cleanupPhase.isActive)
            }
        }
    }
}
