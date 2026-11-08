import XCTest
import ArgumentParser
import ScoutKit
@testable import scout

final class CommandTests: XCTestCase {
    func testCommandName() {
        XCTAssertEqual(Scout.configuration.commandName, "scout")
    }

    func testReadOnlyGroupAcceptsReadsAndRejectsWrites() throws {
        for arguments in [["inboxes"], ["list"], ["show", "12"], ["show", "12", "-o", "files"], ["attachments", "12", "-o", "files"],
                          ["search", "number:123"],
                          ["customers", "--email", "a@b.com"], ["customer", "42"], ["templates"],
                          ["template", "10"], ["auth", "status"]] {
            _ = try Scout.parseAsRoot(["ro"] + arguments)
            _ = try Scout.parseAsRoot(arguments)
        }
        for arguments in [["draft", "12", "--body", "Hi"], ["send", "12", "--body", "Hi"], ["send-draft", "12"],
                          ["mark", "spam", "12"], ["auth", "login"]] {
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

    func testAttachmentDownloadsRequireAnOutputDirectory() throws {
        for prefix: [String] in [[], ["ro"]] {
            let all = try XCTUnwrap(Scout.parseAsRoot(prefix + ["attachments", "12", "-o", "files"]) as? Attachments)
            XCTAssertEqual(all.id, 12)
            XCTAssertEqual(all.outputDir, "files")
            XCTAssertNil(all.attachment)
            let one = try XCTUnwrap(Scout.parseAsRoot(prefix + ["attachments", "12", "--output-dir", "~/files", "--attachment", "5"]) as? Attachments)
            XCTAssertEqual(one.outputDir, "~/files")
            XCTAssertEqual(one.attachment, 5)

            let show = try XCTUnwrap(Scout.parseAsRoot(prefix + ["show", "12", "-o", "files"]) as? Show)
            XCTAssertEqual(show.outputDir, "files")
            XCTAssertNil(try XCTUnwrap(Scout.parseAsRoot(prefix + ["show", "12"]) as? Show).outputDir)

            for arguments in [["attachments", "12"], ["attachments", "12", "-o"], ["attachments", "12", "-o", " "],
                              ["attachments", "0", "-o", "files"], ["attachments", "12", "-o", "files", "--attachment", "0"],
                              ["attachments", "-o", "files"], ["show", "12", "-o", ""],
                              ["show", "12", "-o", "files", "--format", "json"]] {
                XCTAssertThrowsError(try Scout.parseAsRoot(prefix + arguments), "\(arguments)")
            }
        }
    }

    func testTemplateReadsAreIdenticalAtRootAndUnderRO() throws {
        for prefix: [String] in [[], ["ro"]] {
            let list = try XCTUnwrap(Scout.parseAsRoot(prefix + ["templates", "--inbox", "7", "--include-chat", "--format", "json"]) as? Templates)
            XCTAssertEqual(list.inbox, 7)
            XCTAssertTrue(list.includeChat)
            XCTAssertEqual(list.output.format, .json)
            let detail = try XCTUnwrap(Scout.parseAsRoot(prefix + ["template", "10", "--inbox", "7"]) as? Template)
            XCTAssertEqual(detail.id, 10)
            XCTAssertEqual(detail.inbox, 7)
            XCTAssertEqual(detail.format, .raw)
        }
    }

    func testTemplateWritesParseOnlyAtRoot() throws {
        for arguments in [
            ["template-create", "--name", "Greeting", "--body", "Hi {%customer.firstName%}"],
            ["template-create", "--name", "Chat", "--chat-text", "Hi"],
            ["template-update", "10", "--name", "Renamed"],
            ["template-update", "10", "--body-file", "-", "--html"],
            ["template-delete", "10"]
        ] {
            _ = try Scout.parseAsRoot(arguments + ["--inbox", "7"])
            XCTAssertThrowsError(try Scout.parseAsRoot(["ro"] + arguments))
        }
        let create = try XCTUnwrap(Scout.parseAsRoot(["template-create", "--name", "Greeting", "--body", "<p>Hi {%customer.firstName%}</p>", "--html"]) as? TemplateCreate)
        XCTAssertEqual(try create.fields.emailText(), "<p>Hi {%customer.firstName%}</p>")
        for arguments in [
            ["template-create", "--body", "Hi"], ["template-create", "--name", "Hi"],
            ["template-create", "--name", " ", "--body", "Hi"],
            ["template-update", "10"], ["template-update", "10", "--html", "--name", "Hi"],
            ["template-update", "10", "--body", "Hi", "--body-file", "body.txt"],
            ["template-update", "10", "--body", " "], ["template-update", "0", "--name", "Hi"],
            ["template-delete", "0"], ["template-delete", "10", "--inbox", "0"]
        ] {
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

    func testDraftRequiresBodyAndCannotSend() throws {
        for options in [["--body", "Hi"], ["--body-file", "-", "--html"], ["--template", "7"]] {
            for selection: [String] in [[], ["--thread", "90"]] {
                let arguments = ["draft", "12"] + options + selection
                let draft = try XCTUnwrap(Scout.parseAsRoot(arguments) as? Draft)
                XCTAssertEqual(draft.thread, selection.isEmpty ? nil : 90)
                XCTAssertThrowsError(try Scout.parseAsRoot(["ro"] + arguments))
            }
        }
        for options in [[], ["--send"], ["--body", "Hi", "--send"], ["--send", "--thread", "90"],
                        ["--body", "Hi", "--body-file", "missing.txt"], ["--body-file", "-", "--template", "1"],
                        ["--body", "Hi", "--template", "1"], ["--template", "1", "--html"],
                        ["--body", "Hi", "--thread", "0"], ["--body", "Hi", "--thread", "-1"],
                        ["--body", "Hi", "--thread", "abc"], ["--thread", "90"],
                        ["--body", "Hi", "--status", "closed"], ["--delete"]] {
            XCTAssertThrowsError(try Scout.parseAsRoot(["draft", "12"] + options), "\(options)")
        }
        XCTAssertThrowsError(try Scout.parseAsRoot(["draft", "0", "--body", "Hi"]))
    }

    func testSendDraftSelectsExistingDraftWithoutBodyInput() throws {
        for selection: [String] in [[], ["--thread", "90"]] {
            let arguments = ["send-draft", "12"] + selection
            let sendDraft = try XCTUnwrap(Scout.parseAsRoot(arguments) as? SendDraft)
            XCTAssertEqual(sendDraft.id, 12)
            XCTAssertEqual(sendDraft.thread, selection.isEmpty ? nil : 90)
            XCTAssertThrowsError(try Scout.parseAsRoot(["ro"] + arguments))
        }
        for options in [["--body", "Hi"], ["--body-file", "-"], ["--template", "1"], ["--html"],
                        ["--thread", "0"], ["--thread", "-1"], ["--thread", "abc"],
                        ["--status", "closed"], ["--send"], ["--delete"]] {
            XCTAssertThrowsError(try Scout.parseAsRoot(["send-draft", "12"] + options), "\(options)")
        }
        XCTAssertThrowsError(try Scout.parseAsRoot(["send-draft"]))
        XCTAssertThrowsError(try Scout.parseAsRoot(["send-draft", "0"]))
        XCTAssertThrowsError(try Scout.parseAsRoot(["send", "12", "--send"]))
        XCTAssertThrowsError(try Scout.parseAsRoot(["send", "12", "--body-file", "-", "--thread", "90"]))
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
