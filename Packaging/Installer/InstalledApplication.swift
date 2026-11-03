import AppKit

enum InstalledApplication {
    static func stop(at destination: URL) throws {
        let path = destination.resolvingSymlinksInPath().path
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: AppInstaller.bundleIdentifier)
            .filter { $0.bundleURL?.resolvingSymlinksInPath().path == path }
        for application in applications { application.terminate() }
        let deadline = Date().addingTimeInterval(8)
        while applications.contains(where: { !$0.isTerminated }), Date() < deadline {
            if Thread.isMainThread {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            } else {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        guard applications.allSatisfy(\.isTerminated) else {
            throw InstallationError(message: InstallerText.choose(
                "DiskAnalyzer 尚未退出，现有版本已保留。请稍后重试。",
                "DiskAnalyzer has not quit. The installed version is unchanged. Please retry shortly."))
        }
    }

    static func open(at destination: URL, completion: @escaping (NSRunningApplication?, Error?) -> Void) {
        guard destination.isFileURL, FileManager.default.fileExists(atPath: destination.path) else {
            completion(nil, InstallationError(message: InstallerText.choose(
                "找不到刚安装的 DiskAnalyzer，请重新安装。",
                "The installed DiskAnalyzer could not be found. Please install it again.")))
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        // The installer presents launch failures itself. System prompts also
        // turn an unattended missing-file regression check into a Finder alert.
        configuration.promptsUserIfNeeded = false
        configuration.addsToRecentItems = false
        configuration.createsNewApplicationInstance = false
        configuration.allowsRunningApplicationSubstitution = false
        NSWorkspace.shared.openApplication(at: destination, configuration: configuration) { application, error in
            let error = openingError(destination: destination, applicationURL: application?.bundleURL,
                                     isTerminated: application?.isTerminated ?? true, underlyingError: error)
            completion(error == nil ? application : nil, error)
        }
    }

    static func openingError(destination: URL, applicationURL: URL?, isTerminated: Bool, underlyingError: Error?) -> Error? {
        if let underlyingError { return underlyingError }
        guard !isTerminated, let applicationURL, applicationURL.isFileURL,
              applicationURL.standardizedFileURL.resolvingSymlinksInPath()
                == destination.standardizedFileURL.resolvingSymlinksInPath() else {
            return InstallationError(message: InstallerText.choose(
                "未能正常打开刚安装的 DiskAnalyzer。", "The newly installed DiskAnalyzer could not be opened."))
        }
        return nil
    }
}
