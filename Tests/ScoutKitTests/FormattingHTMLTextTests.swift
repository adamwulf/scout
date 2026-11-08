import Foundation
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
        XCTAssertEqual(text(#"<a href=https://x.com/img><img src="x.png" alt="logo"></a>"#), "[[image not shown]](https://x.com/img)")
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
        XCTAssertEqual(text("1 < 2\nAT&amp;T &copy; &bogus; R&D"), "1 < 2\nAT&T © &bogus; R&D")
    }

    func testPlainTextControlEntitiesAreRemovedAfterDecoding() {
        XCTAssertEqual(text("Hi&#27;[31m&#7; there\n&#x202E;next&#x9B;"), "Hi[31m there\nnext")
    }

    func testPreparedPlainTextReadsBackAsWritten() throws {
        let replies = [
            "It's fine",
            "Tom & Jerry <tj@example.com> said \"hi\"",
            "<p>not html</p>",
            "Line one\nLine two\n\nNew paragraph",
            "Hi \"Jane\",\r\nIt's <ok> & done.\nBye",
        ]
        for reply in replies {
            let html = try ReplyBody.prepare(reply, html: false)
            XCTAssertEqual(text(html), reply.replacingOccurrences(of: "\r\n", with: "\n"), html)
        }
    }

    func testListItemsKeepBulletWithBlockContent() {
        XCTAssertEqual(text("<ul><li><p>One</p></li><li><div>Two</div></li><li>\n<p><br>Three</p></li><li></li></ul><p>After</p>"),
                       "- One\n- Two\n- Three\n-\n\nAfter")
        XCTAssertEqual(text("<ol><li><p>First</p><p>More</p></li><li><ul><li>Nested</li></ul></li></ol>"),
                       "- First\nMore\n-\n  - Nested")
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

    // MARK: Images

    private let canary = InlineImageTests.canaryImage
    private let appleMail = InlineImageTests.appleMailImage
    private let canaryName = "6ED8F9BB-BF20-4EF1-930F-E829E7355D47_4_5005_c.jpeg"
    private let appleMailName = "CleanShot-2026-10-15-at-14-09-13-2x.png"

    /// Canary Mail: a read-receipt pixel, then the same pasted image twice.
    private var canaryBody: String {
        """
        <div>The export button does nothing.</div>
        <img id="ex-CE46" alt="" width="0" height="0" src="https://receipts.canarymail.io/track/D98D.png">
        <img src="\(canary)" style="max-width:90vw;width:179px;" alt="\(canary)">
        <div>Same screenshot again:</div>
        <img src="\(canary)" style="max-width:90vw;width:179px;" alt="\(canary)">
        --<br>Sent from Eason
        """
    }

    /// Apple Mail: the alt text is the original file name, which differs from the URL's.
    private var appleMailBody: String {
        #"<div>See screenshot:</div><div><img alt="CleanShot 2026-10-15 at 14.09.13@2x.png" width="640" src="\#(appleMail)"></div>"#
    }

    func testHelpScoutInlineImagesRenderInPlaceOnceWithoutTrackingPixels() throws {
        let rendered = OutputFormatter.HTMLText.render(canaryBody)
        XCTAssertEqual(rendered.text, """
        The export button does nothing.
        ![\(canaryName)](\(canary))
        Same screenshot again:
        --
        Sent from Eason
        """)
        XCTAssertEqual(rendered.inlineImages, [try XCTUnwrap(InlineImage(source: canary))])
        XCTAssertFalse(rendered.text.contains("canarymail"))

        let saved = OutputFormatter.HTMLText.render(canaryBody, inlineImagePaths: [canary: "files/inline-abc-\(canaryName)"]).text
        XCTAssertTrue(saved.contains("\n![\(canaryName)](files/inline-abc-\(canaryName))\n"), saved)
        XCTAssertFalse(saved.contains("cloudfront"))
    }

    func testInlineImageLabelsUseTheURLFileNameAndEscapeLikeAttachments() {
        XCTAssertEqual(text(appleMailBody), "See screenshot:\n![\(appleMailName)](\(appleMail))")
        XCTAssertEqual(OutputFormatter.HTMLText.render(appleMailBody, inlineImagePaths: [appleMail: "my files/inline-abc-\(appleMailName)"]).text,
                       "See screenshot:\n![\(appleMailName)](<my files/inline-abc-\(appleMailName)>)")
        let bracketed = "https://d33v4339jhl8k0.cloudfront.net/inline/1/abc/def/a%5Bb%5D%20(1).png"
        XCTAssertEqual(text(#"<p>Hi <img src="\#(bracketed)"> there</p>"#),
                       #"Hi ![a\[b\] (1).png](<\#(bracketed)>) there"#)
    }

    func testExternalImagesAreNeverLinked() {
        let html = """
        <p>Logo <img src="https://tracker.example.com/open.png?id=1" alt="https://tracker.example.com/open.png?id=1">
        <img src="https://tracker.example.com/open.png?id=1"> <img src="HTTP://Mixed.Example.COM/x.png">
        <img src="https://d33v4339jhl8k0.cloudfront.net.evil.com/inline/1/a/b/x.png">
        <img src="https://d33v4339jhl8k0.cloudfront.net/customer-avatar/1/a.png">
        <img src="data:image/png;base64,AAAA"> <img src="cid:image001.png@01D9"> <img src="logo.png">
        <img src="https://tracker.example.com/pixel.gif" width="1" height=" 0 "> <img src=" "> <img alt="no source"> end</p>
        """
        let output = text(html)
        XCTAssertEqual(output, "Logo [external image not fetched: tracker.example.com] [external image not fetched: mixed.example.com] "
                       + "[external image not fetched: d33v4339jhl8k0.cloudfront.net.evil.com] "
                       + "[external image not fetched: d33v4339jhl8k0.cloudfront.net] "
                       + "[image not shown] [image not shown] [image not shown] end")
        for fragment in ["](", "open.png", "pixel", "data:", "cid:", "x.png", "customer-avatar"] {
            XCTAssertFalse(output.contains(fragment), fragment)
        }
        XCTAssertEqual(OutputFormatter.HTMLText.render(html).inlineImages, [])
    }

    func testImagesInSkippedMarkupAreIgnored() {
        let html = #"<!-- <img src="\#(canary)"> --><style><img src="\#(canary)"></style><p>Only text</p>"#
        XCTAssertEqual(OutputFormatter.HTMLText.render(html), .init(text: "Only text", inlineImages: []))
        XCTAssertEqual(OutputFormatter.HTMLText.render("plain \(canary)"), .init(text: "plain \(canary)", inlineImages: []))
    }

    func testEmptyInput() {
        XCTAssertEqual(text(""), "")
        XCTAssertEqual(text("<p> </p><br>"), "")
    }
}
