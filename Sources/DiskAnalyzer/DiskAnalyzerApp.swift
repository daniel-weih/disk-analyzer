import AppKit
import SwiftUI

@MainActor
final class DiskAnalyzerAppDelegate: NSObject, NSApplicationDelegate {
    let mainWindowLifecycle = MainWindowLifecycle()

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Dock clicks must restore our retained main window, even if an auxiliary
        // panel is visible. Returning false suppresses automatic new-window creation.
        !mainWindowLifecycle.reopen()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return }

        let currentProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        let existingInstance = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter {
                $0.processIdentifier != currentProcessIdentifier
                    && !$0.isTerminated
                    && $0.processIdentifier < currentProcessIdentifier
            }
            .min { $0.processIdentifier < $1.processIdentifier }

        guard let existingInstance else { return }
        existingInstance.activate(options: [.activateAllWindows])
        NSApp.terminate(nil)
    }
}

@main
struct DiskAnalyzerApp: App {
    @NSApplicationDelegateAdaptor(DiskAnalyzerAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup(L10n.text("app.title")) {
            ContentView()
                .background {
                    MainWindowRegistration(lifecycle: appDelegate.mainWindowLifecycle)
                        .frame(width: 0, height: 0)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1240, height: 800)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
