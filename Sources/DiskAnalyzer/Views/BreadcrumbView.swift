import SwiftUI

struct BreadcrumbView: View {
    let path: [FileNode]
    let onNavigate: (FileNode) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(Array(path.enumerated()), id: \.element.id) { index, node in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }

                    Button {
                        onNavigate(node)
                    } label: {
                        HStack(spacing: 4) {
                            if index == 0 {
                                Image(systemName: "internaldrive")
                            }
                            Text(node.name)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: index == path.count - 1 ? .semibold : .medium))
                    .foregroundStyle(index == path.count - 1 ? Color.primary : Color.secondary)
                    .help(node.path ?? node.name)
                }

                if path.isEmpty {
                    Image(systemName: "internaldrive")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(height: 26)
    }
}
