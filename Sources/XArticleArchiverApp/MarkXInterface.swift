import AppKit
import SwiftUI

enum MarkXInterface {
    static let inset: CGFloat = 24
    static let spacing: CGFloat = 20
    static let cornerRadius: CGFloat = 12
    static let canvas = neutral(light: 0.965, dark: 0.105)
    static let surface = neutral(light: 1, dark: 0.15)

    private static func neutral(light: CGFloat, dark: CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(calibratedWhite: isDark ? dark : light, alpha: 1)
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
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(symbolColor)
                .frame(width: 40, height: 40)
                .background(MarkXInterface.surface, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 20, weight: .semibold))
                Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
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
                    Text(title).font(.system(size: 13, weight: .semibold))
                    if let detail {
                        Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
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
        .font(.system(size: 11))
        .lineSpacing(3)
    }
}

struct MarkXFooter<Actions: View>: View {
    var note = ""
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                Text(note).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                actions
            }
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
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }
}
