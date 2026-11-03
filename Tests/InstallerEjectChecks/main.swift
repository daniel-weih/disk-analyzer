import Foundation

@main
enum InstallerEjectChecks {
    static func main() throws {
        guard CommandLine.arguments.count == 5 else { throw failure("Expected destination, mode, ready, and release paths") }
        let destination = URL(fileURLWithPath: CommandLine.arguments[1])
        let mode = CommandLine.arguments[2]
        let ready = URL(fileURLWithPath: CommandLine.arguments[3])
        let release = CommandLine.arguments[4]
        let bundle = Bundle.main.bundleURL
        let source = bundle.deletingLastPathComponent().appendingPathComponent(AppInstaller.appName)
        var installer = AppInstaller()
        installer.validate = { _ = try AppInstaller.bundleExecutable($0) }
        if mode == "install-failure" {
            installer.validate = { _ in throw failure("Injected installation failure") }
            do {
                try installer.install(from: source, to: destination)
                throw failure("Invalid installation succeeded")
            } catch let error as InstallationError {
                guard error.message == "Injected installation failure" else { throw error }
            }
        } else {
            let result = try installer.install(from: source, to: destination)
            guard result == (mode == "install" ? .installed : .alreadyInstalled) else { throw failure("Unexpected installation outcome") }
            guard var image = InstallerDiskImageEjector.prepare(installerURL: bundle, destination: destination) else {
                throw failure("Could not identify the mounted test image")
            }
            if mode == "wrong-identity" { image = .init(mountPoint: image.mountPoint, volumeUUID: UUID().uuidString) }
            let handoff = InstallerLaunchHandoff(timeout: 1)
            var finished = false
            var schedulingError: Error?
            handoff.start(open: { completion in
                completion(mode == "launch-failure" ? failure("Injected launch failure") : nil)
            }, onOpened: {
                do { try InstallerDiskImageEjector.schedule(image) } catch { schedulingError = error }
            }, completion: { _ in finished = true })
            let deadline = Date().addingTimeInterval(2)
            while !finished, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
            guard finished else { throw failure("Launch handoff did not complete") }
            if let schedulingError { throw schedulingError }
        }
        try Data().write(to: ready)
        // The runner verifies that our executable is still keeping the image
        // mounted, then releases us so the system-disk worker can eject it.
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: release), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        guard FileManager.default.fileExists(atPath: release) else { throw failure("Test runner did not release the installer") }
        print("Completed \(mode)")
    }

    private static func failure(_ message: String) -> InstallationError { InstallationError(message: message) }
}
