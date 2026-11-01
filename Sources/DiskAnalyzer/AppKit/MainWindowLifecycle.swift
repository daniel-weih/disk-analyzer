import AppKit
import SwiftUI

/// Retains the main window after closing so reopening also retains its scan state.
@MainActor
final class MainWindowLifecycle {
    private var mainWindow: NSWindow?

    func register(_ window: NSWindow) {
        window.isReleasedWhenClosed = false
        mainWindow = window
    }

    @discardableResult
    func reopen() -> Bool {
        guard let window = mainWindow else { return false }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        return true
    }
}

/// Captures only the window hosting ContentView, without replacing SwiftUI's delegate.
struct MainWindowRegistration: NSViewRepresentable {
    let lifecycle: MainWindowLifecycle

    func makeNSView(context: Context) -> RegistrationView {
        RegistrationView(lifecycle: lifecycle)
    }

    func updateNSView(_ nsView: RegistrationView, context: Context) {
        if let window = nsView.window {
            lifecycle.register(window)
        }
    }

    final class RegistrationView: NSView {
        private let lifecycle: MainWindowLifecycle

        init(lifecycle: MainWindowLifecycle) {
            self.lifecycle = lifecycle
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                lifecycle.register(window)
            }
        }
    }
}
