import SwiftUI

enum CollectionArticleDrag {
    static func target(at location: CGPoint, sidebar: CGRect, collections: [UUID: CGRect]) -> UUID? {
        guard sidebar.contains(location) else { return nil }
        return collections.first { $0.value.contains(location) }?.key
    }
}

struct CollectionArticleDragPreview: View {
    let title: String

    var body: some View {
        Label {
            Text(title).lineLimit(1)
        } icon: {
            Image(systemName: "doc.text.fill").foregroundStyle(Color.orange)
        }
        .font(.system(size: 12, weight: .semibold))
        .frame(width: 204, height: 32, alignment: .leading)
        .padding(.horizontal, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.orange.opacity(0.75)) }
    }
}
