import Foundation
import XCTest
@testable import ScoutKit

final class FormattingConversationTests: XCTestCase {
    private let jane: JSONValue = .object([
        "id": .integer(7), "type": .string("customer"), "first": .string("Jane"), "last": .string("Doe"), "email": .string("jane@example.com"),
    ])
    private let adam: JSONValue = .object([
        "id": .integer(8), "type": .string("user"), "first": .string("Adam"), "last": .string("W"), "email": .string("adam@example.com"),
    ])

    private var conversation: JSONValue {
        .object([
            "id": .integer(555), "number": .integer(42), "subject": .string("Order help"), "status": .string("active"),
            "state": .string("published"), "type": .string("email"), "mailboxId": .integer(9),
            "primaryCustomer": jane, "assignee": adam,
            "tags": .array([.object(["id": .integer(1), "tag": .string("billing")])]),
            "createdAt": .string("2024-01-01T09:00:00Z"), "userUpdatedAt": .string("2024-01-02T10:00:00Z"),
        ])
    }

    private func thread(_ id: Int, type: String, state: String, status: String? = nil, author: JSONValue,
                        createdAt: String?, body: String? = nil, extra: [String: JSONValue] = [:]) -> JSONValue {
        var fields: [String: JSONValue] = ["id": .integer(id), "type": .string(type), "state": .string(state), "createdBy": author]
        if let status { fields["status"] = .string(status) }
        if let createdAt { fields["createdAt"] = .string(createdAt) }
        if let body { fields["body"] = .string(body) }
        return .object(fields.merging(extra) { $1 })
    }

    /// Returned newest first, as the API lists threads, with one undated thread.
    private var threads: [JSONValue] {
        [
            thread(5, type: "note", state: "published", author: adam, createdAt: nil, body: "Internal only"),
            thread(4, type: "message", state: "draft", status: "active", author: adam, createdAt: "2024-01-02T10:00:00Z",
                   body: "<p>Draft &amp; pending</p>", extra: ["to": .array([.string("jane@example.com")])]),
            thread(3, type: "lineitem", state: "published", author: adam, createdAt: "2024-01-01T12:00:00Z",
                   extra: ["action": .object(["type": .string("assigned"), "text": .string("Assigned to Adam W")])]),
            thread(2, type: "message", state: "published", status: "closed", author: adam, createdAt: "2024-01-01T11:00:00.500Z",
                   body: #"Thanks!<br>See <a href="https://example.com/help">our guide</a>."#,
                   extra: ["to": .array([.string("jane@example.com")])]),
            thread(1, type: "customer", state: "published", status: "active", author: jane, createdAt: "2024-01-01T09:00:00Z",
                   body: "<div>Hi,</div><div>I need help.</div>"),
        ]
    }

    func testJSONContainsConversationAndFullUnmodifiedThreads() throws {
        let output = try OutputFormatter.conversation(conversation, threads: threads, format: .json)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: Data(output.utf8))
        XCTAssertEqual(decoded, .object(["conversation": conversation, "threads": .array(threads)]))
        XCTAssertTrue(output.contains("<p>Draft &amp; pending</p>"), "Original HTML is kept")
    }

    func testMarkdownListsThreadsOldestFirstWithLabels() throws {
        XCTAssertEqual(try OutputFormatter.conversation(conversation, threads: threads, format: .markdown), """
        # Order help

        - ID: 555
        - Number: 42
        - Status: active
        - State: published
        - Type: email
        - Inbox ID: 9
        - Customer: Jane Doe <jane@example.com>
        - Assignee: Adam W <adam@example.com>
        - Tags: billing
        - Created: 2024-01-01T09:00:00Z
        - Updated: 2024-01-02T10:00:00Z

        ## Threads (5, oldest first)

        ### 1. Customer message

        - Thread ID: 1
        - Author: Jane Doe <jane@example.com> (customer)
        - Type: customer
        - State: published
        - Status: active
        - Time: 2024-01-01T09:00:00Z

        Hi,
        I need help.

        ### 2. Reply (sent)

        - Thread ID: 2
        - Author: Adam W <adam@example.com> (user)
        - Type: message
        - State: published
        - Status: closed
        - Time: 2024-01-01T11:00:00.500Z
        - To: jane@example.com

        Thanks!
        See [our guide](https://example.com/help).

        ### 3. Activity

        - Thread ID: 3
        - Author: Adam W <adam@example.com> (user)
        - Type: lineitem
        - State: published
        - Time: 2024-01-01T12:00:00Z
        - Action: Assigned to Adam W

        ### 4. DRAFT reply (not sent)

        - Thread ID: 4
        - Author: Adam W <adam@example.com> (user)
        - Type: message
        - State: draft
        - Status: active
        - Time: 2024-01-02T10:00:00Z
        - To: jane@example.com

        Draft & pending

        ### 5. Note

        - Thread ID: 5
        - Author: Adam W <adam@example.com> (user)
        - Type: note
        - State: published

        Internal only

        """)
    }

    func testDraftAndSentRepliesAreNeverLabeledAlike() {
        let titles = ["draft", "published", "review", "hidden", "bounced"].map { state in
            OutputFormatter.Markdown.threadTitle(thread(1, type: "message", state: state, author: adam, createdAt: nil))
        }
        XCTAssertEqual(titles, [
            "DRAFT reply (not sent)", "Reply (sent)", "Reply awaiting review (not sent)", "Reply (hidden)", "Reply (bounced)",
        ])
        XCTAssertEqual(OutputFormatter.Markdown.threadTitle(thread(1, type: "note", state: "draft", author: adam, createdAt: nil)),
                       "DRAFT note (not sent)")
        XCTAssertEqual(OutputFormatter.Markdown.threadTitle(thread(1, type: "newkind", state: "published", author: adam, createdAt: nil)),
                       "Thread (newkind)")
    }

    func testLineItemBodiesAreOptional() throws {
        let lineItems = [
            thread(1, type: "lineitem", state: "published", author: adam, createdAt: "2024-01-01T09:00:00Z",
                   body: "<p>Merged from <b>#41</b></p>", extra: ["action": .object(["text": .string("Merged")])]),
            thread(2, type: "lineitem", state: "published", author: .null, createdAt: "2024-01-01T10:00:00Z",
                   extra: ["action": .object(["text": .string("Status changed to Closed")])]),
            thread(3, type: "lineitem", state: "published", author: .null, createdAt: "2024-01-01T11:00:00Z"),
        ]
        let output = try OutputFormatter.conversation(conversation, threads: lineItems, format: .markdown)
        let sections = output.components(separatedBy: "\n### ").dropFirst()

        XCTAssertEqual(sections.count, 3)
        XCTAssertTrue(sections[1].hasSuffix("- Action: Merged\n\nMerged from #41\n"))
        XCTAssertTrue(sections[2].hasSuffix("- Author: Unknown\n- Type: lineitem\n- State: published\n- Time: 2024-01-01T10:00:00Z\n- Action: Status changed to Closed\n"))
        XCTAssertTrue(sections[3].hasSuffix("- Time: 2024-01-01T11:00:00Z\n\n(no body)\n"))
    }

    func testMarkdownShowsAttachmentsAndScheduledTime() throws {
        let scheduled = thread(1, type: "message", state: "draft", author: adam, createdAt: "2024-01-01T09:00:00Z", body: "Later", extra: [
            "scheduled": .object(["scheduledFor": .string("2024-01-03T09:00:00Z")]),
            "cc": .array([.string("boss@example.com")]),
            "_embedded": .object(["attachments": .array([
                .object(["id": .integer(11), "filename": .string("invoice.pdf"), "mimeType": .string("application/pdf"), "state": .string("valid")]),
                .object(["id": .integer(12), "filename": .string("bad.exe"), "state": .string("virus")]),
                .object(["filename": .string("legacy.txt")]),
            ])]),
        ])
        let output = try OutputFormatter.conversation(conversation, threads: [scheduled], format: .markdown)
        XCTAssertTrue(output.contains("""
        ### 1. DRAFT reply (not sent)

        - Thread ID: 1
        - Author: Adam W <adam@example.com> (user)
        - Type: message
        - State: draft
        - Time: 2024-01-01T09:00:00Z
        - Cc: boss@example.com
        - Scheduled for: 2024-01-03T09:00:00Z
        - Attachments: invoice.pdf (ID 11, application/pdf), bad.exe (ID 12, virus detected), legacy.txt

        Later

        """))
    }

    func testMarkdownLinksDownloadedAttachmentsAndEmbedsImages() throws {
        let attachments: [JSONValue] = [
            .object(["id": .integer(21), "filename": .string("photo.png"), "mimeType": .string("image/png")]),
            .object(["id": .integer(22), "filename": .string("Screen Shot (1).png"), "mimeType": .string("IMAGE/PNG")]),
            .object(["id": .integer(23), "filename": .string("invoice[final].pdf"), "mimeType": .string("application/pdf")]),
            .object(["id": .integer(24), "filename": .string("not-downloaded.png"), "mimeType": .string("image/png")]),
            .object(["id": .integer(25), "filename": .string(""), "mimeType": .string("image/jpeg")]),
        ]
        let withFiles = thread(1, type: "customer", state: "published", author: jane, createdAt: "2024-01-01T09:00:00Z",
                               body: "See attached", extra: ["_embedded": .object(["attachments": .array(attachments)])])
        let paths = [21: "files/21-photo.png", 22: "files/22-Screen Shot (1).png", 23: #"C:\dir/23-invoice[final].pdf"#,
                     25: "files/25-attachment", 99: "files/99-other.png"]

        let output = try OutputFormatter.conversation(conversation, threads: [withFiles], format: .markdown, attachmentPaths: paths)

        XCTAssertTrue(output.hasSuffix("""
        - Attachments: photo.png (ID 21, image/png), Screen Shot (1).png (ID 22, IMAGE/PNG), invoice[final].pdf (ID 23, application/pdf), not-downloaded.png (ID 24, image/png), (ID 25, image/jpeg)

        See attached

        ![photo.png](files/21-photo.png)

        ![Screen Shot (1).png](<files/22-Screen Shot (1).png>)

        [invoice\\[final\\].pdf](C:\\\\dir/23-invoice[final].pdf)

        ![attachment](files/25-attachment)

        """), output)
        XCTAssertFalse(output.contains("not-downloaded.png]("))

        let plain = try OutputFormatter.conversation(conversation, threads: [withFiles], format: .markdown)
        XCTAssertTrue(plain.hasSuffix("\n\nSee attached\n"))
        let json = try OutputFormatter.conversation(conversation, threads: [withFiles], format: .json, attachmentPaths: paths)
        XCTAssertFalse(json.contains("files/21-photo.png"))
    }

    func testEmptyThreadsAndConversationDetail() throws {
        let output = try OutputFormatter.conversation(conversation, threads: [], format: .markdown)
        XCTAssertTrue(output.hasSuffix("## Threads\n\nNo threads.\n"))

        let detail = try OutputFormatter.detail(conversation, kind: .conversation, format: .markdown)
        XCTAssertTrue(detail.hasPrefix("# Order help\n\n- ID: 555\n"))
        XCTAssertFalse(detail.contains("Threads"))

        let json = try OutputFormatter.conversation(conversation, threads: [], format: .json)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))["threads"], .array([]))
    }

    func testRawFormatIsRejectedForConversations() {
        XCTAssertThrowsError(try OutputFormatter.conversation(conversation, threads: threads, format: .raw)) { error in
            guard case ScoutError.invalidInput = error else { return XCTFail("Unexpected error \(error)") }
        }
    }

    func testMarkdownStripsTerminalControlsFromThreadBodies() throws {
        let hostile = thread(1, type: "customer", state: "published", author: jane, createdAt: "2024-01-01T09:00:00Z",
                             body: "Plain\u{1B}[2J text\u{7}\nsecond \u{202E}line")
        let output = try OutputFormatter.conversation(conversation, threads: [hostile], format: .markdown)

        XCTAssertTrue(output.hasSuffix("\n\nPlain[2J text\nsecond line\n"))
        for scalar in output.unicodeScalars where scalar != "\n" {
            XCTAssertNotEqual(scalar.properties.generalCategory, .control)
        }
    }

    func testBodyTextCannotPoseAsThreadHeading() throws {
        let spoof = thread(1, type: "customer", state: "published", author: jane, createdAt: "2024-01-01T09:00:00Z",
                           body: "Hi\n### 2. Reply (sent)\n  # Big\nC# is fine")
        let output = try OutputFormatter.conversation(conversation, threads: [spoof], format: .markdown)

        XCTAssertTrue(output.hasSuffix("\n\nHi\n\\### 2. Reply (sent)\n  \\# Big\nC# is fine\n"))
        XCTAssertEqual(output.components(separatedBy: "\n### ").count, 2)
    }

    func testSortIsDeterministicForTiesAndUndatedThreads() {
        let sorted = OutputFormatter.Markdown.sortedOldestFirst([
            thread(9, type: "note", state: "published", author: adam, createdAt: nil),
            thread(3, type: "note", state: "published", author: adam, createdAt: "2024-01-01T09:00:00Z"),
            thread(2, type: "note", state: "published", author: adam, createdAt: "2024-01-01T09:00:00Z"),
            thread(1, type: "note", state: "published", author: adam, createdAt: "2024-01-02T09:00:00Z"),
            thread(4, type: "note", state: "published", author: adam, createdAt: "not a date"),
        ])
        XCTAssertEqual(sorted.compactMap { $0["id"].int }, [2, 3, 1, 4, 9])
    }
}
