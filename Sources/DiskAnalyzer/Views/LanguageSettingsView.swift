import AppKit
import SwiftUI

struct LanguageSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var languageCode: String

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 13) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(.blue)
                    .frame(width: 44, height: 44)
                    .background(Color.blue.opacity(0.11), in: RoundedRectangle(cornerRadius: 11))

                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.text("settings.title"))
                        .font(.system(size: 19, weight: .semibold))
                    Text(L10n.text("settings.subtitle"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            VStack(alignment: .leading, spacing: 9) {
                Text(L10n.text("settings.language.title"))
                    .font(.system(size: 12, weight: .semibold))

                Picker("", selection: $languageCode) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.selectionTitle).tag(language.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Text(L10n.text("settings.language.detail"))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .background(
                Color(nsColor: .controlBackgroundColor).opacity(0.72),
                in: RoundedRectangle(cornerRadius: 12)
            )

            HStack {
                Spacer()
                Button(L10n.text("common.done")) { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}

struct WindowTitleConfigurator: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        updateWindowTitle(from: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        updateWindowTitle(from: nsView)
    }

    private func updateWindowTitle(from view: NSView) {
        DispatchQueue.main.async {
            view.window?.title = title
        }
    }
}
