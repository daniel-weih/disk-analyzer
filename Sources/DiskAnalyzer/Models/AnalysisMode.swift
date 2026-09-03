import SwiftUI

enum AnalysisMode: String, CaseIterable, Identifiable {
    case diskStatus
    case diskSpace
    case swapSpace
    case tools

    var id: String { rawValue }

    var title: String {
        switch self {
        case .diskStatus:
            return L10n.text("analysis.mode.status")
        case .diskSpace:
            return L10n.text("analysis.mode.disk")
        case .swapSpace:
            return L10n.text("analysis.mode.swap")
        case .tools:
            return L10n.text("analysis.mode.tools")
        }
    }
}

struct AnalysisModePicker: View {
    @Binding var selection: AnalysisMode?
    var isDisabled = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(AnalysisMode.allCases) { mode in
                AnalysisNavigationButton(
                    title: mode.title,
                    isSelected: selection == mode,
                    action: { selection = mode }
                )
                .help(L10n.text("analysis.mode.help"))
            }
        }
        .disabled(isDisabled)
    }
}

struct AnalysisNavigationBar: View {
    @Binding var selection: AnalysisMode?
    var isModeSwitchDisabled = false
    let onShowHome: () -> Void
    let onShowSettings: () -> Void

    var body: some View {
        ZStack {
            HStack {
                HStack(spacing: 10) {
                    AppMarkView()
                    Text(L10n.text("app.title"))
                        .font(.system(size: 13, weight: .semibold))
                }

                Spacer()

                Button(action: onShowSettings) {
                    Label(L10n.text("toolbar.settings"), systemImage: "gearshape")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(L10n.text("toolbar.settings.help"))
            }

            HStack(spacing: 10) {
                AnalysisNavigationButton(
                    title: L10n.text("toolbar.home"),
                    systemImage: "house",
                    isSelected: selection == nil
                ) {
                    selection = nil
                    onShowHome()
                }
                .disabled(isModeSwitchDisabled)
                .help(L10n.text("toolbar.home.help"))

                Divider()
                    .frame(height: 20)

                AnalysisModePicker(
                    selection: $selection,
                    isDisabled: isModeSwitchDisabled
                )
                .fixedSize()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(.bar)
    }
}

private struct AnalysisNavigationButton: View {
    let title: String
    var systemImage: String?
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 14)
                }

                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? Color.white : Color.primary.opacity(0.82))
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background {
                Capsule(style: .continuous)
                    .fill(backgroundColor)
            }
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
        .contentShape(Capsule(style: .continuous))
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var backgroundColor: Color {
        if isSelected {
            return .accentColor
        }
        if isHovering && isEnabled {
            return Color.primary.opacity(0.08)
        }
        return .clear
    }
}

private struct AppMarkView: View {
    var body: some View {
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
        .accessibilityHidden(true)
    }
}
