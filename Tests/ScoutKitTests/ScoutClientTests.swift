import Foundation
import XCTest
@testable import ScoutKit

@MainActor
final class ScoutClientTests: XCTestCase {
    private func client(_ replies: [ScriptedHTTPTransport.Reply]) -> (ScoutClient, ScriptedHTTPTransport) {
        let transport = ScriptedHTTPTransport(replies)
        let http = ScoutHTTPClient(configuration: .init(accessToken: "test-token"), transport: transport, tokenStore: InMemoryTokenStore())
        return (ScoutClient(http: http), transport)
    }

    private let conversation = #"{"id":12,"type":"email","status":"closed","mailboxId":7,"primaryCustomer":{"id":42},"subject":"Help"}"#

    func testListsWholeCursorPageAndPreservesFilters() async throws {
        let (client, transport) = client([.json(200, #"{"_embedded":{"conversations":[{"id":1},{"id":2}]},"_links":{"next":{"href":"https://api.helpscout.net/v3/conversations?status=closed&cursor=a%2Bb%3D"}}}"#)])
        let page = try await client.conversations(inbox: 7, status: .closed, cursor: "previous")
        XCTAssertEqual(page.items.count, 2)
        XCTAssertEqual(page.nextCursor, "a+b=")
        let requests = await transport.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url.path, "/v3/conversations")
        XCTAssertTrue(request.url.absoluteString.contains("inboxId=7"))
        XCTAssertTrue(request.url.absoluteString.contains("status=closed"))
        XCTAssertTrue(request.url.absoluteString.contains("cursor=previous"))
    }

    func testSearchUsesOnlyQueryAndCursorAndEncodesPlus() async throws {
        let (client, transport) = client([.json(200, #"{"_embedded":{"conversations":[]}}"#)])
        _ = try await client.search(#"email:"a+b@my-company.com""#)
        let requests = await transport.requests
        XCTAssertEqual(requests[0].url.path, "/v3/conversations/search")
        XCTAssertTrue(requests[0].url.absoluteString.contains("a%2Bb"))
        XCTAssertFalse(requests[0].url.absoluteString.contains("inboxId="))
        XCTAssertFalse(requests[0].url.absoluteString.contains("status="))
    }

    func testPagesWithoutEmbeddedResourcesAreEmpty() async throws {
        let (client, _) = client([
            .json(200, #"{"_links":{"self":{"href":"https://api.helpscout.net/v3/conversations/search?query=x"},"first":{"href":"https://api.helpscout.net/v3/conversations/search?query=x"}}}"#),
            .json(200, #"{"_embedded":{}}"#),
            .json(200, #"{"page":{"number":1,"size":50,"totalElements":0,"totalPages":0}}"#)
        ])
        let search = try await client.search(#"email:"nobody@example.com""#)
        XCTAssertEqual(search, ResourcePage(items: []))
        let customers = try await client.customers(email: "nobody@example.com")
        XCTAssertEqual(customers, ResourcePage(items: []))
        let inboxes = try await client.inboxes()
        XCTAssertEqual(inboxes, ResourcePage(items: []))
    }

    func testMalformedCollectionsStillFail() async throws {
        for body in [#"{"_embedded":{"conversations":{}}}"#, #"{"_embedded":"none"}"#, #"[]"#] {
            let (client, _) = client([.json(200, body)])
            do { _ = try await client.search("subject:refund"); XCTFail("Accepted \(body)") }
            catch { guard case ScoutError.decoding = error else { return XCTFail("Unexpected error \(error)") } }
        }
    }

    func testCustomerFilterKeepsRecordsWithoutEmbeddedEmails() async throws {
        let (client, transport) = client([.json(200, #"{"_embedded":{"customers":[{"id":5,"firstName":"Jane"}]}}"#)])
        let page = try await client.customers(email: "jane+test@example.com")
        XCTAssertEqual(page.items.count, 1)
        let requests = await transport.requests
        XCTAssertEqual(requests[0].url.path, "/v3/customers")
        XCTAssertTrue(requests[0].url.absoluteString.contains("email=jane%2Btest%40example.com"))
    }

    func testShowFetchesEveryThreadPageAndKeepsMetadata() async throws {
        let (client, transport) = client([
            .json(200, conversation),
            .json(200, #"{"_embedded":{"threads":[{"id":2,"state":"draft","body":"Draft"}]},"page":{"number":1,"totalPages":2}}"#),
            .json(200, #"{"_embedded":{"threads":[{"id":1,"state":"published","body":"Original"}]},"page":{"number":2,"totalPages":2}}"#)
        ])
        let view = try await client.show(12)
        XCTAssertEqual(view.threads.count, 2)
        XCTAssertEqual(view.threads[0]["state"].string, "draft")
        let requests = await transport.requests
        XCTAssertEqual(requests.map(\.url.path), ["/v3/conversations/12", "/v3/conversations/12/threads", "/v3/conversations/12/threads"])
        XCTAssertEqual(requests[2].url.query, "page=2")
    }

    func testInboxPagesAndUnpagedTemplateArray() async throws {
        let (client, transport) = client([
            .json(200, #"{"_embedded":{"mailboxes":[{"id":7}]},"page":{"number":1,"totalPages":2}}"#),
            .json(200, #"[{"id":10,"name":"Thanks","preview":"Thank you"}]"#),
            .json(200, #"{"id":42,"_embedded":{"properties":[{"slug":"plan","value":"paid"}]}}"#)
        ])
        let inboxes = try await client.inboxes()
        XCTAssertEqual(inboxes.nextPage, 2)
        let templates = try await client.templates(inbox: 7)
        XCTAssertEqual(templates.items[0]["id"].int, 10)
        XCTAssertNil(templates.nextPage)
        let customer = try await client.customer(42)
        XCTAssertEqual(customer["_embedded"]["properties"].array?.count, 1)
        let requests = await transport.requests
        XCTAssertEqual(requests[2].url.path, "/v2/customers/42")
    }

    func testTemplateCreateAllowsVariablesAndAcceptsEmptySuccess() async throws {
        let (client, transport) = client([.json(201, "")])
        let text = try ReplyBody.prepareTemplate("Hi {%customer.firstName%} & <friend>\nThanks", html: false)
        let receipt = try await client.createTemplate(inbox: 7, name: "Greeting", text: text, chatText: "Hi {%customer.firstName%}")
        XCTAssertEqual(receipt.operation, "created")
        XCTAssertNil(receipt.templateID)
        XCTAssertEqual(receipt.inboxID, 7)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].method, "POST")
        XCTAssertEqual(requests[0].url.path, "/v2/mailboxes/7/saved-replies")
        let body = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(requests[0].body))
        XCTAssertEqual(body, .object([
            "name": .string("Greeting"),
            "text": .string("Hi {%customer.firstName%} &amp; &lt;friend&gt;<br>Thanks"),
            "chatText": .string("Hi {%customer.firstName%}")
        ]))
        XCTAssertThrowsError(try ReplyBody.prepare(text, html: true))
        let json = try JSONDecoder().decode(JSONValue.self, from: Data(OutputFormatter.receipt(receipt).utf8))
        XCTAssertEqual(json["templateID"], .null)
    }

    func testTemplateChatCreationAndListing() async throws {
        let (client, transport) = client([.json(201, "", headers: ["Resource-ID": "10"]), .json(200, "[]")])
        let receipt = try await client.createTemplate(inbox: 7, name: "Chat", chatText: "Hi")
        XCTAssertEqual(receipt.templateID, 10)
        _ = try await client.templates(inbox: 7, includeChat: true)
        let requests = await transport.requests
        let body = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(requests[0].body))
        XCTAssertNil(body["text"].string)
        XCTAssertEqual(requests[1].url.query, "includeChatReplies=true")
    }

    func testTemplateUpdatesPreserveOmittedFields() async throws {
        for changes in [("Renamed", nil, nil), (nil, "<p>Updated {%customer.firstName%}</p>", nil), (nil, nil, "New chat")] as [(String?, String?, String?)] {
            let (client, transport) = client([
                .json(200, #"{"id":10,"name":"Greeting","text":"<p>Hello</p>","chatText":"Hello chat"}"#), .json(204, "")
            ])
            let receipt = try await client.updateTemplate(10, inbox: 7, name: changes.0, text: changes.1, chatText: changes.2)
            XCTAssertEqual(receipt.operation, "updated")
            XCTAssertEqual(receipt.templateID, 10)
            let requests = await transport.requests
            XCTAssertEqual(requests.map(\.method), ["GET", "PUT"])
            XCTAssertEqual(requests.map(\.url.path), Array(repeating: "/v2/mailboxes/7/saved-replies/10", count: 2))
            let body = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(requests[1].body))
            XCTAssertEqual(body, .object([
                "name": .string(changes.0 ?? "Greeting"), "text": .string(changes.1 ?? "<p>Hello</p>"),
                "chatText": .string(changes.2 ?? "Hello chat")
            ]))
        }
    }

    func testTemplateDeleteAcceptsEmptySuccess() async throws {
        let (client, transport) = client([.json(204, "")])
        let receipt = try await client.deleteTemplate(10, inbox: 7)
        XCTAssertEqual(receipt.operation, "deleted")
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].method, "DELETE")
        XCTAssertEqual(requests[0].url.path, "/v2/mailboxes/7/saved-replies/10")
        XCTAssertNil(requests[0].body)
    }

    func testTemplateRenamePreservesSingleChannelReplies() async throws {
        for current in [
            #"{"id":10,"name":"Chat","text":null,"chatText":"Hi"}"#,
            #"{"id":10,"name":"Email","text":"<p>Hi</p>","chatText":null}"#,
            #"{"id":10,"name":"Email","text":"<p>Hi</p>"}"#
        ] {
            let (client, transport) = client([.json(200, current), .json(204, "")])
            _ = try await client.updateTemplate(10, inbox: 7, name: "Renamed")
            let requests = await transport.requests
            let body = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(requests[1].body))
            let stored = try JSONDecoder().decode(JSONValue.self, from: Data(current.utf8))
            let expected: JSONValue = stored["text"].string == nil
                ? .object(["name": .string("Renamed"), "chatText": .string("Hi")])
                : .object(["name": .string("Renamed"), "text": .string("<p>Hi</p>")])
            XCTAssertEqual(body, expected)
        }
    }

    func testTemplateMissingNamePreventsPutUnlessSupplied() async throws {
        let nameless = #"{"id":10,"text":"Hi"}"#
        let (missingClient, missingTransport) = client([.json(200, nameless)])
        do { _ = try await missingClient.updateTemplate(10, inbox: 7, text: "Updated"); XCTFail() }
        catch { XCTAssertTrue(error.localizedDescription.contains("Provide --name")) }
        let requests = await missingTransport.requests
        XCTAssertEqual(requests.map(\.method), ["GET"])

        let (repairClient, repairTransport) = client([.json(200, nameless), .json(204, "")])
        _ = try await repairClient.updateTemplate(10, inbox: 7, name: "Named")
        let repaired = await repairTransport.requests
        XCTAssertEqual(repaired.map(\.method), ["GET", "PUT"])
    }

    func testTemplateInvalidInputsDoNotMakeRequests() async throws {
        let (client, transport) = client([])
        do { _ = try await client.createTemplate(inbox: 0, name: "Hi", text: "Hi"); XCTFail() } catch {}
        do { _ = try await client.createTemplate(inbox: 7, name: " ", text: "Hi"); XCTFail() } catch {}
        do { _ = try await client.createTemplate(inbox: 7, name: "Hi"); XCTFail() } catch {}
        do { _ = try await client.updateTemplate(10, inbox: 7); XCTFail() } catch {}
        do { _ = try await client.updateTemplate(10, inbox: 7, text: " "); XCTFail() } catch {}
        do { _ = try await client.updateTemplate(0, inbox: 7, name: "Hi"); XCTFail() } catch {}
        do { _ = try await client.deleteTemplate(10, inbox: -1); XCTFail() } catch {}
        do { _ = try await client.deleteTemplate(0, inbox: 7); XCTFail() } catch {}
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testTemplateWriteFailuresAreNotReplayed() async throws {
        for (failure, uncertain) in [(ScriptedHTTPTransport.Reply.failure(URLError(.timedOut)), true), (.json(500), true), (.json(403), false), (.json(404), false)] {
            for operation in ["create", "update", "delete"] {
                let replies: [ScriptedHTTPTransport.Reply] = operation == "update"
                    ? [.json(200, #"{"name":"Original","text":"Hello"}"#), failure] : [failure]
                let (client, transport) = client(replies)
                do {
                    switch operation {
                    case "create": _ = try await client.createTemplate(inbox: 7, name: "Hi", text: "Hi")
                    case "update": _ = try await client.updateTemplate(10, inbox: 7, name: "Hi")
                    default: _ = try await client.deleteTemplate(10, inbox: 7)
                    }
                    XCTFail()
                } catch {
                    XCTAssertTrue(error is ScoutError)
                    XCTAssertFalse(error.localizedDescription.contains("inspect the conversation"))
                    if uncertain {
                        XCTAssertTrue(error.localizedDescription.contains("inspect the inbox's saved replies before retrying"))
                    }
                }
                let requests = await transport.requests
                XCTAssertEqual(requests.count, replies.count)
            }
        }
        let (client, transport) = client([.json(404)])
        do { _ = try await client.updateTemplate(10, inbox: 7, name: "Hi"); XCTFail() } catch {}
        let requests = await transport.requests
        XCTAssertEqual(requests.map(\.method), ["GET"])
    }

    func testDraftPreservesStatusAndPlainTextIsEscaped() async throws {
        let (client, transport) = client([.json(200, conversation), .json(201, "", headers: ["Resource-Id": "90"])])
        let receipt = try await client.createDraft(conversation: 12, content: .text("Thanks & <done>\nOK", html: false))
        XCTAssertTrue(receipt.draft)
        XCTAssertEqual(receipt.threadID, 90)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        let post = requests[1]
        XCTAssertEqual(post.method, "POST")
        XCTAssertEqual(post.url.path, "/v2/conversations/12/reply")
        let body = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(post.body))
        XCTAssertEqual(body["draft"], .bool(true))
        XCTAssertEqual(body["status"].string, "closed")
        XCTAssertEqual(body["customer"]["id"].int, 42)
        XCTAssertEqual(body["text"].string, "Thanks &amp; &lt;done&gt;<br>OK")
    }

    func testSendUsesTemplateFromConversationInboxAndExplicitStatus() async throws {
        let (client, transport) = client([
            .json(200, conversation), .json(200, #"{"id":10,"text":"<p>Thanks &amp; hello</p>","chatText":"wrong"}"#),
            .json(201, "", headers: ["Resource-ID": "91"])
        ])
        let receipt = try await client.sendReply(conversation: 12, content: .template(10), status: .pending)
        XCTAssertFalse(receipt.draft)
        let requests = await transport.requests
        XCTAssertEqual(requests[1].url.path, "/v2/mailboxes/7/saved-replies/10")
        let body = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(requests[2].body))
        XCTAssertEqual(body["draft"], .bool(false))
        XCTAssertEqual(body["status"].string, "pending")
        XCTAssertEqual(body["text"].string, "<p>Thanks &amp; hello</p>")
    }

    func testMissingReceiptIDDoesNotReportFailedSend() async throws {
        let (client, transport) = client([.json(200, conversation), .json(201, "")])
        let receipt = try await client.sendReply(conversation: 12, content: .text("Hello", html: false))
        XCTAssertNil(receipt.threadID)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
    }

    func testInvalidInputsMakeNoRequests() async throws {
        let (client, transport) = client([])
        do { _ = try await client.search("refund"); XCTFail() } catch {}
        do { _ = try await client.customers(email: "a@b.com", query: "firstName:Jane"); XCTFail() } catch {}
        do { _ = try await client.createDraft(conversation: 12, content: .text("{%customer.firstName%}", html: false)); XCTFail() } catch {}
        do { _ = try await client.sendReply(conversation: 12, content: .text(" \n", html: true)); XCTFail() } catch {}
        do { _ = try await client.customer(-1); XCTFail() } catch {}
        do { try await client.mark(conversation: 0, status: .spam); XCTFail() } catch {}
        do { try await client.mark(conversation: -1, status: .closed); XCTFail() } catch {}
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testMarkPatchesOnlyStatusAndAcceptsEmptySuccess() async throws {
        for status in ReplyStatus.allCases {
            let (client, transport) = client([.json(200, conversation), .json(204, "")])
            let receipt = try await client.mark(conversation: 12, status: status)
            XCTAssertEqual(receipt.conversationID, 12)
            XCTAssertEqual(receipt.status, status)
            let requests = await transport.requests
            XCTAssertEqual(requests.map(\.method), ["GET", "PATCH"])
            XCTAssertEqual(requests.map(\.url.path), ["/v3/conversations/12", "/v2/conversations/12"])
            let patch = try XCTUnwrap(requests.last)
            let body = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(patch.body))
            XCTAssertEqual(body, .object([
                "op": .string("replace"), "path": .string("/status"), "value": .string(status.rawValue)
            ]))
        }
    }

    func testMergedConversationCannotBeMarked() async throws {
        let (client, transport) = client([.json(301, "", headers: ["Location": "https://api.helpscout.net/v3/conversations/99"])])
        do { try await client.mark(conversation: 12, status: .spam); XCTFail() }
        catch { XCTAssertEqual(error as? ScoutError, .merged(99)) }
        let requests = await transport.requests
        XCTAssertEqual(requests.map(\.method), ["GET"])
    }

    func testMarkFailuresAreNotReplayed() async throws {
        for failure in [ScriptedHTTPTransport.Reply.failure(URLError(.timedOut)), .json(500), .json(403), .json(404)] {
            let (client, transport) = client([.json(200, conversation), failure])
            do { try await client.mark(conversation: 12, status: .closed); XCTFail() }
            catch { XCTAssertTrue(error is ScoutError) }
            let requests = await transport.requests
            XCTAssertEqual(requests.map(\.method), ["GET", "PATCH"])
        }
    }

    func testUnresolvedSavedTemplateCannotPost() async throws {
        let (client, transport) = client([.json(200, conversation), .json(200, #"{"text":"Hi {%customer.firstName,fallback=there%}"}"#)])
        do { _ = try await client.sendReply(conversation: 12, content: .template(10)); XCTFail() } catch {}
        let requests = await transport.requests
        XCTAssertEqual(requests.map(\.method), ["GET", "GET"])
    }

    func testMergedConversationCannotPost() async throws {
        let (client, transport) = client([.json(301, "", headers: ["Location": "https://api.helpscout.net/v3/conversations/99"])])
        do { _ = try await client.sendReply(conversation: 12, content: .text("Hi", html: false)); XCTFail() }
        catch { XCTAssertEqual(error as? ScoutError, .merged(99)) }
        let requests = await transport.requests
        XCTAssertEqual(requests.map(\.method), ["GET"])
    }

    func testUncertainSendIsNotReplayed() async throws {
        let (client, transport) = client([.json(200, conversation), .failure(URLError(.timedOut))])
        do { _ = try await client.sendReply(conversation: 12, content: .text("Hi", html: false)); XCTFail() }
        catch { XCTAssertTrue(error.localizedDescription.contains("inspect the conversation")) }
        let requests = await transport.requests
        XCTAssertEqual(requests.map(\.method), ["GET", "POST"])
    }

    func testBodySourceValidationAndFileVariableCheck() throws {
        XCTAssertThrowsError(try ReplyBody.validateSources(body: "hi", file: nil, template: 1, html: false))
        XCTAssertThrowsError(try ReplyBody.validateSources(body: nil, file: nil, template: 1, html: true))
        let content = try ReplyBody.content(body: nil, file: "reply.txt", template: nil, html: false,
                                            stdinIsTerminal: true, readStdin: { XCTFail(); return Data() },
                                            readFile: { _ in Data("{%customer.firstName%}".utf8) })
        guard case .text(let text, let html) = content else { return XCTFail() }
        XCTAssertThrowsError(try ReplyBody.prepare(text, html: html))
    }
}
