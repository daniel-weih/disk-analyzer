import Foundation

enum SizeMetric: String, CaseIterable, Identifiable, Sendable {
    case allocated
    case logical

    var id: String { rawValue }

    var title: String {
        switch self {
        case .allocated: return L10n.text("metric.allocated.title")
        case .logical: return L10n.text("metric.logical.title")
        }
    }

    var shortExplanation: String {
        switch self {
        case .allocated:
            return L10n.text("metric.allocated.explanation")
        case .logical:
            return L10n.text("metric.logical.explanation")
        }
    }
}
