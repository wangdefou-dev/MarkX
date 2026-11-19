import SwiftUI

/// Whether the reading pane's own title has scrolled out of view. Kept in a
/// small object so only the top bar redraws when it flips, not the window.
@MainActor
final class DetailTitleState: ObservableObject {
    @Published private(set) var isScrolledAway = false

    func set(_ value: Bool) {
        if isScrolledAway != value { isScrolledAway = value }
    }
}

/// The reading column's fixed top bar, as tall as the window toolbar band.
/// It always keeps its place, so the article scrolls underneath its lower
/// edge and never through it. Empty while the article title is on screen;
/// once the title scrolls away the bar fades in the title, the article
/// actions on the right and a hairline below.
struct DetailTopBar<Actions: View>: View {
    @ObservedObject var state: DetailTitleState
    let title: String
    @ViewBuilder let actions: Actions

    var body: some View {
        let shown = state.isScrolledAway
        HStack(spacing: MarkXSpace.l) {
            Text(title)
                .font(MarkXFont.headline)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            actions
        }
        .frame(minWidth: 0, maxWidth: 860)
        .padding(.horizontal, MarkXSpace.pageSide)
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        .opacity(shown ? 1 : 0)
        .allowsHitTesting(shown)
        .accessibilityHidden(!shown)
        .overlay(alignment: .bottom) {
            Rectangle().fill(MarkXInterface.hairline).frame(height: 1)
                .opacity(shown ? 1 : 0)
        }
        .background(MarkXInterface.reading)
        .animation(.easeOut(duration: 0.15), value: shown)
    }
}
