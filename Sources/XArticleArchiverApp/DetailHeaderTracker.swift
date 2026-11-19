import SwiftUI

/// Collapsing reading header. While the article scrolls, the in-page title
/// stops when it reaches the window's top band and shrinks there into the
/// toolbar title; the article actions leave the status row and glide to the
/// toolbar's top-right corner. Both follow the scroll position (no timed
/// animation), so scrolling back reverses them exactly.
///
/// All frames are in `.global` (window) coordinates. Only the small views
/// that observe this tracker redraw while scrolling, not the whole window.
@MainActor
final class DetailHeaderTracker: ObservableObject {
    /// In-page title text frame.
    @Published var titleFrame: CGRect = .null
    /// Height of one title line at the in-page size.
    @Published var titleLineHeight: CGFloat = 30
    /// In-page actions slot (status row, right side).
    @Published var actionsFrame: CGRect = .null
    /// Toolbar actions slot (window top-right).
    @Published var toolbarActionsFrame: CGRect = .null
    /// Top of the reading column and the height of the toolbar band over it.
    @Published var bandTop: CGFloat = 0
    @Published var band: CGFloat = 38

    /// Scroll distance over which the title shrinks and the actions travel.
    let travel: CGFloat = 48

    func set<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<DetailHeaderTracker, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    func reset() {
        set(\.titleFrame, .null)
        set(\.actionsFrame, .null)
    }

    /// Where the title's first line stops: vertically centred in the band.
    var titleStickTop: CGFloat { bandTop + (band - titleLineHeight) / 2 }

    /// nil while the title scrolls normally; 0…1 while it shrinks in the band.
    var titleProgress: CGFloat? {
        guard !titleFrame.isNull, titleFrame.minY < titleStickTop else { return nil }
        return min(1, (titleStickTop - titleFrame.minY) / travel)
    }

    var titleIsSingleLine: Bool { titleFrame.height < titleLineHeight * 1.5 }

    /// The in-page title is replaced by the band title once it stops; a
    /// wrapped title crossfades so its extra lines don't vanish at once.
    var inPageTitleOpacity: CGFloat {
        guard let progress = titleProgress else { return 1 }
        return titleIsSingleLine ? 0 : 1 - min(1, progress * 2.5)
    }

    var bandTitleOpacity: CGFloat {
        guard let progress = titleProgress else { return 0 }
        return titleIsSingleLine ? 1 : min(1, progress * 2.5)
    }

    /// The glide starts when the actions reach the bottom of the band's
    /// fade, before the fade could cover them.
    var actionsStartLine: CGFloat { bandTop + band + MarkXSpace.xl }

    /// nil while the actions scroll with the page; 0…1 while they travel.
    var actionsProgress: CGFloat? {
        guard !actionsFrame.isNull, actionsFrame.minY < actionsStartLine else { return nil }
        return min(1, (actionsStartLine - actionsFrame.minY) / travel)
    }

    var showsInPageActions: Bool { actionsProgress == nil }
    var showsToolbarActions: Bool { (actionsProgress ?? 0) >= 1 }
}

extension View {
    /// Reports this view's window-space frame whenever it moves, including
    /// while its scroll view scrolls.
    func markxGlobalFrame(_ report: @escaping (CGRect) -> Void) -> some View {
        background(GeometryReader { proxy in
            let frame = proxy.frame(in: .global)
            Color.clear
                .onAppear { report(frame) }
                .onChange(of: frame) { _, value in report(value) }
        })
    }
}

/// The in-page title, faded out while the band shows it.
struct DetailInPageTitle<Content: View>: View {
    @ObservedObject var tracker: DetailHeaderTracker
    @ViewBuilder let content: Content

    var body: some View {
        content
            .markxGlobalFrame { tracker.set(\.titleFrame, $0) }
            .opacity(tracker.inPageTitleOpacity)
    }
}

/// The actions' resting place at the right of the status row.
struct DetailInPageActions<Content: View>: View {
    @ObservedObject var tracker: DetailHeaderTracker
    @ViewBuilder let content: Content

    var body: some View {
        content
            .markxGlobalFrame { tracker.set(\.actionsFrame, $0) }
            .opacity(tracker.showsInPageActions ? 1 : 0)
            .allowsHitTesting(tracker.showsInPageActions)
            .accessibilityHidden(!tracker.showsInPageActions)
    }
}

/// The actions' final place in the window toolbar. Always laid out so its
/// position is known; visible and clickable only once the glide has ended.
struct DetailToolbarActions<Content: View>: View {
    @ObservedObject var tracker: DetailHeaderTracker
    @ViewBuilder let content: Content

    var body: some View {
        content
            .markxGlobalFrame { tracker.set(\.toolbarActionsFrame, $0) }
            .opacity(tracker.showsToolbarActions ? 1 : 0)
            .allowsHitTesting(tracker.showsToolbarActions)
            .accessibilityHidden(!tracker.showsToolbarActions)
    }
}

/// Drawn over the reading column, including the toolbar band: the fade that
/// hides scrolled text, the shrinking title and the gliding actions.
struct DetailHeaderOverlay<Actions: View>: View {
    @ObservedObject var tracker: DetailHeaderTracker
    let title: String
    /// In-page title point size and the toolbar title size it shrinks to.
    let titleSize: CGFloat
    let collapsedTitleSize: CGFloat
    @ViewBuilder let actions: Actions

    var body: some View {
        GeometryReader { proxy in
            let inner = proxy.frame(in: .global)
            let band = max(proxy.safeAreaInsets.top, 38)
            let origin = CGPoint(x: inner.minX, y: inner.minY - proxy.safeAreaInsets.top)
            ZStack(alignment: .topLeading) {
                fade(band: band)
                bandTitle(origin: origin, width: inner.width)
                glidingActions(origin: origin)
                // Measures one title line at the in-page size.
                Text("国X").font(.system(size: titleSize, weight: .medium))
                    .hidden()
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { tracker.set(\.titleLineHeight, $0) }
            }
            .frame(width: inner.width, height: inner.height + proxy.safeAreaInsets.top, alignment: .topLeading)
            .ignoresSafeArea(.container, edges: .top)
            .onChange(of: origin.y, initial: true) { _, value in tracker.set(\.bandTop, value) }
            .onChange(of: band, initial: true) { _, value in tracker.set(\.band, value) }
        }
        .allowsHitTesting(false)
    }

    private func fade(band: CGFloat) -> some View {
        let height = band + MarkXSpace.xl
        return LinearGradient(stops: [.init(color: MarkXInterface.reading, location: 0),
                                      .init(color: MarkXInterface.reading, location: band / height),
                                      .init(color: MarkXInterface.reading.opacity(0), location: 1)],
                              startPoint: .top, endPoint: .bottom)
            .frame(height: height)
            .opacity(tracker.titleProgress == nil ? 0 : min(1, (tracker.titleProgress ?? 0) * 4))
    }

    @ViewBuilder
    private func bandTitle(origin: CGPoint, width: CGFloat) -> some View {
        if let progress = tracker.titleProgress {
            let scale = 1 - progress * (1 - collapsedTitleSize / titleSize)
            let leading = tracker.titleFrame.minX - origin.x
            // Room for the toolbar actions on the right.
            let available = max(80, width - leading - 148)
            Text(title)
                .font(.system(size: titleSize, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: available / scale, height: tracker.titleLineHeight, alignment: .leading)
                .scaleEffect(scale, anchor: .leading)
                .offset(x: leading, y: tracker.titleStickTop - origin.y)
                .opacity(tracker.bandTitleOpacity)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func glidingActions(origin: CGPoint) -> some View {
        if let progress = tracker.actionsProgress, progress < 1, !tracker.actionsFrame.isNull {
            let start = CGPoint(x: tracker.actionsFrame.minX,
                                y: tracker.actionsStartLine)
            let end = tracker.toolbarActionsFrame.isNull ? start : tracker.toolbarActionsFrame.origin
            let eased = progress * progress * (3 - 2 * progress)
            actions
                .fixedSize()
                .offset(x: start.x + (end.x - start.x) * eased - origin.x,
                        y: start.y + (end.y - start.y) * eased - origin.y)
                .accessibilityHidden(true)
        }
    }
}
