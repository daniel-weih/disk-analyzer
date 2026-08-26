import AppKit
import SwiftUI

struct DraggableApplicationIconView: NSViewRepresentable {
    let applicationURL: URL

    func makeNSView(context: Context) -> DraggableApplicationImageView {
        let view = DraggableApplicationImageView(applicationURL: applicationURL)
        view.image = NSWorkspace.shared.icon(forFile: applicationURL.path)
        view.imageScaling = .scaleProportionallyUpOrDown
        view.isEditable = false
        view.isEnabled = true
        view.toolTip = L10n.text("drag.tooltip")
        view.setAccessibilityLabel(L10n.text("drag.accessibility.label"))
        view.setAccessibilityHelp(L10n.text("drag.accessibility.help"))
        return view
    }

    func updateNSView(
        _ nsView: DraggableApplicationImageView,
        context: Context
    ) {
        nsView.applicationURL = applicationURL
        nsView.image = NSWorkspace.shared.icon(forFile: applicationURL.path)
        nsView.toolTip = L10n.text("drag.tooltip")
        nsView.setAccessibilityLabel(L10n.text("drag.accessibility.label"))
        nsView.setAccessibilityHelp(L10n.text("drag.accessibility.help"))
    }
}

enum ApplicationDragPayload {
    static func makePasteboardItem(for applicationURL: URL) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(applicationURL.absoluteString, forType: .fileURL)
        return item
    }
}

@MainActor
final class DraggableApplicationImageView: NSImageView, NSDraggingSource {
    var applicationURL: URL

    init(applicationURL: URL) {
        self.applicationURL = applicationURL
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }

        while let nextEvent = window.nextEvent(
            matching: [.leftMouseDragged, .leftMouseUp],
            until: .distantFuture,
            inMode: .eventTracking,
            dequeue: true
        ) {
            switch nextEvent.type {
            case .leftMouseDragged:
                beginApplicationDrag(with: nextEvent)
                return
            case .leftMouseUp:
                return
            default:
                continue
            }
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    private func beginApplicationDrag(with event: NSEvent) {
        let draggingItem = NSDraggingItem(
            pasteboardWriter: ApplicationDragPayload.makePasteboardItem(
                for: applicationURL
            )
        )
        draggingItem.setDraggingFrame(
            bounds.insetBy(dx: 4, dy: 4),
            contents: image
        )

        let session = beginDraggingSession(
            with: [draggingItem],
            event: event,
            source: self
        )
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }
}
