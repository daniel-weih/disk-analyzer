import AppKit

@main
enum InstallerMain {
    static let source = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent(AppInstaller.appName)
    static let destination = URL(fileURLWithPath: "/Applications/\(AppInstaller.appName)")

    static func main() {
        let arguments = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-psn_") }
        if arguments == ["--verify-only"] {
            do {
                try AppInstaller.validatePayload(source)
                print("Installer payload verified")
            } catch { fail(error) }
            return
        }
        if arguments.first == "--cli" {
            // Explicit paths allow deployment tools and isolated integration checks
            // to exercise the exact installation workflow without opening a window.
            guard arguments.count == 5, arguments[1] == "--source", arguments[3] == "--destination" else {
                fail(InstallationError(message: "Usage: --cli --source <app> --destination <app>"))
            }
            do {
                var installer = AppInstaller()
                installer.stopApplication = InstalledApplication.stop
                let outcome = try installer.install(from: URL(fileURLWithPath: arguments[2]), to: URL(fileURLWithPath: arguments[4]))
                print(outcome == .alreadyInstalled ? "DiskAnalyzer is already installed" : "DiskAnalyzer installed successfully")
            } catch { fail(error) }
            return
        }
        guard arguments.isEmpty else { fail(InstallationError(message: "Unknown installer arguments")) }
        let app = NSApplication.shared
        let delegate = InstallerDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }

    static func fail(_ error: Error) -> Never {
        FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
        exit(1)
    }
}

final class InstallerDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private let status = NSTextField(labelWithString: "")
    private var installing = false
    private var launchHandoff: InstallerLaunchHandoff?

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 200),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.title = InstallerText.choose("安装或更新 DiskAnalyzer", "Install or Update DiskAnalyzer")
        window.isReleasedWhenClosed = false
        let icon = NSImageView(frame: NSRect(x: 30, y: 93, width: 64, height: 64))
        icon.image = NSApp.applicationIconImage
        window.contentView?.addSubview(icon)
        let title = NSTextField(labelWithString: InstallerText.choose("正在准备 DiskAnalyzer", "Preparing DiskAnalyzer"))
        title.font = .systemFont(ofSize: 19, weight: .semibold)
        title.frame = NSRect(x: 112, y: 128, width: 325, height: 26)
        window.contentView?.addSubview(title)
        let detail = NSTextField(labelWithString: InstallerText.choose("偏好设置将保留", "Your preferences will be preserved"))
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.frame = NSRect(x: 112, y: 102, width: 325, height: 20)
        window.contentView?.addSubview(detail)
        let indicator = NSProgressIndicator(frame: NSRect(x: 32, y: 65, width: 396, height: 8))
        indicator.style = .bar
        indicator.isIndeterminate = true
        indicator.startAnimation(nil)
        window.contentView?.addSubview(indicator)
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        status.frame = NSRect(x: 32, y: 29, width: 396, height: 23)
        window.contentView?.addSubview(status)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        startInstallation()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        installing ? .terminateCancel : .terminateNow
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if installing { window.makeKeyAndOrderFront(nil) }
        return true
    }

    private func startInstallation() {
        guard !installing, launchHandoff == nil else { return }
        installing = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                var installer = AppInstaller()
                installer.stopApplication = InstalledApplication.stop
                installer.progress = { message in
                    DispatchQueue.main.async { self.status.stringValue = message }
                }
                let outcome = try installer.install(from: InstallerMain.source, to: InstallerMain.destination)
                let image = InstallerDiskImageEjector.prepare(installerURL: Bundle.main.bundleURL, destination: InstallerMain.destination)
                DispatchQueue.main.async { self.finishInstallation(outcome, sourceImage: image) }
            } catch {
                DispatchQueue.main.async { self.showFailure(error) }
            }
        }
    }

    private func finishInstallation(_ outcome: AppInstaller.Outcome, sourceImage: InstallerDiskImageEjector.Target?) {
        // The app is safely in place now. Quitting must no longer be vetoed
        // while Launch Services opens (or activates) the installed application.
        installing = false
        status.stringValue = outcome == .alreadyInstalled
            ? InstallerText.choose("已安装当前版本，正在打开…", "Already installed. Opening DiskAnalyzer…")
            : InstallerText.choose("安装完成，正在打开…", "Installed. Opening DiskAnalyzer…")
        window.orderOut(nil)
        let handoff = InstallerLaunchHandoff()
        launchHandoff = handoff
        handoff.start(open: { completion in
            InstalledApplication.open(at: InstallerMain.destination) { _, error in
                completion(error)
            }
        }, onOpened: {
            if let sourceImage { try? InstallerDiskImageEjector.schedule(sourceImage) }
        }, completion: { outcome in
            if case .failed(let error) = outcome {
                let alert = NSAlert()
                alert.messageText = InstallerText.choose("安装已完成", "Installation complete")
                alert.informativeText = InstallerText.choose(
                    "可从“应用程序”打开 DiskAnalyzer。\n\(error.localizedDescription)",
                    "Open DiskAnalyzer from Applications.\n\(error.localizedDescription)")
                alert.runModal()
            }
            NSApp.terminate(nil)
        })
    }

    private func showFailure(_ error: Error) {
        installing = false
        status.stringValue = InstallerText.choose("安装未完成", "Installation did not complete")
        let alert = NSAlert()
        alert.messageText = InstallerText.choose("无法安装 DiskAnalyzer", "Could not install DiskAnalyzer")
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: InstallerText.choose("重试", "Retry"))
        alert.addButton(withTitle: InstallerText.choose("关闭", "Close"))
        if alert.runModal() == .alertFirstButtonReturn { startInstallation() }
        else { NSApp.terminate(nil) }
    }
}
