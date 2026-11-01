import Darwin
import Foundation

/// Metadata captured at enumeration time; never follows a replacement symlink.
struct FileSnapshot: Equatable, Sendable {
    let device: dev_t
    let inode: ino_t
    let kind: mode_t
    let birthSeconds: Int
    let birthNanoseconds: Int
    let size: off_t
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int

    init(_ info: stat) {
        device = info.st_dev
        inode = info.st_ino
        kind = info.st_mode & S_IFMT
        birthSeconds = info.st_birthtimespec.tv_sec
        birthNanoseconds = info.st_birthtimespec.tv_nsec
        size = info.st_size
        modifiedSeconds = info.st_mtimespec.tv_sec
        modifiedNanoseconds = info.st_mtimespec.tv_nsec
        changedSeconds = info.st_ctimespec.tv_sec
        changedNanoseconds = info.st_ctimespec.tv_nsec
    }

    static func read(at url: URL) throws -> FileSnapshot {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return FileSnapshot(info)
    }

    func identifiesSameItem(as other: FileSnapshot) -> Bool {
        device == other.device && inode == other.inode && kind == other.kind
            && birthSeconds == other.birthSeconds && birthNanoseconds == other.birthNanoseconds
    }

    func matchesContents(at url: URL) -> Bool {
        (try? Self.read(at: url)) == self
    }
}

enum CleanupValidationError: LocalizedError {
    case changed(String)

    var errorDescription: String? {
        switch self {
        case .changed(let name): return L10n.text("trash.item_changed", name)
        }
    }
}

extension FileNode {
    func validateForCleanup() throws {
        guard let snapshot = fileSnapshot, let url else {
            throw CleanupValidationError.changed(name)
        }
        do {
            let current = try FileSnapshot.read(at: url)
            guard snapshot.identifiesSameItem(as: current) else {
                throw CleanupValidationError.changed(name)
            }
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain
            && (error.code == Int(ENOENT) || error.code == Int(ENOTDIR)) {
            // Let the trash bridge reconcile an item that has already disappeared.
        }
    }
}
