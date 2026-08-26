import Foundation

enum SizeFormatter {
    static let shared: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB]
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        return f
    }()
}
