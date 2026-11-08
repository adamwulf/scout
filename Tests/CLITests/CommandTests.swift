import XCTest
import ArgumentParser
import ScoutKit
@testable import scout

final class CommandTests: XCTestCase {
    func testCommandName() {
        XCTAssertEqual(Scout.configuration.commandName, "scout")
    }

    func testReadOnlyGroupAcceptsReadsAndRejectsWrites() throws {
        for arguments in [["inboxes"], ["list"], ["show", "12"], ["search", "number:123"],
                          ["customers", "--email", "a@b.com"], ["customer", "42"], ["templates"],
                          ["template", "10"], ["auth", "status"]] {
            _ = try Scout.parseAsRoot(["ro"] + arguments)
            _ = try Scout.parseAsRoot(arguments)
        }
        for arguments in [["draft", "12", "--body", "Hi"], ["send", "12", "--body", "Hi"], ["mark", "spam", "12"], ["auth", "login"]] {
            XCTAssertThrowsError(try Scout.parseAsRoot(["ro"] + arguments))
            _ = try Scout.parseAsRoot(arguments)
        }
    }

    func testMarkAcceptsWritableStatusesAndRequiresPositiveConversationID() throws {
        for status in ReplyStatus.allCases {
            let mark = try XCTUnwrap(Scout.parseAsRoot(["mark", status.rawValue, "12", "--env-file", "settings.fixture"]) as? Mark)
            XCTAssertEqual(mark.status, status)
            XCTAssertEqual(mark.id, 12)
            XCTAssertEqual(mark.connection.envFile, "settings.fixture")
            XCTAssertThrowsError(try Scout.parseAsRoot(["ro", "mark", status.rawValue, "12"]))
        }
        for arguments in [["mark"], ["mark", "spam"], ["mark", "spam", "0"], ["mark", "spam", "-1"],
                          ["mark", "spam", "abc"], ["mark", "all", "12"], ["mark", "archive", "12"],
                          ["mark", "12", "spam"], ["mark", "spam", "12", "--body", "Hi"]] {
            XCTAssertThrowsError(try Scout.parseAsRoot(arguments), "\(arguments)")
        }
    }

    func testReplyOptionsValidateBeforeRunning() throws {
        XCTAssertThrowsError(try Scout.parseAsRoot(["send", "12"]))
        XCTAssertThrowsError(try Scout.parseAsRoot(["draft", "12", "--body", "Hi", "--template", "1"]))
        XCTAssertThrowsError(try Scout.parseAsRoot(["send", "12", "--template", "1", "--html"]))
        XCTAssertThrowsError(try Scout.parseAsRoot(["send", "0", "--body", "Hi"]))
        XCTAssertThrowsError(try Scout.parseAsRoot(["draft", "12", "--body", "Hi", "--status", "closed"]))
        let send = try XCTUnwrap(Scout.parseAsRoot(["send", "12", "--body-file", "-", "--status", "closed"]) as? Send)
        XCTAssertEqual(send.status, .closed)
    }

    func testMarkdownFormatUsesMD() throws {
        for prefix: [String] in [[], ["ro"]] {
            let show = try XCTUnwrap(Scout.parseAsRoot(prefix + ["show", "12", "--format", "md"]) as? Show)
            XCTAssertEqual(show.output.format, .markdown)
            let customer = try XCTUnwrap(Scout.parseAsRoot(prefix + ["customer", "42", "--format", "md"]) as? Customer)
            XCTAssertEqual(customer.output.format, .markdown)
            let template = try XCTUnwrap(Scout.parseAsRoot(prefix + ["template", "10", "--format", "md"]) as? Template)
            XCTAssertEqual(template.format, .markdown)

            for command in ["show", "customer", "template"] {
                XCTAssertThrowsError(try Scout.parseAsRoot(prefix + [command, "12", "--format", "markdown"]))
            }
        }
    }

    func testSearchAndCustomerValidationAndFormats() throws {
        XCTAssertThrowsError(try Scout.parseAsRoot(["search", "refund"]))
        XCTAssertThrowsError(try Scout.parseAsRoot(["customers"]))
        XCTAssertThrowsError(try Scout.parseAsRoot(["customers", "--email", "a@b.com", "--query", "firstName:Jane"]))
        XCTAssertThrowsError(try Scout.parseAsRoot(["show", "12", "--format", "raw"]))
        for query in ["number:123", "contactId:42", #"email:"a+b@my-company.com""#] {
            _ = try Scout.parseAsRoot(["search", query, "--format", "jsonl", "--cursor", "abc="])
        }
        let template = try XCTUnwrap(Scout.parseAsRoot(["template", "10"]) as? Template)
        XCTAssertEqual(template.format, .raw)
    }
}
