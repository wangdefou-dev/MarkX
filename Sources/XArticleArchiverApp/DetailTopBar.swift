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
/// fading in). There is no divider line: `DetailScrollFade` softens the text
/// edge under the bar instead. Scrolling back reverses it.
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
                    .font(MarkXTypography.system(size: 16, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    .transition(.offset(y: Self.rise)
                        .combined(with: .scale(scale: 1.3, anchor: .leading))
                        .combined(with: .opacity))
                actions
                    .transition(.offset(y: Self.rise).combined(with: .opacity))
            }
        }
        .frame(minWidth: 0, maxWidth: MarkXSpace.readingColumn)
        .padding(.horizontal, MarkXSpace.pageSide)
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityHidden(!shown)
        .background(MarkXInterface.readingGradient)
        .clipped()
        .animation(.smooth(duration: 0.35), value: shown)
    }
}

/// Once the article header has scrolled away, the text fades out over a short
/// band right under the top bar instead of being cut by a line.
struct DetailScrollFade: ViewModifier {
    @ObservedObject var state: DetailTitleState

    private static let band: CGFloat = 24

    func body(content: Content) -> some View {
        let fade = state.isScrolledAway ? Self.band : 0
        content.mask {
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: fade)
                Color.black
            }
            .animation(.smooth(duration: 0.35), value: fade)
        }
    }
}
