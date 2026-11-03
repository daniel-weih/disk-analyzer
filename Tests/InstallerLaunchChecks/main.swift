import AppKit

@main
@MainActor
enum InstallerLaunchChecks {
    static func main() async {
        do { try await checkLaunches() }
        catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
    }

    private static func checkLaunches() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let oldURL = root.appendingPathComponent("old/Probe.app")
        let installedURL = root.appendingPathComponent("installed/Probe.app")
        var launched: [NSRunningApplication] = []
        defer { stopProbes(launched) }

        func open(_ url: URL) async throws -> NSRunningApplication {
            try await withCheckedThrowingContinuation { continuation in
                InstalledApplication.open(at: url) { application, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let application { continuation.resume(returning: application) }
                    else { continuation.resume(throwing: failure("Missing launch result")) }
                }
            }
        }

        let old = try await open(oldURL)
        launched.append(old)
        print("PASS initial launch: \(old.bundleURL?.path ?? "nil")")

        let handoff = InstallerLaunchHandoff()
        var outcome: InstallerLaunchHandoff.Outcome?
        var installed: NSRunningApplication?
        var cleanups = 0
        handoff.start(open: { completion in
            InstalledApplication.open(at: installedURL) { application, error in
                installed = application
                completion(error)
            }
        }, onOpened: { cleanups += 1 }, completion: { outcome = $0 })
        let deadline = Date().addingTimeInterval(10)
        while outcome == nil, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        if let installed { launched.append(installed) }
        guard case .opened? = outcome, let installed,
              installed.bundleURL?.resolvingSymlinksInPath() == installedURL.resolvingSymlinksInPath(),
              installed.processIdentifier != old.processIdentifier, !old.isTerminated,
              cleanups == 1 else { throw failure("The installer must open its installed copy while another copy is running") }
        print("PASS installed copy with old copy still running: \(installed.bundleURL!.path)")

        let repeated = try await open(installedURL)
        launched.append(repeated)
        guard repeated.processIdentifier == installed.processIdentifier else { throw failure("Repeated installation restarted the app") }
        print("PASS repeated launch reuses the installed process")

        var openedMissingApp = false
        var missingResultReturned = false
        InstalledApplication.open(at: root.appendingPathComponent("missing/Probe.app")) { application, error in
            missingResultReturned = application == nil && error != nil
        }
        guard missingResultReturned else { throw failure("A missing app must fail before invoking Launch Services or showing system UI") }
        do {
            let unexpected = try await open(root.appendingPathComponent("missing/Probe.app"))
            launched.append(unexpected)
            openedMissingApp = true
        } catch {}
        guard !openedMissingApp else { throw failure("A missing installed app must not reuse the old copy") }
        print("PASS missing installed app reports a launch failure")
        print("All 4 real application launch checks passed")
    }

    private static func stopProbes(_ applications: [NSRunningApplication]) {
        for application in applications { application.terminate() }
        let deadline = Date().addingTimeInterval(2)
        while applications.contains(where: { !$0.isTerminated }), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    private static func failure(_ message: String) -> InstallationError { InstallationError(message: message) }
}
