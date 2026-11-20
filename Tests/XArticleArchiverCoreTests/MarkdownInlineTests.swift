import Foundation
import XCTest
@testable import XArticleArchiverCore

final class MarkdownInlineTests: XCTestCase {
    private func inline(_ text: String, _ styles: [InlineStyleRange] = [], links: [LinkRange] = []) -> String {
        MarkdownRenderer.renderInlineText(text, styles: styles, links: links)
    }

    /// `这是**「重点」**内容` does not parse as bold in CommonMark; HTML does.
    func testEmphasisNextToCJKPunctuationFallsBackToHTML() {
        XCTAssertEqual(inline("这是「重点」内容", [InlineStyleRange(offset: 2, length: 4, style: .bold)]), "这是<strong>「重点」</strong>内容")
        XCTAssertEqual(inline("「重点」来了", [InlineStyleRange(offset: 0, length: 4, style: .bold)]), "<strong>「重点」</strong>来了")
        XCTAssertEqual(inline("引用“话”。", [InlineStyleRange(offset: 2, length: 3, style: .italic)]), "引用<em>“话”</em>。")
        XCTAssertEqual(inline("删掉 这段", [InlineStyleRange(offset: 2, length: 3, style: .strikethrough)]), "删掉<del> 这段</del>")
    }

    func testPlainEmphasisKeepsMarkdownDelimitersThatReallyParse() throws {
        let cases: [(String, [InlineStyleRange], String)] = [
            ("前面加粗后面", [InlineStyleRange(offset: 2, length: 2, style: .bold)], "前面**加粗**后面"),
            ("「重点」", [InlineStyleRange(offset: 0, length: 4, style: .bold)], "**「重点」**"),
            ("斜体文字", [InlineStyleRange(offset: 0, length: 2, style: .italic)], "*斜体*文字"),
            ("删除线", [InlineStyleRange(offset: 0, length: 3, style: .strikethrough)], "~~删除线~~")
        ]
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        for (text, styles, expected) in cases {
            let markdown = inline(text, styles)
            XCTAssertEqual(markdown, expected)
            // Foundation's CommonMark parser must consume every delimiter.
            let parsed = String(try AttributedString(markdown: markdown, options: options).characters)
            XCTAssertEqual(parsed, text, markdown)
        }
    }

    func testEmphasisBesideALinkStaysMarkdownWhenItParses() {
        let url = URL(string: "https://example.test")!
        XCTAssertEqual(inline("第一段链接", [InlineStyleRange(offset: 0, length: 3, style: .bold)],
                              links: [LinkRange(offset: 3, length: 2, url: url)]),
                       "**第一段**[链接](https://example.test)")
        // Bold exactly around a link inside CJK text: `**[` after a letter cannot open.
        XCTAssertEqual(inline("这是链接内容", [InlineStyleRange(offset: 2, length: 2, style: .bold)],
                              links: [LinkRange(offset: 2, length: 2, url: url)]),
                       "这是<strong>[链接](https://example.test)</strong>内容")
    }

    func testCodeSpansKeepTheirContentRaw() {
        XCTAssertEqual(inline("用 a_b.c 函数", [InlineStyleRange(offset: 2, length: 5, style: .code)]), "用 `a_b.c` 函数")
        XCTAssertEqual(inline("a`b", [InlineStyleRange(offset: 0, length: 3, style: .code)]), "``a`b``")
        XCTAssertEqual(inline("x", [InlineStyleRange(offset: 0, length: 1, style: .code), InlineStyleRange(offset: 0, length: 1, style: .bold)]),
                       "<code>**x**</code>")
    }

    func testCharactersWithMarkdownMeaningAreEscaped() {
        XCTAssertEqual(inline("价格 $100 ~ $200 & ==高亮=="), "价格 \\$100 \\~ \\$200 \\& \\=\\=高亮\\=\\=")
        XCTAssertEqual(inline("1. 不是列表"), "1\\. 不是列表")
    }

    func testLineBreaksInsideBlocksSurviveInMarkdown() throws {
        let document = CanonicalDocument(
            title: "换行", titleSource: "test", authorName: "作者", authorHandle: "writer", contentType: .xArticle,
            sourceURL: URL(string: "https://x.com/writer/status/1")!, sourcePostID: "1",
            publishedAt: Date(timeIntervalSince1970: 0),
            blocks: [
                CanonicalBlock(kind: .paragraph, text: "第一行\n第二行"),
                CanonicalBlock(kind: .unorderedListItem, text: "条目\n续行"),
                CanonicalBlock(kind: .quote, text: "引用一\n引用二\n\n新段")
            ],
            media: []
        )
        let markdown = try MarkdownRenderer.render(document: document)
        XCTAssertTrue(markdown.contains("第一行<br>\n第二行\n"), markdown)
        XCTAssertTrue(markdown.contains("- 条目<br>\n  续行\n"), markdown)
        XCTAssertTrue(markdown.contains("> 引用一<br>\n> 引用二\n>\n> 新段\n"), markdown)
        try MarkdownRenderer.validateRenderedText(document: document, markdown: markdown)
    }
}
