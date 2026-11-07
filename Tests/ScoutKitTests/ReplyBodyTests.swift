import Foundation
import XCTest
@testable import ScoutKit

final class ReplyBodyTests: XCTestCase {
    private struct UnexpectedRead: Error {}

    /// Reads with injected stdin and files. A nil `stdin` fails the test if standard input is read.
    private func read(body: String? = nil, file: String? = nil, terminal: Bool = false,
                      stdin: Data? = nil, files: [String: Data] = [:]) throws -> String {
        try ReplyBody.read(
            body: body, file: file, stdinIsTerminal: terminal,
            readStdin: {
                guard let stdin else {
                    XCTFail("Standard input must not be read")
                    throw UnexpectedRead()
                }
                return stdin
            },
            readFile: { path in
                guard let data = files[path] else { throw CocoaError(.fileReadNoSuchFile) }
                return data
            }
        )
    }

    private func assertInvalidInput(_ expression: @autoclosure () throws -> String, containing fragment: String? = nil,
                                    file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            guard case ScoutError.invalidInput(let message) = error else {
                return XCTFail("Unexpected error \(error)", file: file, line: line)
            }
            if let fragment {
                XCTAssertTrue(message.contains(fragment), "\"\(message)\" lacks \"\(fragment)\"", file: file, line: line)
            }
        }
    }

    // MARK: Sources

    func testReadsInlineBodyFileAndPipedStdinUnchanged() throws {
        XCTAssertEqual(try read(body: "Thanks!\n"), "Thanks!\n")
        XCTAssertEqual(try read(file: "reply.html", files: ["reply.html": Data("<p>Zoë 👋 李</p>\n".utf8)]), "<p>Zoë 👋 李</p>\n")
        XCTAssertEqual(try read(file: "-", stdin: Data("From a pipe\n".utf8)), "From a pipe\n")
    }

    func testDashOnTerminalFailsInsteadOfWaiting() {
        assertInvalidInput(try read(file: "-", terminal: true), containing: "terminal")
    }

    func testTerminalStdinDoesNotAffectOtherSources() throws {
        XCTAssertEqual(try read(body: "Hi", terminal: true), "Hi")
        XCTAssertEqual(try read(file: "reply.txt", terminal: true, files: ["reply.txt": Data("Hi".utf8)]), "Hi")
    }

    func testRequiresExactlyOneSource() {
        assertInvalidInput(try read(), containing: "--body")
        assertInvalidInput(try read(body: "Hi", file: "reply.txt", files: ["reply.txt": Data("Hi".utf8)]), containing: "not both")
        assertInvalidInput(try read(file: ""), containing: "path")
    }

    func testRejectsInvalidUTF8FromFilesAndStdin() {
        for bytes in [[0x48, 0xFF, 0x69], [0xE2, 0x82], [0xC0, 0xAF]] as [[UInt8]] {
            assertInvalidInput(try read(file: "bad.txt", files: ["bad.txt": Data(bytes)]), containing: "UTF-8")
            assertInvalidInput(try read(file: "-", stdin: Data(bytes)), containing: "UTF-8")
        }
    }

    func testRejectsEmptyAndWhitespaceBodiesFromEverySource() {
        for blank in ["", " ", "\n", " \r\n\t ", "\u{00A0}\u{3000}"] {
            assertInvalidInput(try read(body: blank), containing: "empty")
            assertInvalidInput(try read(file: "blank.txt", files: ["blank.txt": Data(blank.utf8)]), containing: "empty")
            assertInvalidInput(try read(file: "-", stdin: Data(blank.utf8)), containing: "empty")
        }
    }

    func testReadFailuresNameTheSource() {
        assertInvalidInput(try read(file: "missing.txt"), containing: "body file missing.txt")
        XCTAssertThrowsError(try ReplyBody.read(body: nil, file: "-", stdinIsTerminal: false,
                                                readStdin: { throw CocoaError(.fileReadUnknown) }, readFile: { _ in Data() })) { error in
            guard case ScoutError.invalidInput(let message) = error else { return XCTFail("Unexpected error \(error)") }
            XCTAssertTrue(message.contains("standard input"))
        }
        XCTAssertThrowsError(try ReplyBody.read(body: nil, file: "x", stdinIsTerminal: false, readStdin: { Data() },
                                                readFile: { _ in throw ScoutError.configuration("kept") })) { error in
            XCTAssertEqual(error as? ScoutError, .configuration("kept"))
        }
    }

    // MARK: Preparation

    func testPlainTextIsEscapedAndLineBreaksBecomeBR() throws {
        XCTAssertEqual(try ReplyBody.prepare("Tom & \"Jerry\" <tj@example.com>\nIt's fine\r\nBye\rEnd", html: false),
                       "Tom &amp; &quot;Jerry&quot; &lt;tj@example.com&gt;<br>It&#39;s fine<br>Bye<br>End")
        XCTAssertEqual(try ReplyBody.prepare("<p>not html</p>", html: false), "&lt;p&gt;not html&lt;/p&gt;")
        XCTAssertEqual(try ReplyBody.prepare("Zoë 👋", html: false), "Zoë 👋")
    }

    func testPlainTextTrimsSurroundingBlankLines() throws {
        XCTAssertEqual(try ReplyBody.prepare("\n  Hello\n\nWorld\n", html: false), "Hello<br><br>World")
    }

    func testHTMLIsReturnedUnchanged() throws {
        let html = "  <p>Hi &amp; \"bye\"</p>\r\n<br>\n"
        XCTAssertEqual(try ReplyBody.prepare(html, html: true), html)
    }

    func testRejectsEmptyBodies() {
        for html in [false, true] {
            for blank in ["", " \n\t", "\r\n"] {
                assertInvalidInput(try ReplyBody.prepare(blank, html: html), containing: "empty")
            }
        }
    }

    func testRejectsUnresolvedVariablesInPlainTextAndHTML() {
        for html in [false, true] {
            assertInvalidInput(try ReplyBody.prepare("Hi {%customer.firstName%},", html: html), containing: "{%customer.firstName%}")
            assertInvalidInput(try ReplyBody.prepare("<p>Hi {%customer.firstName,fallback=there%}</p>", html: html),
                               containing: "{%customer.firstName,fallback=there%}")
            assertInvalidInput(try ReplyBody.prepare("Broken {% customer.firstName", html: html), containing: "unresolved Help Scout variable.")
        }
        XCTAssertEqual(try ReplyBody.prepare("100% sure {not a variable} %}", html: false), "100% sure {not a variable} %}")
    }

    func testVariableErrorsDoNotEchoMessageText() {
        let secret = String(repeating: "private customer detail ", count: 10)
        for text in ["{%" + secret + "%}", "Hello {%customer\nprivate text%}"] {
            XCTAssertThrowsError(try ReplyBody.prepare(text, html: true)) { error in
                guard case ScoutError.invalidInput(let message) = error else { return XCTFail("Unexpected error \(error)") }
                XCTAssertFalse(message.contains("private"))
                XCTAssertTrue(message.contains("unresolved Help Scout variable."))
            }
        }
    }

    func testVariablesAreRejectedFromEveryInputSource() throws {
        let body = "Hi {%customer.firstName%}"
        let sources: [(String, () throws -> String, Bool)] = [
            ("--body", { try self.read(body: body) }, false),
            ("--body --html", { try self.read(body: "<p>\(body)</p>") }, true),
            ("--body-file", { try self.read(file: "reply.txt", files: ["reply.txt": Data(body.utf8)]) }, false),
            ("--body-file --html", { try self.read(file: "reply.html", files: ["reply.html": Data("<p>\(body)</p>".utf8)]) }, true),
            ("--body-file -", { try self.read(file: "-", stdin: Data(body.utf8)) }, false),
            ("--template", { "<p>\(body)</p>" }, true),
        ]
        for (name, source, html) in sources {
            let text = try source()
            XCTAssertThrowsError(try ReplyBody.prepare(text, html: html), name) { error in
                XCTAssertEqual(error as? ScoutError, .invalidInput(
                    "The reply body contains an unresolved Help Scout variable {%customer.firstName%}. Replace variables with literal text before drafting or sending, for example: scout template ID > reply.html, edit it, then use --body-file reply.html --html."
                ), name)
            }
        }
    }
}
