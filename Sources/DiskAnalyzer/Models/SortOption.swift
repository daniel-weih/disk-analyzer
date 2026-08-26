import Foundation

enum SortOption: String, CaseIterable, Identifiable {
    case sizeDescending
    case sizeAscending
    case nameAscending
    case nameDescending

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sizeDescending: return L10n.text("sort.size_descending")
        case .sizeAscending: return L10n.text("sort.size_ascending")
        case .nameAscending: return L10n.text("sort.name_ascending")
        case .nameDescending: return L10n.text("sort.name_descending")
        }
    }
}
