import AppKit
import SwiftUI

// MARK: - Design tokens
//
// One visual vocabulary for the whole app, taken from Fog's reader
// (Web/thread/thread.css): medium weights instead of bold, secondary text in
// slate grey, 6pt controls, 8pt cards, a 4-based spacing scale. Interface type
// keeps MarkX's +1pt increase (0.3.4x), so every role is Fog's size plus one.

/// Type roles. Use these instead of point sizes in interface code.
enum MarkXFont {
    /// Welcome hero. Fog: none; one step above `title`.
    static let display = MarkXTypography.system(size: 24, weight: .medium)
    /// Pane and sheet titles, list heading. Fog `.subject`: 18 / 500.
    static let title = MarkXTypography.system(size: 18, weight: .medium)
    /// Column heading in the toolbar.
    static let columnTitle = MarkXTypography.system(size: 14, weight: .medium)
    /// Section titles, row titles, names. Fog `.name`: 13 / 500.
    static let headline = MarkXTypography.system(size: 13, weight: .medium)
    /// Default interface text. Fog `body`: 13.
    static let body = MarkXTypography.system(size: 13)
    /// Introductory paragraph under a large title.
    static let lead = MarkXTypography.system(size: 14)
    /// Descriptions and secondary lines. Fog `.line`, `.address`: 12.
    static let detail = MarkXTypography.system(size: 12)
    /// Emphasised secondary text, buttons and chips. Fog `.chip`: 12 / 500.
    static let detailStrong = MarkXTypography.system(size: 12, weight: .medium)
    /// Metadata, footnotes, timestamps.
    static let meta = MarkXTypography.system(size: 11)
    static let metaStrong = MarkXTypography.system(size: 11, weight: .medium)
    /// Counters and tiny badges.
    static let badge = MarkXTypography.system(size: 10, weight: .medium)
    /// Large numbers in result summaries.
    static let metric = MarkXTypography.system(size: 22, weight: .medium).monospacedDigit()
}

/// 4-based spacing scale (Fog uses 2/4/6/8/10/12/16/20 and 52/64 page margins).
enum MarkXSpace {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let s: CGFloat = 6
    static let m: CGFloat = 8
    static let l: CGFloat = 12
    static let xl: CGFloat = 16
    static let xxl: CGFloat = 20
    static let x3: CGFloat = 24
    static let x4: CGFloat = 32
    static let x5: CGFloat = 40
    static let x6: CGFloat = 48
    /// Reading page side margin and top margin (Fog `.thread`: 64px 52px).
    static let pageSide: CGFloat = 52
    static let pageTop: CGFloat = 56
}

enum MarkXRadius {
    /// Buttons, chips, fields, icon tiles (Fog `.chip`, `.banner-button`).
    static let control: CGFloat = 6
    /// Cards and grouped sections (Fog `.card`).
    static let card: CGFloat = 8
    /// Hover rows and larger panels (Fog `header.toggles`).
    static let panel: CGFloat = 12
    /// Floating hero panels (Fog onboarding).
    static let hero: CGFloat = 20
}

enum MarkXInterface {
    static let inset: CGFloat = MarkXSpace.x3
    static let spacing: CGFloat = MarkXSpace.xxl
    static let cornerRadius: CGFloat = MarkXRadius.card

    // Calm neutral palette (the same slate scale as Fog's reading view):
    // low saturation, hairline borders, soft washes instead of strong fills.
    static let canvas = dynamic(light: 0xF9F9FB, dark: 0x18191B)
    static let surface = dynamic(light: 0xFFFFFF, dark: 0x212225)
    /// Flat reading background behind article text.
    static let reading = dynamic(light: 0xFCFCFD, dark: 0x111113)
    static let hairline = dynamic(light: 0x00002D, lightAlpha: 0.09, dark: 0xD3EDF8, darkAlpha: 0.11)
    /// Hover and quiet-selection wash.
    static let wash = dynamic(light: 0x000033, lightAlpha: 0.06, dark: 0xDDEAF8, darkAlpha: 0.08)
    /// Pressed wash and filled input background.
    static let washStrong = dynamic(light: 0x00002D, lightAlpha: 0.09, dark: 0xD3EDF8, darkAlpha: 0.11)
    /// Secondary and tertiary text (Fog --text2 / --text3).
    static let text2 = dynamic(light: 0x646464, dark: 0xB4B4B4)
    static let text3 = dynamic(light: 0x8D8D8D, dark: 0x6E6E6E)

    private static func dynamic(light: UInt32, lightAlpha: CGFloat = 1,
                                dark: UInt32, darkAlpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255,
                           alpha: isDark ? darkAlpha : lightAlpha)
        })
    }

    static func sheetHeight(_ preferred: CGFloat) -> CGFloat {
        min(preferred, max(440, (NSScreen.main?.visibleFrame.height ?? 900) - 120))
    }
}

/// Sheet title block. Fog's dialogs carry no decorative icon: a medium title
/// and one grey line. A status symbol is shown only when it carries meaning.
struct MarkXPaneHeader: View {
    let title: String
    let subtitle: String
    var symbol: String? = nil
    var symbolColor: Color = .secondary

    var body: some View {
        VStack(alignment: .leading, spacing: MarkXSpace.s) {
            HStack(alignment: .firstTextBaseline, spacing: MarkXSpace.m) {
                if let symbol {
                    Image(systemName: symbol)
                        .foregroundStyle(symbolColor)
                        .accessibilityHidden(true)
                }
                Text(title)
            }
            .font(MarkXFont.title)
            Text(subtitle)
                .font(MarkXFont.detail)
                .foregroundStyle(MarkXInterface.text2)
                .lineSpacing(MarkXSpace.xxs)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, MarkXInterface.inset)
        .padding(.top, MarkXSpace.x4)
        .padding(.bottom, MarkXSpace.xxl)
    }
}

/// A grouped card: title, optional grey description, content (Fog `.card`).
struct MarkXSection<Content: View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: MarkXSpace.l) {
            if !title.isEmpty {
                VStack(alignment: .leading, spacing: MarkXSpace.xs) {
                    Text(title).font(MarkXFont.headline)
                    if let detail {
                        Text(detail).font(MarkXFont.detail).foregroundStyle(MarkXInterface.text2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(MarkXSpace.xl)
        .markxSurface()
    }
}

/// One-line note with a small leading symbol in tertiary grey.
struct MarkXInfoLine: View {
    let symbol: String
    let text: String
    var color: Color = MarkXInterface.text3

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: MarkXSpace.m) {
            Image(systemName: symbol).foregroundStyle(color).frame(width: MarkXIcon.inlineWidth)
            Text(text).foregroundStyle(MarkXInterface.text2).fixedSize(horizontal: false, vertical: true)
        }
        .font(MarkXFont.meta)
        .lineSpacing(MarkXSpace.xxs)
    }
}

struct MarkXFooter<Actions: View>: View {
    var note = ""
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(MarkXInterface.hairline).frame(height: 1)
            HStack(spacing: MarkXSpace.m) {
                Text(note).font(MarkXFont.meta).foregroundStyle(MarkXInterface.text2).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                actions
            }
            .buttonStyle(.markxPill)
            .controlSize(.regular)
            .padding(.horizontal, MarkXInterface.inset)
            .padding(.vertical, MarkXSpace.xl)
        }
        .background(MarkXInterface.canvas)
    }
}

/// Icon sizing. Symbols follow the text they sit next to; these fix the
/// column widths so labels line up.
enum MarkXIcon {
    /// Column for a symbol beside caption or detail text.
    static let inlineWidth: CGFloat = 14
    /// Column for a symbol beside a row title.
    static let rowWidth: CGFloat = 18
    /// Square tile behind a symbol in setup rows.
    static let tile: CGFloat = 28
}

/// A symbol on a washed 6pt tile, for setup rows (Fog `.avatar` geometry).
struct MarkXIconTile: View {
    let systemImage: String
    var color: Color = MarkXInterface.text2

    var body: some View {
        Image(systemName: systemImage)
            .font(MarkXFont.headline)
            .foregroundStyle(color)
            .frame(width: MarkXIcon.tile, height: MarkXIcon.tile)
            .background(MarkXInterface.wash, in: RoundedRectangle(cornerRadius: MarkXRadius.control))
            .accessibilityHidden(true)
    }
}

extension View {
    func markxSurface() -> some View {
        background(MarkXInterface.surface, in: RoundedRectangle(cornerRadius: MarkXRadius.card))
            .overlay(RoundedRectangle(cornerRadius: MarkXRadius.card)
                .strokeBorder(MarkXInterface.hairline, lineWidth: 1))
    }

    /// Fog's filled input: wash background, no border, 6pt corners.
    func markxField() -> some View {
        textFieldStyle(.plain)
            .padding(.horizontal, MarkXSpace.m + MarkXSpace.xxs)
            .frame(minHeight: 30)
            .background(MarkXInterface.wash, in: RoundedRectangle(cornerRadius: MarkXRadius.control))
    }
}

/// Keeps metadata readable when larger text needs another line.
struct MarkXFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrangement(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = arrangement(width: bounds.width, subviews: subviews)
        for (subview, frame) in zip(subviews, layout.frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrangement(width: CGFloat, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        let width = max(0, width)
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        var frames: [CGRect] = []
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: width.isFinite ? width : nil, height: nil))
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            usedWidth = max(usedWidth, x + size.width)
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }
        return (CGSize(width: usedWidth, height: y + rowHeight), frames)
    }
}

/// Button tiers (Fog):
/// - `.markxPillProminent` / `.markxPill`: 32pt capsules for the main and
///   secondary actions of a sheet or page (Fog onboarding).
/// - `.markxCompact`: 26pt washed buttons for actions inside content
///   (Fog `.banner-button`).
/// - `.markxText`: grey text-only actions (Fog `.text-action`).
struct MarkXPillButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(MarkXFont.headline)
            .foregroundStyle(prominent ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, MarkXSpace.xxl)
            .frame(minWidth: 88, minHeight: 32)
            .background(
                Capsule().fill(prominent
                    ? AnyShapeStyle(.tint)
                    : AnyShapeStyle(configuration.isPressed ? MarkXInterface.washStrong : MarkXInterface.wash))
            )
            .opacity(isEnabled ? (prominent && configuration.isPressed ? 0.85 : 1) : 0.45)
            .contentShape(Capsule())
    }
}

struct MarkXCompactButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(MarkXCompactLabelStyle(prominent: prominent))
            .font(MarkXFont.detailStrong)
            .foregroundStyle(prominent ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, MarkXSpace.m + MarkXSpace.xxs)
            .frame(minHeight: 26)
            .background(
                RoundedRectangle(cornerRadius: MarkXRadius.control).fill(prominent
                    ? AnyShapeStyle(.tint)
                    : AnyShapeStyle(configuration.isPressed ? MarkXInterface.washStrong : MarkXInterface.wash))
            )
            .brightness(prominent && configuration.isPressed ? -0.06 : 0)
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: MarkXRadius.control))
    }
}

private struct MarkXCompactLabelStyle: LabelStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: MarkXSpace.s) {
            configuration.icon.foregroundStyle(prominent ? AnyShapeStyle(Color.white) : AnyShapeStyle(MarkXInterface.text2))
            configuration.title
        }
    }
}

struct MarkXTextButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(MarkXFont.detail)
            .foregroundStyle(configuration.isPressed ? AnyShapeStyle(.primary) : AnyShapeStyle(MarkXInterface.text2))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == MarkXPillButtonStyle {
    static var markxPill: MarkXPillButtonStyle { MarkXPillButtonStyle() }
    static var markxPillProminent: MarkXPillButtonStyle { MarkXPillButtonStyle(prominent: true) }
}

extension ButtonStyle where Self == MarkXCompactButtonStyle {
    static var markxCompact: MarkXCompactButtonStyle { MarkXCompactButtonStyle() }
    static var markxCompactProminent: MarkXCompactButtonStyle { MarkXCompactButtonStyle(prominent: true) }
}

extension ButtonStyle where Self == MarkXTextButtonStyle {
    static var markxText: MarkXTextButtonStyle { MarkXTextButtonStyle() }
}
