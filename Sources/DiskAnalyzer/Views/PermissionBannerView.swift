import AppKit
import SwiftUI

struct ScanCoverageBannerView: View {
    let diagnostics: ScanDiagnostics
    @State private var isShowingDetails = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text(
                    "coverage.banner.title",
                    diagnostics.issueCount.formatted()
                ))
                    .font(.system(size: 12, weight: .semibold))
                Text(L10n.text(
                    "coverage.banner.detail",
                    diagnostics.coverageSummary ?? L10n.text("coverage.banner.fallback")
                ))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(L10n.text("coverage.banner.view_items")) {
                isShowingDetails = true
            }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(diagnostics.issues.isEmpty)
        }
        .padding(9)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .sheet(isPresented: $isShowingDetails) {
            ScanIssuesDetailView(diagnostics: diagnostics)
        }
    }
}

private struct ScanIssuesDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let diagnostics: ScanDiagnostics
    @State private var didCopy = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "list.bullet.rectangle.portrait")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.orange)
                    .frame(width: 44, height: 44)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.text("coverage.detail.title"))
                        .font(.system(size: 19, weight: .semibold))
                    Text(L10n.text("coverage.detail.explanation"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Button(L10n.text(didCopy ? "common.copied" : "common.copy_all")) {
                    copyAllIssues()
                }
                .buttonStyle(.bordered)

                Button(L10n.text("common.done")) { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(18)

            Divider()

            List {
                if !diagnostics.unreadableDirectoryIssues.isEmpty {
                    Section(L10n.text(
                        "coverage.detail.unreadable_section",
                        diagnostics.unreadableDirectoryIssues.count.formatted()
                    )) {
                        ForEach(diagnostics.unreadableDirectoryIssues) { issue in
                            ScanIssueRow(issue: issue)
                        }
                    }
                }

                if !diagnostics.metadataIssues.isEmpty {
                    Section(L10n.text(
                        "coverage.detail.metadata_section",
                        diagnostics.metadataIssues.count.formatted()
                    )) {
                        ForEach(diagnostics.metadataIssues) { issue in
                            ScanIssueRow(issue: issue)
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
        .frame(width: 900, height: 620)
    }

    private func copyAllIssues() {
        let text = diagnostics.issues.map { issue in
            "[\(issue.kind.title)] \(issue.path)\n  \(issue.errorDescription)"
        }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        didCopy = true
    }
}

private struct ScanIssueRow: View {
    let issue: ScanIssue

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: issue.kind.systemImage)
                .foregroundStyle(.orange)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                Text(issue.path)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                Text(issue.errorDescription)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 12)

            Button {
                FinderBridge.reveal(URL(fileURLWithPath: issue.path))
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help(L10n.text("common.reveal_finder"))
        }
        .padding(.vertical, 3)
    }
}

struct SkippedVolumesBannerView: View {
    let diagnostics: ScanDiagnostics
    @State private var isShowingDetails = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "externaldrive")
                .foregroundStyle(.blue)
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text(
                    "skipped.banner.title",
                    diagnostics.skippedVolumeCount.formatted()
                ))
                    .font(.system(size: 12, weight: .semibold))
                Text(L10n.text(
                    "skipped.banner.detail",
                    diagnostics.skippedVolumeNamesPreview
                        ?? L10n.text("skipped.banner.fallback")
                ))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(L10n.text("skipped.banner.view")) {
                isShowingDetails = true
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(diagnostics.skippedVolumes.isEmpty)
        }
        .padding(9)
        .background(Color.blue.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .sheet(isPresented: $isShowingDetails) {
            SkippedVolumesDetailView(diagnostics: diagnostics)
        }
    }
}

struct SkippedVolumesDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let diagnostics: ScanDiagnostics
    @State private var didCopy = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "externaldrive.badge.xmark")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.blue)
                    .frame(width: 44, height: 44)
                    .background(Color.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.text(
                        "skipped.detail.title",
                        diagnostics.skippedVolumeCount.formatted()
                    ))
                        .font(.system(size: 19, weight: .semibold))
                    Text(L10n.text("skipped.detail.explanation"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Button(L10n.text(didCopy ? "common.copied" : "common.copy_all")) {
                    copyAllVolumes()
                }
                .buttonStyle(.bordered)

                Button(L10n.text("common.done")) { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(18)

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(diagnostics.skippedVolumes) { volume in
                        SkippedVolumeRow(volume: volume)
                            .padding(.horizontal, 18)
                        Divider()
                            .padding(.leading, 53)
                    }
                }
                .padding(.vertical, 6)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .frame(width: 860, height: 560)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func copyAllVolumes() {
        let text = diagnostics.skippedVolumes.map { volume in
            "[\(volume.kind.title)] \(volume.name)\n  \(volume.path)"
        }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        didCopy = true
    }
}

private struct SkippedVolumeRow: View {
    let volume: SkippedVolumeInfo

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: volume.kind.systemImage)
                .foregroundStyle(.blue)
                .frame(width: 24, height: 24)
                .background(Color.blue.opacity(0.09), in: RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 3) {
                Text(volume.name)
                    .font(.system(size: 12, weight: .semibold))
                Text(volume.path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 12)

            Text(volume.kind.title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.08), in: Capsule())

            Button {
                FinderBridge.reveal(URL(fileURLWithPath: volume.path, isDirectory: true))
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help(L10n.text("common.reveal_finder"))
        }
        .padding(.vertical, 4)
    }
}
