import AppKit
import SwiftUI
import XCTest
@testable import XArticleArchiverApp
import XArticleArchiverCore

/// Renders a document with every X Article block and inline format off
/// screen. Set MARKX_RENDER_DIR to also save the PNG for visual review.
@MainActor
final class ArticleRenderingSnapshotTests: XCTestCase {
    static func sampleDocument() -> CanonicalDocument {
        let link = URL(string: "https://example.test/source")!
        func styled(_ text: String, _ parts: [(String, InlineStyleRange.Style)]) -> CanonicalBlock {
            let ns = text as NSString
            return CanonicalBlock(kind: .paragraph, text: text, inlineStyles: parts.map {
                let r = ns.range(of: $0.0); return InlineStyleRange(offset: r.location, length: r.length, style: $0.1)
            })
        }
        return CanonicalDocument(
            title: "想让公众号有苹果那种高级感", authorName: "作者", authorHandle: "writer", contentType: .xArticle,
            sourceURL: URL(string: "https://x.com/writer/status/1")!, sourcePostID: "1", publishedAt: Date(timeIntervalSince1970: 0),
            blocks: [
                CanonicalBlock(kind: .paragraph, text: "想让公众号有苹果那种高级感，先别急着加设计，记住三个原则：留白、层级、克制。"),
                CanonicalBlock(kind: .heading, text: "一、留白", level: 1),
                styled("苹果的设计很少把信息塞得特别满。正文用 15 号，行距 1.8，一段尽量控制在三到五行，这样读起来不会累，也不会显得拥挤和局促。", [("15 号", .bold), ("行距 1.8", .bold)]),
                styled("如果一句话特别「重要」，不要马上加边框、底色或下划线，也不要删除线，直接单独成段。", [("「重要」", .bold), ("下划线", .underline), ("删除线", .strikethrough)]),
                CanonicalBlock(kind: .heading, text: "第二级小标题", level: 2),
                CanonicalBlock(kind: .unorderedListItem, text: "一级小标题 21 号加粗"),
                CanonicalBlock(kind: .unorderedListItem, text: "嵌套的二级要点", depth: 1),
                CanonicalBlock(kind: .orderedListItem, text: "正文保持 15 号"),
                CanonicalBlock(kind: .orderedListItem, text: "说明文字降到 13 号"),
                CanonicalBlock(kind: .quote, text: "空白本身就已经是在强调。\n这是引用的第二行。"),
                {
                    let text = "调用 renderInlineText() 或访问链接。" as NSString
                    let code = text.range(of: "renderInlineText()"), anchor = text.range(of: "链接")
                    return CanonicalBlock(kind: .paragraph, text: text as String,
                                          inlineStyles: [InlineStyleRange(offset: code.location, length: code.length, style: .code)],
                                          links: [LinkRange(offset: anchor.location, length: anchor.length, url: link)])
                }(),
                CanonicalBlock(kind: .code, text: "let size = 15\nlet lineHeight = 1.8", sourceEntityType: "browser-rendered-code:swift"),
                CanonicalBlock(kind: .divider),
                CanonicalBlock(kind: .table, text: "层级 字号", tableRows: [
                    [CanonicalTableCell(text: "层级", isHeader: true), CanonicalTableCell(text: "字号", isHeader: true)],
                    [CanonicalTableCell(text: "一级标题"), CanonicalTableCell(text: "21")],
                    [CanonicalTableCell(text: "正文"), CanonicalTableCell(text: "15")]
                ]),
                CanonicalBlock(kind: .embeddedPost, text: "引用", links: [LinkRange(offset: 0, length: 2, url: link)]),
                CanonicalBlock(kind: .paragraph, text: "层级之间要真正拉开，而不是标题 17、正文 16，最后看起来几乎没有区别。")
            ]
        )
    }

    func testRendersEveryBlockKind() throws {
        let view = ArticleDocumentPreview(document: Self.sampleDocument(), textScale: 1)
            .padding(32).frame(width: 720).background(Color.white).environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        XCTAssertGreaterThan(image.size.height, 600)
        if let directory = ProcessInfo.processInfo.environment["MARKX_RENDER_DIR"],
           let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: directory).appending(path: "article-render.png"))
        }
    }
}
