import Darwin
import Foundation

enum InstallerText {
    static func choose(_ chinese: String, _ english: String) -> String {
        Locale.preferredLanguages.first?.hasPrefix("zh") == true ? chinese : english
    }
}

struct InstallationError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// The old app remains in place until a fully validated copy is ready. On an
/// update, renamex_np swaps both directories atomically on the same volume.
struct AppInstaller {
    static let bundleIdentifier = "org.opensource.diskanalyzer"
    static let appName = "DiskAnalyzer.app"

    struct Identity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    enum Outcome {
        case installed
        case alreadyInstalled
    }

    var validate: (URL) throws -> Void = AppInstaller.validatePayload
    var stopApplication: (URL) throws -> Void = { _ in }
    var rename: (URL, URL, UInt32) throws -> Void = AppInstaller.renameItem
    var progress: (String) -> Void = { _ in }

    @discardableResult
    func install(from source: URL, to destination: URL) throws -> Outcome {
        let fm = FileManager.default
        let source = source.standardizedFileURL
        let destination = destination.standardizedFileURL
        let parent = destination.deletingLastPathComponent()
        let resolvedSource = source.resolvingSymlinksInPath().path
        let resolvedParent = parent.resolvingSymlinksInPath().path
        guard destination.lastPathComponent == Self.appName,
              resolvedSource != destination.resolvingSymlinksInPath().path,
              resolvedParent != resolvedSource,
              !resolvedParent.hasPrefix(resolvedSource + "/") else {
            throw InstallationError(message: InstallerText.choose("安装位置无效。", "Invalid installation location."))
        }

        progress(InstallerText.choose("正在验证安装包…", "Checking the application…"))
        try validate(source)
        let original = try Self.destinationIdentity(destination)
        // Compare the whole bundle, not just its version: a damaged resource or a
        // rebuilt app with the same version must still be repaired/replaced.
        if original != nil, fm.contentsEqual(atPath: source.path, andPath: destination.path) {
            var installedCopyIsValid = false
            do {
                try validate(destination)
                installedCopyIsValid = true
            } catch {
                // Matching bytes do not imply matching permissions or a usable app.
            }
            if installedCopyIsValid {
                guard try Self.destinationIdentity(destination) == original else {
                    throw InstallationError(message: InstallerText.choose(
                        "安装位置已被其他操作更改，请重试。", "The installation changed during this check. Please retry."))
                }
                progress(InstallerText.choose("已安装当前版本", "This version is already installed"))
                return .alreadyInstalled
            }
        }
        let staging = parent.appendingPathComponent(".disk-analyzer-install-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false,
                               attributes: [.posixPermissions: 0o700])
        let candidate = staging.appendingPathComponent(Self.appName, isDirectory: true)
        var retainBackup = false
        defer { if !retainBackup { try? fm.removeItem(at: staging) } }

        progress(InstallerText.choose("正在准备新版本…", "Preparing the new version…"))
        try fm.copyItem(at: source, to: candidate)
        try validate(candidate)
        let newIdentity = try Self.identity(candidate)

        progress(InstallerText.choose("正在退出旧版本…", "Closing the installed application…"))
        try stopApplication(destination)
        guard try Self.destinationIdentity(destination) == original else {
            throw InstallationError(message: InstallerText.choose(
                "安装位置已被其他操作更改，请重试。", "The installation changed during this update. Please retry."))
        }

        progress(InstallerText.choose("正在安装…", "Installing…"))
        if let original {
            try rename(candidate, destination, UInt32(RENAME_SWAP))
            // The previous app is now at candidate. Never discard it if recovery fails.
            retainBackup = true
            do {
                guard try Self.identity(candidate) == original else {
                    throw InstallationError(message: InstallerText.choose(
                        "安装位置已被其他操作更改。", "The installation was changed by another operation."))
                }
                try validate(destination)
                guard try Self.identity(destination) == newIdentity else {
                    throw InstallationError(message: InstallerText.choose(
                        "安装完成前应用已被移动。", "The application moved before installation finished."))
                }
            } catch {
                let installError = error
                do {
                    guard try Self.identity(destination) == newIdentity else { throw installError }
                    try rename(candidate, destination, UInt32(RENAME_SWAP))
                    retainBackup = false
                } catch {
                    throw InstallationError(message: InstallerText.choose(
                        "安装未完成，旧版本已保留在：\n\(candidate.path)",
                        "Installation could not finish. The previous version is preserved at:\n\(candidate.path)"))
                }
                throw installError
            }
            retainBackup = false
        } else {
            // An app appearing after our initial check must not be overwritten.
            try rename(candidate, destination, UInt32(RENAME_EXCL))
            do {
                try validate(destination)
                guard try Self.identity(destination) == newIdentity else {
                    throw InstallationError(message: InstallerText.choose(
                        "安装完成前应用已被移动。", "The application moved before installation finished."))
                }
            } catch {
                if (try? Self.identity(destination)) == newIdentity {
                    try? rename(destination, candidate, UInt32(RENAME_EXCL))
                }
                throw error
            }
        }
        return .installed
    }

    static func identity(_ url: URL) throws -> Identity {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                          userInfo: [NSFilePathErrorKey: url.path])
        }
        return Identity(device: info.st_dev, inode: info.st_ino)
    }

    static func destinationIdentity(_ url: URL) throws -> Identity? {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            if errno == ENOENT { return nil }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
        }
        // Recognize the existing bundle even if its executable needs repair.
        _ = try bundleExecutable(url, requireExecutable: false)
        return Identity(device: info.st_dev, inode: info.st_ino)
    }

    static func bundleExecutable(_ app: URL, requireExecutable: Bool = true) throws -> URL {
        let values = try app.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true,
              let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              info["CFBundleIdentifier"] as? String == bundleIdentifier,
              info["CFBundlePackageType"] as? String == "APPL",
              info["CFBundleExecutable"] as? String == "DiskAnalyzer" else {
            throw InstallationError(message: InstallerText.choose(
                "这不是有效的 DiskAnalyzer 应用：\n\(app.path)", "This is not a valid DiskAnalyzer application:\n\(app.path)"))
        }
        let executable = app.appendingPathComponent("Contents/MacOS/DiskAnalyzer")
        if !requireExecutable { return executable }
        guard FileManager.default.isExecutableFile(atPath: executable.path),
              executable.resolvingSymlinksInPath().path.hasPrefix(app.resolvingSymlinksInPath().path + "/") else {
            throw InstallationError(message: InstallerText.choose("应用的可执行文件缺失或无效。", "The application executable is missing or invalid."))
        }
        return executable
    }

    static func validatePayload(_ app: URL) throws {
        _ = try bundleExecutable(app)
        try run(URL(fileURLWithPath: "/usr/bin/codesign"), arguments: ["--verify", "--deep", "--strict", app.path])
        try validateResources(app)
    }

    static func validateResources(_ app: URL) throws {
        for language in ["en", "zh-hans"] {
            let resource = app.appendingPathComponent("Contents/Resources/\(language).lproj/Localizable.strings")
            guard let data = try? Data(contentsOf: resource),
                  let strings = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: String],
                  strings["app.title"]?.isEmpty == false else {
                throw InstallationError(message: InstallerText.choose(
                    "应用语言资源缺失或损坏，请重新下载安装包。",
                    "Application language resources are missing or damaged. Please download the disk image again."))
            }
        }
    }

    static func run(_ executable: URL, arguments: [String]) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(20)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning {
            process.terminate()
            let terminationDeadline = Date().addingTimeInterval(1)
            while process.isRunning, Date() < terminationDeadline { Thread.sleep(forTimeInterval: 0.05) }
            // Only a validation child we started, never the installed application.
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw InstallationError(message: InstallerText.choose("验证安装包超时，现有应用未被替换。", "Application validation timed out."))
        }
        guard process.terminationStatus == 0 else {
            throw InstallationError(message: InstallerText.choose(
                "应用签名或资源校验失败，请重新构建或下载安装包。",
                "Application signature or resource validation failed. Please rebuild or download the disk image again."))
        }
    }

    static func renameItem(_ source: URL, _ destination: URL, _ flags: UInt32) throws {
        guard renamex_np(source.path, destination.path, flags) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                          userInfo: [NSFilePathErrorKey: destination.path])
        }
    }
}
