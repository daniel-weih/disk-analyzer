import AppKit
import Darwin

enum TrashMoveOutcome: Equatable {
    case moved(destinationURL: URL?)
    case alreadyMissing
}

enum FinderBridge {
    @MainActor
    static func chooseDirectory(startingAt url: URL?) -> URL? {
        let panel = NSOpenPanel()
        panel.title = L10n.text("picker.title")
        panel.prompt = L10n.text("picker.prompt")
        panel.message = L10n.text("picker.message")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = url
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func reveal(_ url: URL?) {
        guard let url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func open(_ url: URL?) {
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }

    @MainActor
    static func openFullDiskAccessSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    static func moveToTrash(_ url: URL) throws -> TrashMoveOutcome {
        do {
            var resultingURL: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
            return .moved(destinationURL: resultingURL as URL?)
        } catch {
            guard sourceIsMissing(url) else { throw error }
            return .alreadyMissing
        }
    }

    private static func sourceIsMissing(_ url: URL) -> Bool {
        var info = stat()
        if lstat(url.path, &info) == 0 { return false }
        return errno == ENOENT || errno == ENOTDIR
    }
}
