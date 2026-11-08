import Foundation
import XCTest
@testable import ScoutKit

final class FormattingListTests: XCTestCase {
    private func decode(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    private func conversation(id: Int, number: Int, status: String, customer: JSONValue, subject: String) -> JSONValue {
        .object([
            "id": .integer(id), "number": .integer(number), "status": .string(status),
            "primaryCustomer": customer, "subject": .string(subject),
        ])
    }

    // MARK: JSON

    func testJSONRoundTripsPageAndPreservesRawValues() throws {
        let item: JSONValue = .object([
            "id": .integer(10),
            "preview": .string("<p>Hi &amp; \"bye\"</p>\n/path"),
            "score": .number(4.5),
            "flag": .bool(false),
            "missing": .null,
            "_embedded": .object(["emails": .array([.object(["value": .string("a@example.com")])])]),
        ])
        let page = ResourcePage(items: [item], nextCursor: "abc+/=")
        let output = try OutputFormatter.list(page, kind: .conversation, format: .json)

        XCTAssertTrue(output.hasSuffix("}\n"))
        XCTAssertEqual(try JSONDecoder().decode(ResourcePage.self, from: Data(output.utf8)), page)
        XCTAssertEqual(try decode(output)["items"].array?.first, item)
        XCTAssertEqual(try decode(output)["nextPage"], .null)
        XCTAssertEqual(try OutputFormatter.list(page, kind: .conversation, format: .json), output, "Output is stable")
    }

    func testJSONEmptyPageKeepsStableShape() throws {
        let output = try OutputFormatter.list(ResourcePage(items: []), kind: .inbox, format: .json)
        XCTAssertEqual(try decode(output), .object(["items": .array([]), "nextCursor": .null, "nextPage": .null]))
        XCTAssertEqual(try JSONDecoder().decode(ResourcePage.self, from: Data(output.utf8)), ResourcePage(items: []))
    }

    func testJSONPageNumberContinuation() throws {
        let output = try OutputFormatter.list(ResourcePage(items: [], nextPage: 3), kind: .inbox, format: .json)
        XCTAssertEqual(try decode(output)["nextPage"], .integer(3))
    }

    // MARK: JSONL and ID

    func testJSONLEmitsOneCompactItemPerLine() throws {
        let items: [JSONValue] = [
            .object(["id": .integer(1), "subject": .string("Line\nbreak"), "nested": .object(["b": .integer(2), "a": .integer(1)])]),
            .object(["id": .integer(2), "subject": .string("Second")]),
        ]
        let output = try OutputFormatter.list(ResourcePage(items: items, nextCursor: "next"), kind: .conversation, format: .jsonl)
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)

        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines.last, "")
        XCTAssertEqual(lines[0], #"{"id":1,"nested":{"a":1,"b":2},"subject":"Line\nbreak"}"#)
        XCTAssertEqual(try lines.dropLast().map { try decode(String($0)) }, items)
        XCTAssertFalse(output.contains("next"), "Continuation stays out of stdout data")
    }

    func testIDFormatEmitsOneIDPerLine() throws {
        let page = ResourcePage(items: [.object(["id": .integer(12)]), .object(["id": .integer(345)])], nextPage: 2)
        XCTAssertEqual(try OutputFormatter.list(page, kind: .inbox, format: .id), "12\n345\n")
    }

    func testEmptyLineFormatsProduceNoOutput() throws {
        let empty = ResourcePage(items: [])
        XCTAssertEqual(try OutputFormatter.list(empty, kind: .customer, format: .jsonl), "")
        XCTAssertEqual(try OutputFormatter.list(empty, kind: .customer, format: .id), "")
    }

    func testIDFormatRejectsItemsWithoutID() {
        let page = ResourcePage(items: [.object(["name": .string("No ID")])])
        XCTAssertThrowsError(try OutputFormatter.list(page, kind: .template, format: .id)) { error in
            guard case ScoutError.decoding = error else { return XCTFail("Unexpected error \(error)") }
        }
    }

    // MARK: Tables

    func testConversationTableShowsIDNumberStatusCustomerAndSubject() throws {
        let page = ResourcePage(items: [
            conversation(id: 101, number: 7, status: "active",
                         customer: .object(["first": .string("Jane"), "last": .string("Doe"), "email": .string("jane@example.com")]),
                         subject: "Refund request"),
            conversation(id: 2002, number: 1234, status: "pending", customer: .object(["first": .string("Bob")]), subject: ""),
        ])
        let output = try OutputFormatter.list(page, kind: .conversation, format: .table)
        XCTAssertEqual(output, """
        ID    NUMBER  STATUS   CUSTOMER          SUBJECT
        101   7       active   jane@example.com  Refund request
        2002  1234    pending  Bob

        """)
    }

    func testEmptyTablePrintsHeaderOnly() throws {
        XCTAssertEqual(try OutputFormatter.list(ResourcePage(items: []), kind: .conversation, format: .table),
                       "ID  NUMBER  STATUS  CUSTOMER  SUBJECT\n")
        XCTAssertEqual(try OutputFormatter.list(ResourcePage(items: []), kind: .template, format: .table), "ID  NAME  PREVIEW\n")
    }

    func testCustomerInboxAndTemplateTables() throws {
        let customers = ResourcePage(items: [.object([
            "id": .integer(5), "firstName": .string("Vernon"), "lastName": .string("Bear"),
            "_embedded": .object(["emails": .array([
                .object(["value": .string("bear@acme.com"), "type": .string("work")]),
                .object(["value": .string("v@home.com"), "type": .string("home")]),
            ])]),
        ])])
        XCTAssertEqual(try OutputFormatter.list(customers, kind: .customer, format: .table), """
        ID  NAME         EMAIL
        5   Vernon Bear  bear@acme.com, v@home.com

        """)

        let inboxes = ResourcePage(items: [.object(["id": .integer(1), "name": .string("Support"), "email": .string("help@example.com")])])
        XCTAssertEqual(try OutputFormatter.list(inboxes, kind: .inbox, format: .table), """
        ID  NAME     EMAIL
        1   Support  help@example.com

        """)

        let templates = ResourcePage(items: [.object(["id": .integer(9), "name": .string("Welcome"), "preview": .string("Hi there,\nthanks")])])
        XCTAssertEqual(try OutputFormatter.list(templates, kind: .template, format: .table), """
        ID  NAME     PREVIEW
        9   Welcome  Hi there, thanks

        """)
    }

    func testTableRemovesControlCharactersAndKeepsRowsOnOneLine() throws {
        let hostile = "Bad\u{1B}[31m red\r\nsecond\tline\u{7}\u{202E}txt\u{2028}end\u{9B}"
        let page = ResourcePage(items: [
            conversation(id: 1, number: 2, status: "active\n", customer: .object(["email": .string("x@example.com\u{1B}]0;title\u{7}")]), subject: hostile),
        ])
        let output = try OutputFormatter.list(page, kind: .conversation, format: .table)
        let lines = output.split(separator: "\n")

        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[1], "1   2       active  x@example.com ]0;title  Bad [31m red second line txt end")
        for scalar in output.unicodeScalars where scalar != "\n" {
            XCTAssertNotEqual(scalar.properties.generalCategory, .control, "Control U+\(String(scalar.value, radix: 16))")
            XCTAssertFalse(OutputFormatter.TerminalText.isBidiControl(scalar))
        }
    }

    func testTableAlignsWideUnicodeAndHasNoTrailingSpaces() throws {
        let page = ResourcePage(items: [
            .object(["id": .integer(1), "name": .string("李小龙"), "email": .string("li@example.com")]),
            .object(["id": .integer(22), "name": .string("Zoë 👋"), "email": .string("")]),
            .object(["id": .integer(333), "name": .string("Ann"), "email": .string("ann@example.com")]),
        ])
        let output = try OutputFormatter.list(page, kind: .inbox, format: .table)
        let lines = output.split(separator: "\n").map(String.init)

        XCTAssertEqual(lines.count, 4)
        for line in lines { XCTAssertFalse(line.hasSuffix(" "), "Trailing space in \(line)") }
        let emailColumn = { (line: String, email: String) -> Int in
            OutputFormatter.TerminalText.displayWidth(String(line[..<line.range(of: email)!.lowerBound]))
        }
        XCTAssertEqual(emailColumn(lines[0], "EMAIL"), 13)
        XCTAssertEqual(emailColumn(lines[1], "li@example.com"), 13)
        XCTAssertEqual(emailColumn(lines[3], "ann@example.com"), 13)
        XCTAssertEqual(lines[2], "22   Zoë 👋")
    }

    func testTableTruncatesLongFreeTextColumns() throws {
        let subject = String(repeating: "word ", count: 40)
        let page = ResourcePage(items: [conversation(id: 1, number: 1, status: "active", customer: .null, subject: subject)])
        let row = try OutputFormatter.list(page, kind: .conversation, format: .table).split(separator: "\n")[1]
        let shown = String(row[row.range(of: "word")!.lowerBound...])

        XCTAssertTrue(shown.hasSuffix("…"))
        XCTAssertEqual(OutputFormatter.TerminalText.displayWidth(shown), 80)
    }
}
