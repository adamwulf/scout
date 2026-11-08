import CryptoKit
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

    private func thread(_ id: Int, createdAt: String, _ attachments: [JSONValue], body: String? = nil) -> JSONValue {
        var fields: [String: JSONValue] = [
            "id": .integer(id), "createdAt": .string(createdAt), "_embedded": .object(["attachments": .array(attachments)]),
        ]
        if let body { fields["body"] = .string(body) }
        return .object(fields)
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
            .init(source: .attachment(30), filename: "photo.png", path: directory.path + "/30-photo.png", byteCount: 5),
            .init(source: .attachment(31), filename: "notes.txt", path: directory.path + "/31-notes.txt", byteCount: 6),
        ])
        XCTAssertEqual(download.skipped, [.init(source: .attachment(32), filename: "bad.exe", reason: "Help Scout flagged it as a virus.")])
        XCTAssertEqual(download.failed, [])
        XCTAssertEqual(download.attachmentPaths, [30: directory.path + "/30-photo.png", 31: directory.path + "/31-notes.txt"])
        XCTAssertEqual(download.inlineImagePaths, [:])
        XCTAssertEqual(try String(contentsOfFile: directory.path + "/30-photo.png", encoding: .utf8), "first")
        XCTAssertEqual(try String(contentsOfFile: directory.path + "/31-notes.txt", encoding: .utf8), "second")
        XCTAssertEqual(try names(in: directory), ["30-photo.png", "31-notes.txt"])
        let requests = await transport.requests
        XCTAssertEqual(requests.map(\.method), ["GET", "GET"])
        XCTAssertEqual(requests.map(\.url.path), ["/v2/conversations/12/attachments/30/data", "/v2/conversations/12/attachments/31/data"])
    }

    func testFileNamesStayInsideTheOutputDirectory() async throws {
        let hostile = ["../escape.png", "....//x.png", "/etc/passwd", #"a\b:c<d>.png"#, "\u{1B}[2J\u{202E}evil.png", "", "  spaced   name.png  ",
                       "Invoice #1234?.png", "100% done.png"]
        let attachments = hostile.enumerated().map { attachment($0.offset + 1, $0.element) }
        let (client, _) = client(hostile.map { _ in data("x") })
        let directory = root.appendingPathComponent("files")

        let download = try await client.downloadAttachments(in: view([thread(1, createdAt: "2024-01-01T09:00:00Z", attachments)]), to: directory.path)

        XCTAssertEqual(download.failed, [])
        XCTAssertEqual(try names(in: directory), [
            "1-.._escape.png", "2-....__x.png", "3-_etc_passwd", "4-a_b_c_d_.png", "5-[2Jevil.png", "6-attachment", "7-spaced name.png",
            "8-Invoice _1234_.png", "9-100_ done.png",
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

        XCTAssertEqual(download.failed.map(\.source), [.attachment(1), .attachment(2)])
        XCTAssertTrue(download.failed[0].reason.contains("HTTP 404"))
        XCTAssertEqual(download.failed[1].reason, "Help Scout returned no valid base64 data for attachment 2.")
        XCTAssertEqual(download.saved.map(\.source), [.attachment(3)])
        XCTAssertEqual(download.skipped, [.init(source: .attachment(nil), filename: "anonymous.png", reason: "Help Scout listed it without an attachment ID.")])
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

    func testSingleAttachmentSelectionFetchesNoInlineImages() async throws {
        let threads = [thread(1, createdAt: "2024-01-01T09:00:00Z", [
            attachment(30, "photo.png"), attachment(31, "notes.txt"), attachment(32, "bad.exe", state: "virus"),
        ], body: #"<img src="\#(InlineImageTests.appleMailImage)">"#)]
        let directory = root.appendingPathComponent("files")

        let (single, singleTransport) = client([data("notes"), .response(HTTPResponse(statusCode: 200, body: Data("png".utf8)))])
        let download = try await single.downloadAttachments(in: view(threads), to: directory.path, only: 31)
        XCTAssertEqual(download.saved.map(\.source), [.attachment(31)])
        XCTAssertEqual(download.skipped, [])
        XCTAssertEqual(try names(in: directory), ["31-notes.txt"])
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
        download.saved = [.init(source: .attachment(30), filename: "photo.png", path: "files/30-photo.png", byteCount: 5),
                          .init(source: .inlineImage(InlineImageTests.canaryImage), filename: "shot.jpeg", path: "files/inline-abc-shot.jpeg", byteCount: 4)]
        download.skipped = [.init(source: .attachment(32), filename: "bad.exe", reason: "Help Scout flagged it as a virus.")]
        download.failed = [.init(source: .attachment(33), filename: "x\u{1B}[2J.png", reason: "HTTP 404: Not found"),
                           .init(source: .attachment(nil), filename: "", reason: "Help Scout listed it without an attachment ID."),
                           .init(source: .inlineImage(InlineImageTests.appleMailImage), filename: "CleanShot.png",
                                 reason: "HTTP 404: Help Scout's image CDN did not return the image.")]

        XCTAssertEqual(OutputFormatter.attachmentPaths(download), "files/30-photo.png\nfiles/inline-abc-shot.jpeg\n")
        XCTAssertEqual(download.attachmentPaths, [30: "files/30-photo.png"])
        XCTAssertEqual(download.inlineImagePaths, [InlineImageTests.canaryImage: "files/inline-abc-shot.jpeg"])
        XCTAssertEqual(OutputFormatter.attachmentProblems(download), [
            "Skipped attachment 32 (bad.exe): Help Scout flagged it as a virus.",
            "Failed to save attachment 33 (x [2J.png): HTTP 404: Not found",
            "Failed to save attachment: Help Scout listed it without an attachment ID.",
            "Failed to save inline image (CleanShot.png): HTTP 404: Help Scout's image CDN did not return the image.",
        ])
    }

    // MARK: Inline images

    private let canary = InlineImageTests.canaryImage
    private let appleMail = InlineImageTests.appleMailImage
    private let canaryName = "6ED8F9BB-BF20-4EF1-930F-E829E7355D47_4_5005_c.jpeg"
    private let appleMailName = "CleanShot-2026-10-15-at-14-09-13-2x.png"

    private func image(_ text: String) -> ScriptedHTTPTransport.Reply {
        .response(HTTPResponse(statusCode: 200, headers: ["Content-Type": "image/png"], body: Data(text.utf8)))
    }

    /// The documented naming rule, computed independently of the implementation.
    private func inlineName(_ source: String, _ filename: String) -> String {
        let hash = SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
        return "inline-\(hash.prefix(12))-\(filename)"
    }

    func testDownloadsInlineImagesOncePerSourceWithoutCredentialsAndNeverFetchesOtherImages() async throws {
        let older = """
        <div>Export fails.</div>
        <img id="ex-CE46" alt="" width="0" height="0" src="https://receipts.canarymail.io/track/D98D.png">
        <img src="\(canary)" style="max-width:90vw;width:179px;" alt="\(canary)">
        <img src="https://tracker.example.com/logo.png"><img src="https://d33v4339jhl8k0.cloudfront.net/customer-avatar/1/a.png">
        <img src="https://d33v4339jhl8k0.cloudfront.net.evil.com/inline/1/a/b/x.png"><img src="cid:image001.png">
        <img src="\(canary)" alt="\(canary)">
        --<br>Sent from Eason
        """
        let newer = #"<img alt="CleanShot 2026-10-15 at 14.09.13@2x.png" width="640" src="\#(appleMail)"> <img src="\#(canary)">"#
        // Threads arrive newest first, as the API lists them.
        let threads = [
            thread(2, createdAt: "2024-01-02T09:00:00Z", [], body: newer),
            thread(1, createdAt: "2024-01-01T09:00:00Z", [attachment(30, "photo.png")], body: older),
        ]
        let (client, transport) = client([data("attached"), image("canary"), image("apple-mail")])
        let directory = root.appendingPathComponent("files")

        let download = try await client.downloadAttachments(in: view(threads), to: directory.path)

        let canaryPath = directory.path + "/" + inlineName(canary, canaryName)
        let appleMailPath = directory.path + "/" + inlineName(appleMail, appleMailName)
        XCTAssertEqual(download.saved, [
            .init(source: .attachment(30), filename: "photo.png", path: directory.path + "/30-photo.png", byteCount: 8),
            .init(source: .inlineImage(canary), filename: canaryName, path: canaryPath, byteCount: 6),
            .init(source: .inlineImage(appleMail), filename: appleMailName, path: appleMailPath, byteCount: 10),
        ])
        XCTAssertEqual(download.skipped, [])
        XCTAssertEqual(download.failed, [])
        XCTAssertEqual(download.attachmentPaths, [30: directory.path + "/30-photo.png"])
        XCTAssertEqual(download.inlineImagePaths, [canary: canaryPath, appleMail: appleMailPath])
        XCTAssertEqual(OutputFormatter.attachmentPaths(download), [directory.path + "/30-photo.png", canaryPath, appleMailPath].map { $0 + "\n" }.joined())
        XCTAssertEqual(try String(contentsOfFile: canaryPath, encoding: .utf8), "canary")
        XCTAssertEqual(try String(contentsOfFile: appleMailPath, encoding: .utf8), "apple-mail")
        XCTAssertEqual(try names(in: directory), ["30-photo.png", inlineName(canary, canaryName), inlineName(appleMail, appleMailName)].sorted())
        XCTAssertTrue(inlineName(canary, canaryName).hasPrefix("inline-"))

        let requests = await transport.requests
        XCTAssertEqual(requests.map(\.url.absoluteString), [
            "https://api.helpscout.net/v2/conversations/12/attachments/30/data", canary, appleMail,
        ])
        XCTAssertEqual(requests[0].headers["Authorization"], "Bearer test-token")
        for request in requests.dropFirst() {
            XCTAssertEqual(request.method, "GET")
            XCTAssertEqual(request.headers, ["Accept": "image/*"], "No Authorization header goes to the CDN")
        }
    }

    func testInlineOnlyConversationCreatesTheDirectory() async throws {
        let threads = [thread(1, createdAt: "2024-01-01T09:00:00Z", [], body: #"<div><img src="\#(appleMail)"></div>"#)]
        let (client, _) = client([image("png")])
        let directory = root.appendingPathComponent("nested/inline")

        let download = try await client.downloadAttachments(in: view(threads), to: directory.path)

        XCTAssertFalse(download.isEmpty)
        XCTAssertEqual(download.saved.map(\.source), [.inlineImage(appleMail)])
        XCTAssertEqual(try names(in: directory), [inlineName(appleMail, appleMailName)])
    }

    func testOnlyExternalImagesAndTrackingPixelsDownloadNothing() async throws {
        let body = """
        <img src="https://tracker.example.com/open.png"><img src="\(canary)" width="0">
        <img src="\(appleMail)" height="0"><img src="http://d33v4339jhl8k0.cloudfront.net/inline/1/a/b/x.png">
        <img src="https://d33v4339jhl8k0.cloudfront.net/customer-avatar/192496/a.png"><img src="data:image/png;base64,AAAA">
        <!-- <img src="\(canary)"> -->
        """
        let (client, transport) = client([])
        let directory = root.appendingPathComponent("unused")

        let download = try await client.downloadAttachments(in: view([thread(1, createdAt: "2024-01-01T09:00:00Z", [], body: body)]), to: directory.path)

        XCTAssertTrue(download.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 0)
    }

    func testFailedInlineImageDoesNotStopOthersAndIsNotReplayed() async throws {
        let sources = (1...4).map { "https://d33v4339jhl8k0.cloudfront.net/inline/192496/aaa/b\($0)/shot.png" }
        let body = sources.map { #"<img src="\#($0)">"# }.joined()
        let (client, transport) = client([
            .json(404, "<Error/>"), .failure(URLError(.timedOut)), .response(HTTPResponse(statusCode: 200)), image("ok"),
        ])
        let directory = root.appendingPathComponent("files")

        let download = try await client.downloadAttachments(in: view([thread(1, createdAt: "2024-01-01T09:00:00Z", [], body: body)]), to: directory.path)

        XCTAssertEqual(download.failed.map(\.source), sources.prefix(3).map(AttachmentDownload.Source.inlineImage))
        XCTAssertEqual(download.failed.map(\.reason), [
            "HTTP 404: Help Scout's image CDN did not return the image.",
            "Network request failed for an inline image on Help Scout's image CDN: \(URLError(.timedOut).localizedDescription)",
            "Help Scout's image CDN returned an empty file.",
        ])
        XCTAssertEqual(download.saved.map(\.source), [.inlineImage(sources[3])])
        XCTAssertEqual(try names(in: directory), [inlineName(sources[3], "shot.png")])
        XCTAssertEqual(Set(sources.map { inlineName($0, "shot.png") }).count, 4, "Same URL file name, distinct saved names")
        XCTAssertEqual(OutputFormatter.attachmentProblems(download).first,
                       "Failed to save inline image (shot.png): HTTP 404: Help Scout's image CDN did not return the image.")
        let requests = await transport.requests
        XCTAssertEqual(requests.map(\.url.absoluteString), sources)
    }

    func testInlineImageFileNamesAreOneSafePathComponent() throws {
        func name(_ path: String) throws -> String {
            ScoutClient.inlineImageFileName(try XCTUnwrap(InlineImage(source: "https://d33v4339jhl8k0.cloudfront.net/inline/1/a/b/" + path)))
        }
        let base = "https://d33v4339jhl8k0.cloudfront.net/inline/1/a/b/"
        XCTAssertEqual(try name("%23%3F%25%3A%3C%3E.png"), inlineName(base + "%23%3F%25%3A%3C%3E.png", "______.png"))
        XCTAssertEqual(try name("%07"), inlineName(base + "%07", "image"))
        XCTAssertEqual(try name(".hidden"), inlineName(base + ".hidden", ".hidden"))
        let long = try name(String(repeating: "x", count: 300) + ".png")
        XCTAssertLessThanOrEqual(long.utf8.count, 255)
        XCTAssertTrue(long.hasSuffix("x.png"))
        XCTAssertEqual(try name("photo.png"), try name("photo.png"), "Deterministic")
    }
}
