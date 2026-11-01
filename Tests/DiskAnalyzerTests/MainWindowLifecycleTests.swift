import AppKit
import SwiftUI
import Testing
@testable import DiskAnalyzer

@MainActor
@Suite("Main window reopening", .serialized)
struct MainWindowLifecycleTests {
    @Test("Closing and reopening preserves the same window and content")
    func closeAndReopen() throws {
        let application = NSApplication.shared
        let delegate = DiskAnalyzerAppDelegate()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false
        )
        let content = NSHostingView(rootView:
            Text("Retained scan results")
                .background(MainWindowRegistration(lifecycle: delegate.mainWindowLifecycle))
        )
        window.contentView = content
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        content.layoutSubtreeIfNeeded()

        for _ in 0..<3 {
            window.performClose(nil)
            #expect(!window.isVisible)
            let useDefaultHandling = delegate.applicationShouldHandleReopen(application, hasVisibleWindows: false)
            #expect(!useDefaultHandling)
            #expect(window.isVisible)
            #expect(window.contentView === content)
        }

        // A visible permission panel must not prevent restoring the main window.
        window.performClose(nil)
        #expect(!delegate.applicationShouldHandleReopen(application, hasVisibleWindows: true))
        #expect(window.isVisible)
        #expect(window.contentView === content)
    }

    @Test("Reopening before the main window exists permits normal launch handling")
    func reopenBeforeRegistration() {
        let delegate = DiskAnalyzerAppDelegate()
        #expect(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false))
    }
}
