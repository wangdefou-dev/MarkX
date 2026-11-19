import SwiftUI

/// Collapsing reading header. While the article scrolls, the in-page title
/// stops when it reaches the window's top band and stays there at its own
/// size; the article actions leave the status row and glide up to sit just
/// right of that title. Both follow the scroll position (no timed
/// animation), so scrolling back reverses them exactly.
///
/// All frames are in `.global` (window) coordinates. Only the small views
/// that observe this tracker redraw while scrolling, not the whole window.
@MainActor
final class DetailHeaderTracker: ObservableObject {
    /// In-page title text frame.
    @Published var titleFrame: CGRect = .null
    /// Height of one title line, and the title's width on one line.
    @Published var titleLineHeight: CGFloat = 30
    @Published var titleNaturalWidth: CGFloat = 0
    /// In-page actions slot (status row, right side).
    @Published var actionsFrame: CGRect = .null
    /// Top of the reading column and the height of the toolbar band over it.
    @Published var bandTop: CGFloat = 0
    @Published var band: CGFloat = 38

    /// Scroll distance over which the actions travel.
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

    /// nil while the title scrolls normally; 0…1 just after it stops.
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
    var actionsDocked: Bool { (actionsProgress ?? 0) >= 1 }
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

/// Drawn over the reading column, including the toolbar band: the fade that
/// hides scrolled text, the stopped title and the actions beside it.
struct DetailHeaderOverlay<Actions: View>: View {
    @ObservedObject var tracker: DetailHeaderTracker
    let title: String
    /// The in-page title font, so the stopped title looks identical.
    let titleFont: Font
    @ViewBuilder let actions: Actions

    /// Gap between the stopped title and the actions.
    private let gap = MarkXSpace.l

    var body: some View {
        GeometryReader { proxy in
            let inner = proxy.frame(in: .global)
            let band = max(proxy.safeAreaInsets.top, 38)
            let origin = CGPoint(x: inner.minX, y: inner.minY - proxy.safeAreaInsets.top)
            let layout = Layout(tracker: tracker, origin: origin, gap: gap)
            ZStack(alignment: .topLeading) {
                Group {
                    fade(band: band)
                    bandTitle(layout)
                    // Measure one title line and the title's one-line width.
                    Text("国X").font(titleFont)
                        .hidden()
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { tracker.set(\.titleLineHeight, $0) }
                    Text(title).font(titleFont).lineLimit(1).fixedSize()
                        .hidden()
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { tracker.set(\.titleNaturalWidth, $0) }
                }
                .allowsHitTesting(false)
                movingActions(layout)
            }
            .frame(width: inner.width, height: inner.height + proxy.safeAreaInsets.top, alignment: .topLeading)
            .ignoresSafeArea(.container, edges: .top)
            .onChange(of: origin.y, initial: true) { _, value in tracker.set(\.bandTop, value) }
            .onChange(of: band, initial: true) { _, value in tracker.set(\.band, value) }
        }
    }

    /// Positions in overlay coordinates. The title keeps the in-page left
    /// edge; the actions follow the title and never pass the column's right
    /// edge (the in-page actions' right edge), so a long title truncates.
    private struct Layout {
        let titleLeading: CGFloat
        let titleTop: CGFloat
        let titleWidth: CGFloat
        let actionsStart: CGPoint
        let actionsEnd: CGPoint

        @MainActor init(tracker: DetailHeaderTracker, origin: CGPoint, gap: CGFloat) {
            titleLeading = tracker.titleFrame.isNull ? 0 : tracker.titleFrame.minX - origin.x
            titleTop = tracker.titleStickTop - origin.y
            let actions = tracker.actionsFrame.isNull ? CGRect(x: 0, y: 0, width: 0, height: 0) : tracker.actionsFrame
            let rightEdge = actions.maxX - origin.x
            titleWidth = max(0, min(tracker.titleNaturalWidth, rightEdge - actions.width - gap - titleLeading))
            actionsStart = CGPoint(x: actions.minX - origin.x, y: tracker.actionsStartLine - origin.y)
            actionsEnd = CGPoint(x: titleLeading + titleWidth + gap,
                                 y: tracker.bandTop + (tracker.band - actions.height) / 2 - origin.y)
        }
    }

    private func fade(band: CGFloat) -> some View {
        // Solid a little past the band, since the full-size title nearly
        // fills it, then fading out so scrolled text slips away softly.
        let solid = band + MarkXSpace.m
        let height = solid + MarkXSpace.xxl
        return LinearGradient(stops: [.init(color: MarkXInterface.reading, location: 0),
                                      .init(color: MarkXInterface.reading, location: solid / height),
                                      .init(color: MarkXInterface.reading.opacity(0), location: 1)],
                              startPoint: .top, endPoint: .bottom)
            .frame(height: height)
            .opacity(tracker.titleProgress == nil ? 0 : min(1, (tracker.titleProgress ?? 0) * 4))
    }

    @ViewBuilder
    private func bandTitle(_ layout: Layout) -> some View {
        if tracker.titleProgress != nil {
            Text(title)
                .font(titleFont)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: layout.titleWidth, height: tracker.titleLineHeight, alignment: .leading)
                .offset(x: layout.titleLeading, y: layout.titleTop)
                .opacity(tracker.bandTitleOpacity)
                .accessibilityHidden(true)
        }
    }

    /// One view for the whole trip, so it never flickers: a ghost while it
    /// glides, the clickable actions once it has arrived.
    @ViewBuilder
    private func movingActions(_ layout: Layout) -> some View {
        if let progress = tracker.actionsProgress, !tracker.actionsFrame.isNull {
            let eased = progress * progress * (3 - 2 * progress)
            let docked = tracker.actionsDocked
            actions
                .fixedSize()
                .offset(x: layout.actionsStart.x + (layout.actionsEnd.x - layout.actionsStart.x) * eased,
                        y: layout.actionsStart.y + (layout.actionsEnd.y - layout.actionsStart.y) * eased)
                .allowsHitTesting(docked)
                .accessibilityHidden(!docked)
        }
    }
}
