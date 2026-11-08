import Foundation
import XCTest
@testable import ScoutKit

final class ScoutAttachmentTests: XCTestCase {
    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("scout-attachment-tests-\(UUID().uuidString)", isDirectory: true)

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func client(_ replies: [ScriptedHTTPTransport.Reply]) -> (ScoutClient, ScriptedHTTPTransport) {
        let transport = ScriptedHTTPTransport(replies)
        let http = ScoutHTTPClient(configuration: .init(accessToken: "test-token"), transport: transport, tokenStore: InMemoryTokenStore())
        return (ScoutClient(http: http), transport)
    }

    private func attachment(_ id: Int?, _ filename: String, mimeType: String = "image/png", state: String = "valid") -> JSONValue {
        var fields: [String: JSONValue] = ["filename": .string(filename), "mimeType": .string(mimeType), "state": .string(state)]
        if let id { fields["id"] = .integer(id) }
        return .object(fields)
    }

    private func thread(_ id: Int, createdAt: String, _ attachments: [JSONValue]) -> JSONValue {
        .object(["id": .integer(id), "createdAt": .string(createdAt), "_embedded": .object(["attachments": .array(attachments)])])
    }

    private func view(_ threads: [JSONValue]) -> ConversationView {
        ConversationView(conversation: .object(["id": .integer(12)]), threads: threads)
    }

    private func data(_ text: String) -> ScriptedHTTPTransport.Reply {
        .json(200, #"{"data":"\#(Data(text.utf8).base64EncodedString())"}"#)
    }

    private func names(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    func testSavesAttachmentsOldestFirstIntoNewDirectoryAndSkipsViruses() async throws {
        // Threads arrive newest first, as the API lists them.
        let threads = [
            thread(2, createdAt: "2024-01-02T09:00:00Z", [attachment(31, "notes.txt", mimeType: "text/plain")]),
            thread(1, createdAt: "2024-01-01T09:00:00Z", [attachment(30, "photo.png"), attachment(32, "bad.exe", state: "virus")]),
        ]
        let (client, transport) = client([data("first"), data("second")])
        let directory = root.appendingPathComponent("nested/files")

        let download = try await client.downloadAttachments(in: view(threads), to: directory.path)

        XCTAssertEqual(download.saved, [
            .init(attachmentID: 30, filename: "photo.png", path: directory.path + "/30-photo.png", byteCount: 5),
            .init(attachmentID: 31, filename: "notes.txt", path: directory.path + "/31-notes.txt", byteCount: 6),
        ])
        XCTAssertEqual(download.skipped, [.init(attachmentID: 32, filename: "bad.exe", reason: "Help Scout flagged it as a virus.")])
        XCTAssertEqual(download.failed, [])
        XCTAssertEqual(download.paths, [30: directory.path + "/30-photo.png", 31: directory.path + "/31-notes.txt"])
        XCTAssertEqual(try String(contentsOfFile: directory.path + "/30-photo.png", encoding: .utf8), "first")
        XCTAssertEqual(try String(contentsOfFile: directory.path + "/31-notes.txt", encoding: .utf8), "second")
        XCTAssertEqual(try names(in: directory), ["30-photo.png", "31-notes.txt"])
        let requests = await transport.requests
        XCTAssertEqual(requests.map(\.method), ["GET", "GET"])
        XCTAssertEqual(requests.map(\.url.path), ["/v2/conversations/12/attachments/30/data", "/v2/conversations/12/attachments/31/data"])
    }

    func testFileNamesStayInsideTheOutputDirectory() async throws {
        let hostile = ["../escape.png", "....//x.png", "/etc/passwd", #"a\b:c<d>.png"#, "\u{1B}[2J\u{202E}evil.png", "", "  spaced   name.png  "]
        let attachments = hostile.enumerated().map { attachment($0.offset + 1, $0.element) }
        let (client, _) = client(hostile.map { _ in data("x") })
        let directory = root.appendingPathComponent("files")

        let download = try await client.downloadAttachments(in: view([thread(1, createdAt: "2024-01-01T09:00:00Z", attachments)]), to: directory.path)

        XCTAssertEqual(download.failed, [])
        XCTAssertEqual(try names(in: directory), [
            "1-.._escape.png", "2-....__x.png", "3-_etc_passwd", "4-a_b_c_d_.png", "5-[2Jevil.png", "6-attachment", "7-spaced name.png",
        ].sorted())
        XCTAssertEqual(try names(in: root), ["files"], "Nothing is written outside the output directory")
        XCTAssertTrue(download.saved.allSatisfy { URL(fileURLWithPath: $0.path).deletingLastPathComponent().path == directory.path })
    }

    func testLongNamesFitTheFileNameLimitAndKeepShortExtensions() {
        let long = ScoutClient.attachmentFileName(id: 123, filename: String(repeating: "é", count: 300) + ".png")
        XCTAssertLessThanOrEqual(long.utf8.count, 255)
        XCTAssertTrue(long.hasPrefix("123-é"))
        XCTAssertTrue(long.hasSuffix("é.png"))

        let longExtension = ScoutClient.attachmentFileName(id: 7, filename: "a." + String(repeating: "x", count: 300))
        XCTAssertEqual(longExtension.utf8.count, 255)
        XCTAssertTrue(longExtension.hasPrefix("7-a.x"))
        XCTAssertEqual(ScoutClient.attachmentFileName(id: 5, filename: "photo.png"), "5-photo.png")
    }

    func testFailedAttachmentDoesNotStopOthersAndIsNotReplayed() async throws {
        let attachments = [attachment(1, "missing.png"), attachment(2, "empty.png"), attachment(3, "ok.png"), attachment(nil, "anonymous.png")]
        let (client, transport) = client([.json(404, #"{"message":"Not found"}"#), .json(200, #"{"other":true}"#), data("ok")])
        let directory = root.appendingPathComponent("files")

        let download = try await client.downloadAttachments(in: view([thread(1, createdAt: "2024-01-01T09:00:00Z", attachments)]), to: directory.path)

        XCTAssertEqual(download.failed.map(\.attachmentID), [1, 2])
        XCTAssertTrue(download.failed[0].reason.contains("HTTP 404"))
        XCTAssertEqual(download.failed[1].reason, "Help Scout returned no valid base64 data for attachment 2.")
        XCTAssertEqual(download.saved.map(\.attachmentID), [3])
        XCTAssertEqual(download.skipped, [.init(attachmentID: nil, filename: "anonymous.png", reason: "Help Scout listed it without an attachment ID.")])
        XCTAssertEqual(try names(in: directory), ["3-ok.png"])
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 3)
    }

    func testRepeatedDownloadReplacesTheSameFile() async throws {
        let threads = [thread(1, createdAt: "2024-01-01T09:00:00Z", [attachment(30, "photo.png")])]
        let (client, _) = client([data("old"), data("new")])
        let directory = root.appendingPathComponent("files")

        _ = try await client.downloadAttachments(in: view(threads), to: directory.path)
        let second = try await client.downloadAttachments(in: view(threads), to: directory.path + "/")

        XCTAssertEqual(second.saved.map(\.path), [directory.path + "/30-photo.png"])
        XCTAssertEqual(try names(in: directory), ["30-photo.png"])
        XCTAssertEqual(try String(contentsOfFile: directory.path + "/30-photo.png", encoding: .utf8), "new")
    }

    func testSingleAttachmentSelection() async throws {
        let threads = [thread(1, createdAt: "2024-01-01T09:00:00Z", [
            attachment(30, "photo.png"), attachment(31, "notes.txt"), attachment(32, "bad.exe", state: "virus"),
        ])]
        let directory = root.appendingPathComponent("files")

        let (single, singleTransport) = client([data("notes")])
        let download = try await single.downloadAttachments(in: view(threads), to: directory.path, only: 31)
        XCTAssertEqual(download.saved.map(\.attachmentID), [31])
        XCTAssertEqual(download.skipped, [])
        let requests = await singleTransport.requests
        XCTAssertEqual(requests.map(\.url.path), ["/v2/conversations/12/attachments/31/data"])

        for (id, message) in [(99, "Attachment 99 is not in conversation 12."), (32, "Help Scout flagged attachment 32 as a virus."),
                              (0, "Attachment ID must be a positive")] {
            let (rejecting, rejectingTransport) = client([])
            do {
                _ = try await rejecting.downloadAttachments(in: view(threads), to: directory.path, only: id)
                XCTFail("Accepted attachment \(id)")
            } catch ScoutError.invalidInput(let text) {
                XCTAssertTrue(text.hasPrefix(message), text)
            }
            let rejected = await rejectingTransport.requests
            XCTAssertEqual(rejected.count, 0)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path + "/32-bad.exe"))
    }

    func testConversationWithoutAttachmentsWritesNothing() async throws {
        let (client, transport) = client([])
        let directory = root.appendingPathComponent("unused")

        let download = try await client.downloadAttachments(in: view([thread(1, createdAt: "2024-01-01T09:00:00Z", [])]), to: directory.path)

        XCTAssertTrue(download.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 0)

        do {
            _ = try await client.downloadAttachments(in: view([]), to: "  ")
            XCTFail("Accepted an empty directory")
        } catch ScoutError.invalidInput {}
    }

    func testOutputDirectoryThatIsAFileFailsBeforeAnyRequest() async throws {
        let file = root.appendingPathComponent("taken")
        try Data("x".utf8).write(to: file)
        let (client, transport) = client([data("x")])

        do {
            _ = try await client.downloadAttachments(in: view([thread(1, createdAt: "2024-01-01T09:00:00Z", [attachment(30, "photo.png")])]), to: file.path)
            XCTFail("Used a file as the output directory")
        } catch ScoutError.invalidInput(let text) {
            XCTAssertTrue(text.hasPrefix("Could not create the output directory"), text)
        }
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 0)
    }

    func testDownloadReportLines() {
        var download = AttachmentDownload()
        download.saved = [.init(attachmentID: 30, filename: "photo.png", path: "files/30-photo.png", byteCount: 5)]
        download.skipped = [.init(attachmentID: 32, filename: "bad.exe", reason: "Help Scout flagged it as a virus.")]
        download.failed = [.init(attachmentID: 33, filename: "x\u{1B}[2J.png", reason: "HTTP 404: Not found"),
                           .init(attachmentID: nil, filename: "", reason: "Help Scout listed it without an attachment ID.")]

        XCTAssertEqual(OutputFormatter.attachmentPaths(download), "files/30-photo.png\n")
        XCTAssertEqual(OutputFormatter.attachmentProblems(download), [
            "Skipped attachment 32 (bad.exe): Help Scout flagged it as a virus.",
            "Failed to save attachment 33 (x [2J.png): HTTP 404: Not found",
            "Failed to save attachment: Help Scout listed it without an attachment ID.",
        ])
    }
}
