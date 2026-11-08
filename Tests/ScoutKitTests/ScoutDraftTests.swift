import Foundation
import XCTest
@testable import ScoutKit

@MainActor
final class ScoutDraftTests: XCTestCase {
    private let conversation = #"{"id":12,"type":"email","status":"closed","mailboxId":7,"primaryCustomer":{"id":42}}"#
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func client(_ replies: [ScriptedHTTPTransport.Reply]) -> (ScoutClient, ScriptedHTTPTransport) {
        let transport = ScriptedHTTPTransport(replies)
        let http = ScoutHTTPClient(configuration: .init(accessToken: "test-token"), transport: transport, tokenStore: InMemoryTokenStore())
        let date = now
        return (ScoutClient(http: http, clock: { date }), transport)
    }

    private func draft(_ id: Int = 90, body: JSONValue = .string("<p>Hello</p>"),
                       type: String = "message", state: String = "draft", scheduled: JSONValue = .null,
                       attachments: [JSONValue] = []) -> JSONValue {
        .object(["id": .integer(id), "type": .string(type), "state": .string(state), "body": body,
                 "scheduled": scheduled, "_embedded": .object(["attachments": .array(attachments)])])
    }

    private func page(_ threads: [JSONValue], pages: Int = 1) throws -> ScriptedHTTPTransport.Reply {
        let value = JSONValue.object(["_embedded": .object(["threads": .array(threads)]),
                                      "page": .object(["totalPages": .integer(pages)])])
        return .json(200, String(decoding: try JSONEncoder().encode(value), as: UTF8.self))
    }

    private func body(_ request: HTTPRequest) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(request.body))
    }

    func testSaveCreatesOnlyWhenNoDraftExistsAndPreservesStatus() async throws {
        let (client, transport) = client([.json(200, conversation), try page([draft(state: "published")]),
                                          .json(201, "", headers: ["Resource-ID": "91"])])
        let receipt = try await client.saveDraft(conversation: 12, content: .text("Hi & bye\nOK", html: false))
        XCTAssertEqual(receipt.operation, .created)
        XCTAssertEqual(receipt.threadID, 91)
        let requests = await transport.requests
        XCTAssertEqual(requests.map(\.method), ["GET", "GET", "POST"])
        XCTAssertEqual(requests[2].url.path, "/v2/conversations/12/reply")
        XCTAssertEqual(try body(requests[2]), .object([
            "customer": .object(["id": .integer(42)]), "draft": .bool(true),
            "status": .string("closed"), "text": .string("Hi &amp; bye<br>OK")
        ]))
    }

    func testSaveUpdatesDraftOnLaterPageWithOnlyTextPatch() async throws {
        let (client, transport) = client([.json(200, conversation), try page([draft(1, state: "published")], pages: 2),
                                          try page([draft()], pages: 2), .json(204, "")])
        let receipt = try await client.saveDraft(conversation: 12, content: .text("<p>Updated &amp; saved</p>", html: true))
        XCTAssertEqual(receipt.operation, .updated)
        XCTAssertEqual(receipt.threadID, 90)
        let requests = await transport.requests
        XCTAssertEqual(requests.map(\.method), ["GET", "GET", "GET", "PATCH"])
        XCTAssertEqual(requests[2].url.query, "page=2")
        XCTAssertEqual(requests[3].url.path, "/v2/conversations/12/threads/90")
        XCTAssertEqual(try body(requests[3]), .object([
            "op": .string("replace"), "path": .string("/text"), "value": .string("<p>Updated &amp; saved</p>")
        ]))
        let json = try JSONDecoder().decode(JSONValue.self, from: Data(OutputFormatter.receipt(receipt).utf8))
        XCTAssertEqual(json, .object(["conversationID": .integer(12), "threadID": .integer(90), "operation": .string("updated")]))
    }

    func testExplicitSelectionAndTemplateUseConversationInbox() async throws {
        let (client, transport) = client([.json(200, conversation), try page([draft(90), draft(91)]),
                                          .json(200, #"{"text":"<p>Template</p>"}"#), .json(204, "")])
        let receipt = try await client.saveDraft(conversation: 12, thread: 91, content: .template(3))
        XCTAssertEqual(receipt.threadID, 91)
        let requests = await transport.requests
        XCTAssertEqual(requests[2].url.path, "/v2/mailboxes/7/saved-replies/3")
        XCTAssertEqual(requests[3].url.path, "/v2/conversations/12/threads/91")
        XCTAssertEqual(try body(requests[3])["value"], .string("<p>Template</p>"))
    }

    func testAmbiguousDraftsAcrossPagesRequireSelectionForSaveAndSend() async throws {
        for sending in [false, true] {
            let (client, transport) = client([.json(200, conversation), try page([draft()], pages: 2),
                                              try page([draft(91, type: "forwardparent")], pages: 2)])
            do {
                if sending { _ = try await client.sendDraft(conversation: 12) }
                else { _ = try await client.saveDraft(conversation: 12, content: .text("Hi", html: false)) }
                XCTFail("Selected an ambiguous draft")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("90, 91"))
                XCTAssertTrue(error.localizedDescription.contains("--thread"))
            }
            let requests = await transport.requests
            XCTAssertEqual(requests.map(\.method), ["GET", "GET", "GET"])
        }
    }

    func testInvalidExplicitTargetsNeverCreateOrSend() async throws {
        for target in [draft(state: "published"), draft(state: "review"), draft(state: "hidden"),
                       draft(type: "note"), draft(type: "forwardparent"), draft(type: "forwardchild"), draft(91)] {
            for sending in [false, true] {
                let (client, transport) = client([.json(200, conversation), try page([target])])
                do {
                    if sending { _ = try await client.sendDraft(conversation: 12, thread: 90) }
                    else { _ = try await client.saveDraft(conversation: 12, thread: 90, content: .text("Hi", html: false)) }
                    XCTFail("Accepted invalid target")
                } catch { XCTAssertTrue(error is ScoutError) }
                let requests = await transport.requests
                XCTAssertEqual(requests.map(\.method), ["GET", "GET"])
            }
        }
    }

    func testScheduledDraftsAreNeverEditedOrReplaced() async throws {
        let schedules: [JSONValue] = [.object(["scheduledFor": .string("2027-04-01T12:00:00Z")]), .object([:]), .bool(true)]
        for scheduled in schedules {
            for (thread, content) in [(Int?.none, ReplyContent.text("Hi", html: false)), (90, .template(3))] {
                let (client, transport) = client([.json(200, conversation), try page([draft(scheduled: scheduled)])])
                do {
                    _ = try await client.saveDraft(conversation: 12, thread: thread, content: content)
                    XCTFail("Edited scheduled draft")
                } catch {
                    XCTAssertTrue(error.localizedDescription.contains("Draft 90 in conversation 12 is scheduled"))
                    XCTAssertTrue(error.localizedDescription.contains("Help Scout"))
                }
                let requests = await transport.requests
                XCTAssertEqual(requests.map(\.method), ["GET", "GET"])
            }
        }
    }

    func testUnsupportedSingleDraftDoesNotCauseCreation() async throws {
        let (client, transport) = client([.json(200, conversation), try page([draft(type: "forwardparent")])])
        do { _ = try await client.saveDraft(conversation: 12, content: .text("Hi", html: false)); XCTFail() }
        catch { XCTAssertTrue(error.localizedDescription.contains("not a supported reply draft")) }
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
    }

    func testNoDraftSendAndExplicitSaveFailWithoutWrites() async throws {
        for sending in [false, true] {
            let (client, transport) = client([.json(200, conversation), try page([])])
            do {
                if sending { _ = try await client.sendDraft(conversation: 12) }
                else { _ = try await client.saveDraft(conversation: 12, thread: 90, content: .text("Hi", html: false)) }
                XCTFail()
            } catch { XCTAssertTrue(error.localizedDescription.lowercased().contains("draft")) }
            let requests = await transport.requests
            XCTAssertEqual(requests.count, 2)
        }
    }

    func testUnscheduledSendSchedulesThenPublishesSameThread() async throws {
        let (client, transport) = client([.json(200, conversation), try page([draft(), draft(91)]), .json(204, ""), .json(204, "")])
        let receipt = try await client.sendDraft(conversation: 12, thread: 91)
        XCTAssertEqual(receipt.operation, .sent)
        XCTAssertEqual(receipt.threadID, 91)
        let requests = await transport.requests
        XCTAssertEqual(requests.map(\.method), ["GET", "GET", "PUT", "PATCH"])
        XCTAssertEqual(requests[2].url.path, "/v2/conversations/12/threads/91/schedule")
        XCTAssertEqual(requests[3].url.path, requests[2].url.path)
        XCTAssertEqual(try body(requests[2]), .object([
            "scheduledFor": .string(ISO8601DateFormatter().string(from: now.addingTimeInterval(86400))),
            "unscheduleOnCustomerReply": .bool(true), "sendAsCreator": .bool(false)
        ]))
        XCTAssertEqual(try body(requests[3]), .object([
            "op": .string("replace"), "path": .string("/state"), "value": .string("published")
        ]))
    }

    func testScheduledSendPublishesWithoutReplacingSchedule() async throws {
        let scheduled = JSONValue.object(["scheduledFor": .string("2027-04-01T12:00:00Z"), "sendAsId": .integer(4)])
        let (client, transport) = client([.json(200, conversation), try page([draft(scheduled: scheduled)]), .json(204, "")])
        _ = try await client.sendDraft(conversation: 12)
        let requests = await transport.requests
        XCTAssertEqual(requests.map(\.method), ["GET", "GET", "PATCH"])
        XCTAssertEqual(requests[2].url.path, "/v2/conversations/12/threads/90/schedule")
    }

    func testInvalidScheduleFailsWithoutOverwritingIt() async throws {
        for scheduled in [JSONValue.object([:]), .bool(true)] {
            let (client, transport) = client([.json(200, conversation), try page([draft(scheduled: scheduled)])])
            do { _ = try await client.sendDraft(conversation: 12); XCTFail() }
            catch { XCTAssertTrue(error.localizedDescription.contains("schedule data")) }
            let requests = await transport.requests
            XCTAssertEqual(requests.count, 2)
        }
    }

    func testEmptyAndUnresolvedBodiesCannotSendAndAreNotEchoed() async throws {
        let bodies: [JSONValue] = [.null, .string(""), .string(" \n"), .string("<p><br></p>"),
                                  .string("<p>&nbsp;&#160;</p>"), .string("<ul><li><br></li></ul>"),
                                  .string("<p>{%privateCustomerText%}</p>"), .string("&#123;%privateCustomerText%}"),
                                  .string("<script>privateCustomerText</script>")]
        for body in bodies {
            let (client, transport) = client([.json(200, conversation), try page([draft(body: body)])])
            do { _ = try await client.sendDraft(conversation: 12); XCTFail("Accepted \(body)") }
            catch { XCTAssertFalse(error.localizedDescription.contains("privateCustomerText")) }
            let requests = await transport.requests
            XCTAssertEqual(requests.count, 2)
        }
    }

    func testImageAndAttachmentDraftsCanSendWithoutChangingContent() async throws {
        for thread in [draft(body: .string("<p><img src='cid:image'></p>")),
                       draft(body: .string(""), attachments: [.object(["id": .integer(1)])])] {
            let (client, transport) = client([.json(200, conversation), try page([thread]), .json(204, ""), .json(204, "")])
            _ = try await client.sendDraft(conversation: 12)
            let requests = await transport.requests
            XCTAssertEqual(requests.map(\.method), ["GET", "GET", "PUT", "PATCH"])
            XCTAssertNil(try body(requests[2])["text"].string)
        }
    }

    func testFailuresDescribePhaseAndNeverReplayOrContinue() async throws {
        let failures: [(ScriptedHTTPTransport.Reply, Bool)] = [(.failure(URLError(.timedOut)), false),
            (.json(500), false), (.json(408), false), (.json(403), true), (.json(404), true), (.json(429), true)]
        for (failure, rejected) in failures {
            for phase in ["schedule", "publish", "scheduled-publish", "update"] {
                let scheduled: JSONValue = phase == "scheduled-publish" ? .object(["scheduledFor": .string("2027-01-01T00:00:00Z")]) : .null
                var replies: [ScriptedHTTPTransport.Reply] = [.json(200, conversation), try page([draft(scheduled: scheduled)])]
                if phase == "publish" { replies.append(.json(204, "")) }
                replies.append(failure)
                let (client, transport) = client(replies)
                do {
                    if phase == "update" { _ = try await client.saveDraft(conversation: 12, content: .text("Hi", html: false)) }
                    else { _ = try await client.sendDraft(conversation: 12) }
                    XCTFail()
                } catch {
                    if phase != "update" {
                        let message = error.localizedDescription
                        XCTAssertTrue(message.contains("draft 90 in conversation 12"))
                        XCTAssertTrue(message.contains("before retrying"))
                        if phase == "schedule" {
                            XCTAssertTrue(message.contains("did not attempt publication"))
                            XCTAssertTrue(message.contains(rejected ? "Scheduling was rejected" : "may be scheduled"))
                        } else {
                            XCTAssertTrue(message.contains(rejected ? "Publication was rejected" : "may already have been sent"))
                            XCTAssertTrue(message.contains(rejected ? "scheduled time" : "send later"))
                        }
                    }
                }
                let requests = await transport.requests
                XCTAssertEqual(requests.count, replies.count)
                if phase == "schedule" { XCTAssertEqual(requests.last?.method, "PUT") }
            }
        }
    }

    func testReadFailuresAndMergedConversationsPreventWrites() async throws {
        for sending in [false, true] {
            for replies: [ScriptedHTTPTransport.Reply] in [
                [.json(301, "", headers: ["Location": "https://api.helpscout.net/v3/conversations/99"])],
                [.json(200, conversation), .json(500)],
                [.json(200, conversation), try page([], pages: 2), .json(403)]
            ] {
                let (client, transport) = client(replies)
                do {
                    if sending { _ = try await client.sendDraft(conversation: 12) }
                    else { _ = try await client.saveDraft(conversation: 12, content: .text("Hi", html: false)) }
                    XCTFail()
                } catch { XCTAssertTrue(error is ScoutError) }
                let requests = await transport.requests
                XCTAssertTrue(requests.allSatisfy { $0.method == "GET" })
            }
        }
    }

    func testHTTP408CompleteSendErrorsRemainConsistentlyUncertain() async throws {
        for publishing in [false, true] {
            var replies: [ScriptedHTTPTransport.Reply] = [.json(200, conversation), try page([draft()])]
            if publishing { replies.append(.json(204, "")) }
            replies.append(.json(408))
            let (client, transport) = client(replies)
            do { _ = try await client.sendDraft(conversation: 12); XCTFail() }
            catch {
                let phase = publishing
                    ? "Publication could not be confirmed. The reply may already have been sent, or the draft may remain scheduled and send later."
                    : "Scheduling could not be confirmed. The draft may be scheduled and send later. This command did not attempt publication."
                let method = publishing ? "PATCH" : "PUT"
                XCTAssertEqual(error.localizedDescription,
                    "Could not complete sending draft 90 in conversation 12. \(phase) "
                    + "Inspect the thread in Help Scout and cancel any remaining schedule before retrying. "
                    + "HTTP 408: Help Scout reported a request timeout for \(method) /v2/conversations/12/threads/90/schedule. "
                    + "The write outcome is uncertain; inspect the conversation before retrying.")
            }
            let requests = await transport.requests
            XCTAssertEqual(requests.count, replies.count)
        }
    }

    func testInvalidInputsFailBeforeNetworkAndMissingCreatedIDIsSuccess() async throws {
        let (invalid, transport) = client([])
        do { _ = try await invalid.sendDraft(conversation: 0); XCTFail() } catch {}
        do { _ = try await invalid.sendDraft(conversation: 12, thread: 0); XCTFail() } catch {}
        do { _ = try await invalid.saveDraft(conversation: 12, thread: -1, content: .text("Hi", html: false)); XCTFail() } catch {}
        do { _ = try await invalid.saveDraft(conversation: 12, content: .text("{%name%}", html: true)); XCTFail() } catch {}
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)

        let (client, _) = client([.json(200, conversation), try page([]), .json(201, "")])
        let receipt = try await client.saveDraft(conversation: 12, content: .text("Hi", html: false))
        XCTAssertEqual(receipt.operation, .created)
        XCTAssertNil(receipt.threadID)
    }

    func testDraftThreadIDAppearsInMarkdown() throws {
        let text = OutputFormatter.Markdown.conversation(.object(["id": .integer(12)]), threads: [draft()])
        XCTAssertTrue(text.contains("Thread ID: 90"))
        XCTAssertTrue(text.contains("DRAFT reply (not sent)"))
    }
}
