import SwiftUI

/// Whether everything above the article text (title, metadata, status and
/// the divider) has scrolled out of view. Kept in a small object so only the
/// top bar redraws when it flips, not the window.
@MainActor
final class DetailTitleState: ObservableObject {
    @Published private(set) var isScrolledAway = false

    func set(_ value: Bool) {
        if isScrolledAway != value { isScrolledAway = value }
    }
}

/// The reading column's fixed top bar, as tall as the window toolbar band
/// and drawn above the scroll view, so the article scrolls underneath its
/// lower edge and never through it. Empty while the article header is on
/// screen; once the header has scrolled away, the title and the article
/// actions glide up into the bar (moving and shrinking into place, not just
/// fading in) and a hairline appears below. Scrolling back reverses it.
struct DetailTopBar<Actions: View>: View {
    @ObservedObject var state: DetailTitleState
    let title: String
    @ViewBuilder let actions: Actions

    /// How far below its resting place the bar content starts its glide.
    private static var rise: CGFloat { 22 }

    var body: some View {
        let shown = state.isScrolledAway
        HStack(spacing: MarkXSpace.l) {
            if shown {
                Text(title)
                    .font(MarkXFont.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    .transition(.offset(y: Self.rise)
                        .combined(with: .scale(scale: 1.35, anchor: .leading))
                        .combined(with: .opacity))
                actions
                    .transition(.offset(y: Self.rise).combined(with: .opacity))
            }
        }
        .frame(minWidth: 0, maxWidth: 860)
        .padding(.horizontal, MarkXSpace.pageSide)
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityHidden(!shown)
        .overlay(alignment: .bottom) {
            Rectangle().fill(MarkXInterface.hairline).frame(height: 1)
                .opacity(shown ? 1 : 0)
        }
        .background(MarkXInterface.readingGradient)
        .clipped()
        .animation(.smooth(duration: 0.35), value: shown)
    }
}
