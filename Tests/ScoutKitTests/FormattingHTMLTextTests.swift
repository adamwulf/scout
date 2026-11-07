import XCTest
@testable import ScoutKit

final class FormattingHTMLTextTests: XCTestCase {
    private func text(_ html: String) -> String { OutputFormatter.HTMLText.plainText(html) }

    func testParagraphsLineBreaksAndWhitespace() {
        XCTAssertEqual(text("<p>Hello&nbsp;there,\n   friend</p><p>Line one<br/>Line two<BR>Line three</p>"),
                       "Hello there, friend\n\nLine one\nLine two\nLine three")
        XCTAssertEqual(text("<h1>Title</h1>text after<hr>end"), "Title\n\ntext after\n\nend")
        XCTAssertEqual(text("<div>Hi,</div><div>I need help.</div>"), "Hi,\nI need help.")
    }

    func testListsAndNestedLists() {
        XCTAssertEqual(text("<p>Steps:</p><ul><li>One</li><li>Two<ul><li>Nested</li></ul></li></ul><ol><li>First</li></ol>"),
                       "Steps:\n\n- One\n- Two\n  - Nested\n\n- First")
    }

    func testLinksKeepUsefulTargets() {
        XCTAssertEqual(text(#"<p>Read <a href="https://x.com/?a=1&amp;b=2">the docs</a>.</p>"#), "Read [the docs](https://x.com/?a=1&b=2).")
        XCTAssertEqual(text(#"<p>Read <a href='https://x.com'> spaced </a> now</p>"#), "Read [spaced](https://x.com) now")
        XCTAssertEqual(text(#"<a href="https://x.com">https://x.com</a>"#), "https://x.com")
        XCTAssertEqual(text(#"<a href="MAILTO:a@b.com">a@b.com</a>"#), "a@b.com")
        XCTAssertEqual(text(#"<a href=https://x.com/img><img src="x.png" alt="logo"></a>"#), "https://x.com/img")
        XCTAssertEqual(text(##"<a href="javascript:alert(1)">click</a> <a>bare</a> <a href="#top">top</a>"##), "click bare top")
    }

    func testEntities() {
        XCTAssertEqual(text("<p>&lt;b&gt; &amp;amp; &#65;&#x42; &unknown; &copy; AT&T &#0; &#xZZ;</p>"),
                       "<b> &amp; AB &unknown; © AT&T \u{FFFD} &#xZZ;")
    }

    func testScriptsStylesCommentsAndDeclarationsAreSkipped() {
        let html = "<!DOCTYPE html><html><head><title>Mail</title><style>p{color:red}</style></head>"
            + "<body><script>alert('x')</script><!-- hidden <p>no</p> --><p>Visible</p></body></html>"
        XCTAssertEqual(text(html), "Visible")
    }

    func testPlainTextKeepsItsLineBreaks() {
        XCTAssertEqual(text("Line 1\r\nLine 2\n\n\n\nLine 3  \n"), "Line 1\nLine 2\n\nLine 3")
        XCTAssertEqual(text("if x<y then\n  ok"), "if x<y then\n  ok")
        XCTAssertEqual(text("1 < 2\nAT&amp;T"), "1 < 2\nAT&amp;T")
    }

    func testLiteralAngleBracketsAndUnclosedTags() {
        XCTAssertEqual(text("<p>1 < 2 and 3 > 2</p>"), "1 < 2 and 3 > 2")
        XCTAssertEqual(text("<p>Hello</p> <b"), "Hello\n\n<b")
        XCTAssertEqual(text(#"<p title="a > b">Quoted attribute</p>"#), "Quoted attribute")
    }

    func testPreformattedTextKeepsWhitespace() {
        XCTAssertEqual(text("<pre>line 1\n  indented</pre><p>after</p>"), "line 1\n  indented\n\nafter")
    }

    func testTablesAndInlineTags() {
        XCTAssertEqual(text("<table><tr><td>A</td><td><b>B</b></td></tr><tr><td>C</td></tr></table>"), "A B\nC")
        XCTAssertEqual(text("<p><strong>Bold</strong> and <em>italic</em><span>!</span></p>"), "Bold and italic!")
    }

    func testControlCharactersFromMarkupAndEntitiesAreRemoved() {
        XCTAssertEqual(text("<p>Hi&#27;[31m red\u{7} &#x202E;txt</p>"), "Hi[31m red txt")
    }

    func testEmptyInput() {
        XCTAssertEqual(text(""), "")
        XCTAssertEqual(text("<p> </p><br>"), "")
    }
}
