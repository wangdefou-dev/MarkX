import AppKit
import SwiftUI

enum MarkXInterface {
    static let inset: CGFloat = 24
    static let spacing: CGFloat = 20
    static let cornerRadius: CGFloat = 14

    // Calm neutral palette (the same slate scale as Fog's reading view):
    // low saturation, hairline borders, soft washes instead of strong fills.
    static let canvas = dynamic(light: 0xF9F9FB, dark: 0x18191B)
    static let surface = dynamic(light: 0xFFFFFF, dark: 0x212225)
    /// Flat reading background behind article text.
    static let reading = dynamic(light: 0xFCFCFD, dark: 0x111113)
    static let hairline = dynamic(light: 0x00002D, lightAlpha: 0.09, dark: 0xD3EDF8, darkAlpha: 0.11)
    /// Hover and quiet-selection wash.
    static let wash = dynamic(light: 0x000033, lightAlpha: 0.06, dark: 0xDDEAF8, darkAlpha: 0.08)

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

struct MarkXPaneHeader: View {
    let title: String
    let subtitle: String
    let symbol: String
    var symbolColor: Color = .secondary

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(MarkXTypography.system(size: 19, weight: .medium))
                .foregroundStyle(symbolColor)
                .frame(width: 40, height: 40)
                .background(MarkXInterface.surface, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(MarkXInterface.hairline, lineWidth: 1))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(MarkXTypography.system(size: 20, weight: .semibold))
                Text(subtitle).font(MarkXTypography.system(size: 12)).foregroundStyle(.secondary)
                    .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(MarkXInterface.inset)
    }
}

struct MarkXSection<Content: View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !title.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(MarkXTypography.system(size: 13, weight: .semibold))
                    if let detail {
                        Text(detail).font(MarkXTypography.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .markxSurface()
    }
}

struct MarkXInfoLine: View {
    let symbol: String
    let text: String
    var color: Color = .secondary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(color).frame(width: 15)
            Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .font(MarkXTypography.system(size: 11))
        .lineSpacing(3)
    }
}

struct MarkXFooter<Actions: View>: View {
    var note = ""
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(MarkXInterface.hairline).frame(height: 1)
            HStack(spacing: 10) {
                Text(note).font(MarkXTypography.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                actions
            }
            .buttonStyle(.markxPill)
            .controlSize(.regular)
            .padding(.horizontal, MarkXInterface.inset)
            .padding(.vertical, 16)
        }
        .background(MarkXInterface.canvas)
    }
}

extension View {
    func markxSurface() -> some View {
        background(MarkXInterface.surface, in: RoundedRectangle(cornerRadius: MarkXInterface.cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: MarkXInterface.cornerRadius)
                .strokeBorder(MarkXInterface.hairline, lineWidth: 1))
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

/// Wide pill buttons (Fog-style): a filled accent pill for the main action and
/// a soft wash pill for secondary ones.
struct MarkXPillButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(MarkXTypography.system(size: 13, weight: .medium))
            .foregroundStyle(prominent ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, 22)
            .frame(minWidth: 96, minHeight: 32)
            .background(
                Capsule().fill(prominent ? AnyShapeStyle(.tint) : AnyShapeStyle(MarkXInterface.wash))
            )
            .overlay(Capsule().strokeBorder(prominent ? Color.clear : MarkXInterface.hairline, lineWidth: 1))
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
            .contentShape(Capsule())
    }
}

extension ButtonStyle where Self == MarkXPillButtonStyle {
    static var markxPill: MarkXPillButtonStyle { MarkXPillButtonStyle() }
    static var markxPillProminent: MarkXPillButtonStyle { MarkXPillButtonStyle(prominent: true) }
}
