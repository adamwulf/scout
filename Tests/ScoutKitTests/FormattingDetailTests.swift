import Foundation
import XCTest
@testable import ScoutKit

final class FormattingDetailTests: XCTestCase {
    private let templateText = "<p>Hi {%customer.firstName,fallback=there%},</p>\r\n<p>Thanks &amp; regards</p>"

    private var template: JSONValue {
        .object([
            "id": .integer(234567), "name": .string("Visiting us"),
            "text": .string(templateText), "chatText": .string("Hi there,\nchat version"),
        ])
    }

    // MARK: Raw templates

    func testRawTemplateIsExactEmailTextWithOneTrailingNewline() throws {
        let output = try OutputFormatter.detail(template, kind: .template, format: .raw)
        XCTAssertEqual(output, templateText + "\n")
        XCTAssertEqual(String(output.dropLast()), templateText, "Saving and stripping the final newline round-trips")
        XCTAssertFalse(output.contains("chat version"))
        XCTAssertFalse(output.contains("Visiting us"))
    }

    func testRawTemplateDoesNotAddNewlineWhenPresent() throws {
        for text in ["<p>Done</p>\n", "<p>Done</p>\r\n", "<p>Done</p>\n\n"] {
            let value: JSONValue = .object(["id": .integer(1), "text": .string(text)])
            XCTAssertEqual(try OutputFormatter.detail(value, kind: .template, format: .raw), text)
        }
    }

    func testRawRequiresTemplateText() {
        XCTAssertThrowsError(try OutputFormatter.detail(.object(["id": .integer(1)]), kind: .template, format: .raw)) { error in
            guard case ScoutError.decoding = error else { return XCTFail("Unexpected error \(error)") }
        }
        for kind in [ResourceKind.inbox, .conversation, .customer] {
            XCTAssertThrowsError(try OutputFormatter.detail(template, kind: kind, format: .raw)) { error in
                guard case ScoutError.invalidInput = error else { return XCTFail("Unexpected error \(error)") }
            }
        }
    }

    // MARK: JSON

    func testStatusReceiptJSONContract() throws {
        for status in ReplyStatus.allCases {
            let receipt = StatusReceipt(conversationID: 987654, status: status)
            let output = try OutputFormatter.receipt(receipt)
            XCTAssertEqual(output, """
            {
              "conversationID" : 987654,
              "status" : "\(status.rawValue)"
            }

            """)
        }
    }

    func testDetailJSONPreservesAllRawValues() throws {
        let output = try OutputFormatter.detail(template, kind: .template, format: .json)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: Data(output.utf8)), template)
        XCTAssertTrue(output.hasSuffix("}\n"))
    }

    // MARK: Markdown

    func testTemplateMarkdownIsLabeledReadableText() throws {
        XCTAssertEqual(try OutputFormatter.detail(template, kind: .template, format: .markdown), """
        # Visiting us

        - ID: 234567

        Hi {%customer.firstName,fallback=there%},

        Thanks & regards

        """)
    }

    func testInboxMarkdown() throws {
        let inbox: JSONValue = .object([
            "id": .integer(1), "name": .string("Support"), "email": .string("help@example.com"),
            "slug": .string("abc123"), "createdAt": .string("2024-01-01T00:00:00Z"),
        ])
        XCTAssertEqual(try OutputFormatter.detail(inbox, kind: .inbox, format: .markdown), """
        # Support

        - ID: 1
        - Email: help@example.com
        - Slug: abc123
        - Created: 2024-01-01T00:00:00Z

        """)
    }

    func testCustomerMarkdownIncludesContactsAndProperties() throws {
        let customer: JSONValue = .object([
            "id": .integer(100), "firstName": .string("Vernon"), "lastName": .string("Bear"),
            "organization": .string("Acme, Inc"), "jobTitle": .string("CEO"),
            "background": .string("Contact Jane <jane@acme.com> at <b>conference</b>.\nLikes tea &amp; cake."),
            "conversationCount": .integer(10),
            "_embedded": .object([
                "emails": .array([.object(["id": .integer(1), "value": .string("bear@acme.com"), "type": .string("work")])]),
                "phones": .array([.object(["id": .integer(2), "value": .string("123-123"), "type": .string("home")])]),
                "websites": .array([.object(["id": .integer(3), "value": .string("http://home.com")])]),
                "address": .object(["lines": .array([.string("1 Main St")]), "city": .string("Prague"), "country": .string("CZ")]),
                "properties": .array([
                    .object(["type": .string("text"), "slug": .string("car"), "name": .string("Car"), "value": .string("Tesla"), "text": .string("Tesla")]),
                    .object(["type": .string("number"), "slug": .string("seats"), "value": .integer(5)]),
                    .object(["type": .string("text"), "slug": .string("plan"), "name": .string("Plan"), "value": .null]),
                ]),
            ]),
        ])
        XCTAssertEqual(try OutputFormatter.detail(customer, kind: .customer, format: .markdown), """
        # Vernon Bear

        - ID: 100
        - Emails: bear@acme.com (work)
        - Phones: 123-123 (home)
        - Websites: http://home.com
        - Organization: Acme, Inc
        - Job title: CEO
        - Address: 1 Main St, Prague, CZ
        - Conversations: 10

        ## Properties

        - Car: Tesla
        - seats: 5
        - Plan: (none)

        ## Background

        Contact Jane <jane@acme.com> at <b>conference</b>.
        Likes tea &amp; cake.

        """)
    }

    func testMarkdownRemovesTerminalControlsFromFields() throws {
        let inbox: JSONValue = .object(["id": .integer(1), "name": .string("Evil\u{1B}[2J\nName"), "email": .string("a@b.c\u{7}")])
        let output = try OutputFormatter.detail(inbox, kind: .inbox, format: .markdown)
        XCTAssertEqual(output, "# Evil [2J Name\n\n- ID: 1\n- Email: a@b.c\n")
    }
}
