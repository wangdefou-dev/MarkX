import Foundation
import SwiftUI
import XCTest
@testable import XArticleArchiverApp
import XArticleArchiverCore

final class ArticleInlineTextTests: XCTestCase {
    /// Every X inline format shows as styling, never as Markdown or HTML marks.
    func testAllInlineFormatsBecomeAttributesWithoutLiteralMarks() throws {
        let text = "这是「重点」和斜体，下划线、删除线、code 与链接。"
        let ns = text as NSString
        func r(_ s: String) -> NSRange { ns.range(of: s) }
        let styles = [
            InlineStyleRange(offset: r("「重点」").location, length: r("「重点」").length, style: .bold),
            InlineStyleRange(offset: r("「重点」").location, length: r("「重点」").length, style: .italic),
            InlineStyleRange(offset: r("下划线").location, length: r("下划线").length, style: .underline),
            InlineStyleRange(offset: r("删除线").location, length: r("删除线").length, style: .strikethrough),
            InlineStyleRange(offset: r("code").location, length: r("code").length, style: .code)
        ]
        let url = URL(string: "https://example.test/a")!
        let links = [LinkRange(offset: r("链接").location, length: r("链接").length, url: url)]

        let attributed = ArticleInlineText.attributed(text, styles: styles, links: links)
        XCTAssertEqual(String(attributed.characters), text, "no markers are added to the visible text")

        func attributes(of word: String) -> AttributedString.Runs.Run {
            let range = try! XCTUnwrap(Range(r(word), in: attributed))
            return attributed[range].runs.first!
        }
        XCTAssertEqual(attributes(of: "「重点」").inlinePresentationIntent, [.stronglyEmphasized, .emphasized])
        XCTAssertEqual(attributes(of: "下划线").underlineStyle, .single)
        XCTAssertEqual(attributes(of: "删除线").strikethroughStyle, .single)
        XCTAssertEqual(attributes(of: "code").inlinePresentationIntent, .code)
        XCTAssertEqual(attributes(of: "链接").link, url)
    }

    func testOutOfRangeStylesAreIgnored() {
        let attributed = ArticleInlineText.attributed("短", styles: [InlineStyleRange(offset: 0, length: 9, style: .bold)], links: [])
        XCTAssertEqual(String(attributed.characters), "短")
        XCTAssertNil(attributed.runs.first?.inlinePresentationIntent)
    }

    func testReadingScaleFollowsTheTwentyOneSeventeenFifteenThirteenLadder() {
        let typography = ArticleTypography(1)
        XCTAssertEqual(typography.bodySize, 15)
        XCTAssertEqual(typography.headingSize(level: 1), 21, accuracy: 0.001)
        XCTAssertEqual(typography.headingSize(level: 2), 17, accuracy: 0.001)
        XCTAssertEqual(typography.smallSize, 13, accuracy: 0.001)
        // Line height 1.8: ~1.2 natural + 0.6em added.
        XCTAssertEqual(typography.bodyLineSpacing, 9, accuracy: 0.001)
        XCTAssertGreaterThan(typography.paragraphSpacing, typography.bodyLineSpacing * 2)
    }
}
