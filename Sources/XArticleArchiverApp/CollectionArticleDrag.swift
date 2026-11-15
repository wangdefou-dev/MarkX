import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum CollectionArticleDrag {
    static let type = UTType(exportedAs: "ai.defou.markx.collection-article", conformingTo: .data)

    static func provider(for id: UUID) -> NSItemProvider {
        let provider = NSItemProvider()
        let data = Data(id.uuidString.utf8)
        provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .ownProcess) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }

    static func receive(_ providers: [NSItemProvider], onDrop: @escaping @MainActor (UUID) -> Void) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(type.identifier) }) else {
            return false
        }
        _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
            guard let data, let id = UUID(uuidString: String(decoding: data, as: UTF8.self)) else { return }
            Task { @MainActor in onDrop(id) }
        }
        return true
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
        .contentShape(.dragPreview, RoundedRectangle(cornerRadius: 8))
    }
}
