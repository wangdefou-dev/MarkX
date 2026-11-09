import AppKit
import SwiftUI

/// A two-point increase over the original interface, before the reader's own zoom.
enum MarkXTypography {
    static func pointSize(_ base: CGFloat, scale: CGFloat = 1) -> CGFloat {
        (base + 2) * scale
    }

    static func system(size: CGFloat, scale: CGFloat = 1, weight: Font.Weight = .regular,
                       design: Font.Design = .default) -> Font {
        .system(size: pointSize(size, scale: scale), weight: weight, design: design)
    }

    static func system(_ style: Font.TextStyle, design: Font.Design = .default) -> Font {
        let nativeStyle: NSFont.TextStyle
        switch style {
        case .largeTitle: nativeStyle = .largeTitle
        case .title: nativeStyle = .title1
        case .title2: nativeStyle = .title2
        case .title3: nativeStyle = .title3
        case .headline: nativeStyle = .headline
        case .subheadline: nativeStyle = .subheadline
        case .callout: nativeStyle = .callout
        case .caption: nativeStyle = .caption1
        case .caption2: nativeStyle = .caption2
        case .footnote: nativeStyle = .footnote
        default: nativeStyle = .body
        }
        let nativeDesign: NSFontDescriptor.SystemDesign
        switch design {
        case .monospaced: nativeDesign = .monospaced
        case .rounded: nativeDesign = .rounded
        case .serif: nativeDesign = .serif
        default: nativeDesign = .default
        }
        let base = NSFont.preferredFont(forTextStyle: nativeStyle)
        let descriptor = base.fontDescriptor.withDesign(nativeDesign) ?? base.fontDescriptor
        return Font(NSFont(descriptor: descriptor, size: pointSize(base.pointSize)) ?? base)
    }

    static var largeTitle: Font { system(.largeTitle) }
    static var title: Font { system(.title) }
    static var title2: Font { system(.title2) }
    static var title3: Font { system(.title3) }
    static var headline: Font { system(.headline) }
    static var subheadline: Font { system(.subheadline) }
    static var body: Font { system(.body) }
    static var callout: Font { system(.callout) }
    static var caption: Font { system(.caption) }
    static var caption2: Font { system(.caption2) }
    static var footnote: Font { system(.footnote) }
}
