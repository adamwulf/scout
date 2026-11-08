import Foundation
import XCTest
@testable import ScoutKit

final class FormattingShellTests: XCTestCase {
    private let trickyValues = [
        "plain", "", "it's", "'", "''", "subject:refund AND status:active", #"email:"jane+test@my-company.com""#,
        "$HOME", "`date`", "$(echo hi)", "a\\b", "*", "~", "=cmd", "!history", "tab\there", "line\nbreak", "Zoë 李", "--status",
        "abc+/_-.,:@%9", "%1", "eyJwYWdlIjoyfQ==",
    ]

    func testShellQuoteLeavesSafeArgumentsBare() {
        XCTAssertEqual(OutputFormatter.shellQuote("scout"), "scout")
        XCTAssertEqual(OutputFormatter.shellQuote("--inbox"), "--inbox")
        XCTAssertEqual(OutputFormatter.shellQuote("abc+/_-.,:@%9"), "abc+/_-.,:@%9")
    }

    func testShellQuoteSingleQuotesEverythingElse() {
        XCTAssertEqual(OutputFormatter.shellQuote(""), "''")
        XCTAssertEqual(OutputFormatter.shellQuote("it's"), #"'it'\''s'"#)
        XCTAssertEqual(OutputFormatter.shellQuote("'"), #"''\'''"#)
        XCTAssertEqual(OutputFormatter.shellQuote("a b"), "'a b'")
        XCTAssertEqual(OutputFormatter.shellQuote("$HOME"), "'$HOME'")
        XCTAssertEqual(OutputFormatter.shellQuote("=cmd"), "'=cmd'")
        XCTAssertEqual(OutputFormatter.shellQuote("~"), "'~'")
        XCTAssertEqual(OutputFormatter.shellQuote("Zoë"), "'Zoë'")
    }

    func testQuotedArgumentsRoundTripThroughShells() throws {
        for shell in ["/bin/sh", "/bin/zsh"] {
            guard FileManager.default.isExecutableFile(atPath: shell) else { continue }
            let script = "printf '%s\\0' " + trickyValues.map(OutputFormatter.shellQuote).joined(separator: " ")
            XCTAssertEqual(try run(shell, script), trickyValues, shell)
        }
    }

    func testContinuationAppendsCursorAndPreservesFilters() throws {
        let command = ["scout", "search", "subject:'refund' AND status:active", "--format", "jsonl"]
        let page = ResourcePage(items: [], nextCursor: "eyJwYWdlIjoyfQ==")
        let hint = try XCTUnwrap(OutputFormatter.continuation(command: command, page: page))

        XCTAssertEqual(hint, #"scout search 'subject:'\''refund'\'' AND status:active' --format jsonl --cursor 'eyJwYWdlIjoyfQ=='"#)
        XCTAssertFalse(hint.contains("\n"))
        let arguments = try run("/bin/sh", "printf '%s\\0' " + hint)
        XCTAssertEqual(arguments, command + ["--cursor", "eyJwYWdlIjoyfQ=="])
    }

    func testContinuationAppendsPageNumber() {
        let page = ResourcePage(items: [.object(["id": .integer(1)])], nextPage: 3)
        XCTAssertEqual(OutputFormatter.continuation(command: ["scout", "ro", "inboxes"], page: page), "scout ro inboxes --page 3")
    }

    func testContinuationPrefersCursorAndOmitsLastPage() {
        XCTAssertEqual(OutputFormatter.continuation(command: ["scout", "list"], page: ResourcePage(items: [], nextCursor: "c1", nextPage: 2)),
                       "scout list --cursor c1")
        XCTAssertNil(OutputFormatter.continuation(command: ["scout", "list"], page: ResourcePage(items: [.object(["id": .integer(1)])])))
        XCTAssertNil(OutputFormatter.continuation(command: ["scout", "list"], page: ResourcePage(items: [], nextCursor: "")))
    }

    /// Runs `script` in `shell` and splits its NUL-terminated output.
    private func run(_ shell: String, _ script: String) throws -> [String] {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-c", script]
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": "/nonexistent", "LC_ALL": "en_US.UTF-8"]
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return String(decoding: data, as: UTF8.self).split(separator: "\0", omittingEmptySubsequences: false).dropLast().map(String.init)
    }
}
