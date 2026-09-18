import AppKit
import SwiftUI

/// A passive drag assistant attached visually to System Settings, not to the
/// app's modal sheet. Only public window geometry is inspected; no AX access,
/// screen capture, or programmatic permission changes are required.
@MainActor
final class FullDiskAccessDragAssistant {
    static let shared = FullDiskAccessDragAssistant()
    private var panel: NSPanel?
    private var timer: Timer?
    private var startedAt = Date.distantPast
    private var lastProbe = Date.distantPast
    private var onGranted: (() -> Void)?
    private var onBack: (() -> Void)?
    private var onFallback: (() -> Void)?
    private var hasShownOverlay = false
    var isActive: Bool { panel != nil }

    func present(onGranted: @escaping () -> Void, onBack: @escaping () -> Void,
                 onFallback: @escaping () -> Void) {
        dismiss()
        self.onGranted = onGranted
        self.onBack = onBack
        self.onFallback = onFallback
        hasShownOverlay = false
        startedAt = Date()
        let panel = PermissionDragPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 116),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: PermissionDragStrip(onBack: { [weak self] in
            guard let self else { return }
            let callback = self.onBack
            self.dismiss()
            NSApp.activate(ignoringOtherApps: true)
            callback?()
        }))
        self.panel = panel
        FinderBridge.openFullDiskAccessSettings()
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.update() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        update()
    }

    func dismiss() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        onGranted = nil
        onBack = nil
        onFallback = nil
        lastProbe = .distantPast
    }

    private func update() {
        guard let panel else { return }
        // Never leave an orphaned overlay following Settings indefinitely.
        guard Date().timeIntervalSince(startedAt) < 300 else { restoreGuide(); return }
        if Date().timeIntervalSince(lastProbe) >= 1 {
            lastProbe = Date()
            if FullDiskAccessProbe.check().isGranted {
                let callback = onGranted
                dismiss()
                callback?()
                return
            }
        }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier == "com.apple.systempreferences" else {
            panel.orderOut(nil)
            if !hasShownOverlay && Date().timeIntervalSince(startedAt) > 10 { restoreGuide() }
            return
        }
        let snapshot = settingsWindow(pid: app.processIdentifier)
        let decision = PermissionDragPagePolicy.decision(
            title: snapshot?.title, hasGeometry: snapshot != nil,
            elapsed: Date().timeIntervalSince(startedAt), hasShownOverlay: hasShownOverlay
        )
        guard decision == .show else {
            panel.orderOut(nil)
            if decision == .fallback { restoreGuide() }
            return
        }
        guard let frame = snapshot?.frame,
              let screen = NSScreen.screens.max(by: {
                  $0.frame.intersection(frame).area < $1.frame.intersection(frame).area
              }) else {
            // Do not guess where the permission list is when geometry is unavailable.
            panel.orderOut(nil)
            restoreGuide()
            return
        }
        let target = PermissionDragGeometry.overlayFrame(settings: frame, visible: screen.visibleFrame)
        if panel.frame != target { panel.setFrame(target, display: true) }
        if !panel.isVisible { panel.orderFrontRegardless() }
        hasShownOverlay = true
    }

    private func restoreGuide() {
        let callback = onFallback
        dismiss()
        // Restore the app's guide without stealing focus from System Settings.
        callback?()
    }

    private func settingsWindow(pid: pid_t) -> (frame: CGRect, title: String?)? {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]], let desktop = NSScreen.screens.first else { return nil }
        // CG coordinates have their origin at the top-left of the primary display.
        // AppKit's global coordinates have their origin at its bottom-left.
        for window in windows {
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds),
                  rect.width >= 450, rect.height >= 350 else { continue }
            return (CGRect(x: rect.minX, y: desktop.frame.maxY - rect.maxY,
                           width: rect.width, height: rect.height),
                    window[kCGWindowName as String] as? String)
        }
        return nil
    }
}

enum PermissionDragPagePolicy {
    enum Decision { case wait, show, fallback }

    static func decision(title: String?, hasGeometry: Bool, elapsed: TimeInterval,
                         hasShownOverlay: Bool) -> Decision {
        // Window titles may be redacted without Screen Recording permission.
        // Never request that permission merely to show an onboarding overlay.
        let title = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let knownTitles = ["Full Disk Access", "完全磁盘访问权限", "完全磁盘访问", "完整磁碟存取權", "完整磁碟存取"]
        if hasGeometry && knownTitles.contains(where: { $0.caseInsensitiveCompare(title) == .orderedSame }) {
            return .show
        }
        // Allow the deep link to load initially; after display, fail closed as
        // soon as the user changes pages or Settings stops exposing its title.
        return hasShownOverlay || elapsed >= 3 ? .fallback : .wait
    }
}

enum PermissionDragGeometry {
    static func overlayFrame(settings: CGRect, visible: CGRect) -> CGRect {
        let width = min(420, max(280, settings.width - 32), visible.width - 16)
        let height: CGFloat = 116
        let x = min(max(settings.maxX - width - 16, visible.minX + 8), visible.maxX - width - 8)
        let y = min(max(settings.minY + 12, visible.minY + 8), visible.maxY - height - 8)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}

private final class PermissionDragPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

struct PermissionDragStrip: View {
    let onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 9) {
                Image(systemName: "arrow.up").font(.system(size: 20, weight: .bold)).foregroundStyle(.blue)
                Text(L10n.text("fda.overlay.title")).font(.system(size: 12, weight: .medium))
            }
            HStack(spacing: 10) {
                Button(action: onBack) { Image(systemName: "chevron.left").frame(width: 24, height: 30) }
                    .buttonStyle(.borderless)
                    .help(L10n.text("fda.overlay.back"))
                PermissionApplicationDragRow().frame(height: 36)
                    .background(.background, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.quaternary))
            }
            Text(L10n.text("fda.overlay.detail")).font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.quaternary))
    }
}

private struct PermissionApplicationDragRow: NSViewRepresentable {
    func makeNSView(context: Context) -> PermissionApplicationDragRowView {
        PermissionApplicationDragRowView()
    }
    func updateNSView(_ view: PermissionApplicationDragRowView, context: Context) {}
}

private final class PermissionApplicationDragRowView: NSView, NSDraggingSource {
    private let icon = NSWorkspace.shared.icon(forFile: Bundle.main.bundleURL.path)
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(L10n.text("drag.accessibility.label"))
        setAccessibilityHelp(L10n.text("drag.accessibility.help"))
        toolTip = L10n.text("drag.tooltip")
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func draw(_ dirtyRect: NSRect) {
        icon.draw(in: NSRect(x: 9, y: (bounds.height - 24) / 2, width: 24, height: 24))
        (L10n.text("app.title") as NSString).draw(
            at: NSPoint(x: 42, y: (bounds.height - 16) / 2),
            withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium),
                             .foregroundColor: NSColor.labelColor]
        )
    }
    override func mouseDragged(with event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: ApplicationDragPayload.makePasteboardItem(for: Bundle.main.bundleURL))
        let point = convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(NSRect(x: point.x - 16, y: point.y - 16, width: 32, height: 32), contents: icon)
        beginDraggingSession(with: [item], event: event, source: self).animatesToStartingPositionsOnCancelOrFail = true
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
}
