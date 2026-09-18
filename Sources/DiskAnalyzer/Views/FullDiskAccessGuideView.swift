import AppKit
import SwiftUI

struct FullDiskAccessSetupCard: View {
    let status: FullDiskAccessConfirmationStatus
    let onShowGuide: () -> Void

    private var isReady: Bool { status == .confirmed }
    private var tint: Color { isReady ? .green : .orange }
    private var iconName: String { isReady ? "checkmark.shield.fill" : "lock.shield.fill" }

    private var title: String {
        switch status {
        case .confirmed:
            return L10n.text("fda.card.confirmed.title")
        case .appIdentityChanged:
            return L10n.text("fda.card.identity_changed.title")
        case .unableToVerify:
            return L10n.text("fda.card.unavailable.title")
        case .notConfirmed:
            return L10n.text("fda.card.not_confirmed.title")
        }
    }

    private var detail: String {
        switch status {
        case .confirmed:
            return L10n.text("fda.card.confirmed.detail")
        case .appIdentityChanged:
            return L10n.text("fda.card.identity_changed.detail")
        case .unableToVerify:
            return L10n.text("fda.card.unavailable.detail")
        case .notConfirmed:
            return L10n.text("fda.card.not_confirmed.detail")
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: iconName)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 42, height: 42)
                .background(
                    tint.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 10)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            if isReady {
                Button(L10n.text("common.view"), action: onShowGuide)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            } else {
                Button(L10n.text("common.authorize"), action: onShowGuide)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(13)
        .background(
            tint.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(tint.opacity(0.25), lineWidth: 1)
        }
    }
}

struct FullDiskAccessGuideView: View {
    var overlayUnavailable = false
    let hasPendingScan: Bool
    let confirmationStatus: FullDiskAccessConfirmationStatus
    let probeResult: FullDiskAccessProbeResult
    let didAttemptPermissionCheck: Bool
    let onOpenSettings: () -> Void
    let onRevealApplication: () -> Void
    let onCheckPermission: () -> Void
    let onContinueWithoutPermission: () -> Void
    let onCancel: () -> Void

    private var applicationURL: URL { Bundle.main.bundleURL }

    private var appDisplayName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? applicationURL.deletingPathExtension().lastPathComponent
    }

    private var isInstalledInApplications: Bool {
        let appPath = applicationURL.standardizedFileURL.path
        let systemApplications = "/Applications/"
        let userApplications = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
            .standardizedFileURL.path + "/"
        return appPath.hasPrefix(systemApplications) || appPath.hasPrefix(userApplications)
    }

    var body: some View {
        Group {
            if isInstalledInApplications {
                permissionView
            } else {
                installationView
            }
        }
        .padding(26)
        .frame(width: 480)
    }

    private var permissionView: some View {
        VStack(spacing: 18) {
            permissionHeader

            if confirmationStatus == .confirmed {
                confirmationView
            } else {
                if confirmationStatus == .appIdentityChanged {
                    Label(
                        L10n.text("fda.updated_notice"),
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
                }

                Button(action: onOpenSettings) {
                    Label(L10n.text("fda.open_settings"), systemImage: "gearshape.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Label(L10n.text(overlayUnavailable ? "fda.overlay.fallback" : "fda.overlay.intro"), systemImage: "hand.draw")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Button(action: onRevealApplication) {
                        Label(L10n.text("fda.reveal_app"), systemImage: "finder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button(action: onCheckPermission) {
                        Label(L10n.text("fda.recheck"), systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }

                permissionStatusView

                Text(L10n.text("fda.drag_fallback", appDisplayName))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Button(L10n.text("fda.not_now"), action: onCancel)
                        .buttonStyle(.bordered)

                    if hasPendingScan {
                        Button(L10n.text("fda.skip_continue"), action: onContinueWithoutPermission)
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Label(L10n.text("fda.privacy"), systemImage: "hand.raised.fill")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    private var permissionHeader: some View {
        HStack(spacing: 15) {
            Image(systemName: confirmationStatus == .confirmed ? "checkmark.shield.fill" : "lock.shield.fill")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(confirmationStatus == .confirmed ? .green : .orange)
                .frame(width: 58, height: 58)
                .background(
                    (confirmationStatus == .confirmed ? Color.green : Color.orange).opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 15)
                )

            VStack(alignment: .leading, spacing: 5) {
                Text(
                    confirmationStatus == .confirmed
                        ? L10n.text("fda.header.confirmed")
                        : L10n.text("fda.header.request", appDisplayName)
                )
                    .font(.system(size: 21, weight: .semibold, design: .rounded))
                Text(L10n.text("fda.header.detail"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
    }


    @ViewBuilder
    private var permissionStatusView: some View {
        switch probeResult {
        case .granted:
            EmptyView()
        case .denied where didAttemptPermissionCheck:
            Label(L10n.text("fda.status.denied"), systemImage: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
                .permissionStatusStyle()
        case .unavailable:
            Label(L10n.text("fda.status.unavailable"), systemImage: "questionmark.circle.fill")
                .foregroundStyle(.secondary)
                .permissionStatusStyle()
        default:
            EmptyView()
        }
    }

    private var confirmationView: some View {
        VStack(spacing: 14) {
            Label(L10n.text("fda.confirmed.probe"), systemImage: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.green)
                .padding(13)
                .frame(maxWidth: .infinity)
                .background(Color.green.opacity(0.09), in: RoundedRectangle(cornerRadius: 11))

            Button(L10n.text("common.done"), action: onCancel)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
        }
    }

    private var installationView: some View {
        VStack(spacing: 22) {
            Image(systemName: "arrow.down.app.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.blue)
                .frame(width: 64, height: 64)
                .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))

            VStack(spacing: 8) {
                Text(L10n.text("fda.install.title", appDisplayName))
                    .font(.system(size: 22, weight: .semibold, design: .rounded))

                Text(L10n.text("fda.install.detail", appDisplayName))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button(L10n.text("fda.got_it"), action: onCancel)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
        }
    }
}


private extension View {
    func permissionStatusStyle() -> some View {
        font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
    }
}
