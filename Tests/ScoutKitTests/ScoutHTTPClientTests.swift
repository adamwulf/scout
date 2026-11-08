import Foundation
import XCTest
@testable import ScoutKit

final class ScoutHTTPClientTests: XCTestCase {
    private let appID = "app-id-123"
    private let appSecret = "s3cr+t&=/Secret"
    private let explicitToken = "explicit-token-ZZZ"

    private var clientCredentials: ScoutConfiguration {
        ScoutConfiguration(appID: appID, appSecret: appSecret, sourceDescription: "fixture.env")
    }

    private var tokenConfiguration: ScoutConfiguration {
        ScoutConfiguration(appID: appID, appSecret: appSecret, accessToken: explicitToken, sourceDescription: "fixture.env")
    }

    private func client(
        _ configuration: ScoutConfiguration,
        _ transport: ScriptedHTTPTransport,
        store: InMemoryTokenStore = InMemoryTokenStore(),
        clock: ManualClock = ManualClock()
    ) -> ScoutHTTPClient {
        ScoutHTTPClient(configuration: configuration, transport: transport, tokenStore: store, clock: { clock.now() })
    }

    // MARK: Client credentials

    func testExchangesTokenOnceThenReusesItUntilExpiry() async throws {
        let clock = ManualClock()
        let start = clock.now()
        let store = InMemoryTokenStore()
        let transport = ScriptedHTTPTransport([
            .token("issued-token-1"), .json(200), .json(200), .token("issued-token-2"), .json(200),
        ])
        let client = client(clientCredentials, transport, store: store, clock: clock)

        _ = try await client.request(path: "/v2/users/me")
        _ = try await client.request(path: "/v2/mailboxes")
        clock.advance(172_800 - 30)  // inside the early-renewal margin
        _ = try await client.request(path: "/v2/users/me")

        let requests = await transport.requests
        XCTAssertEqual(requests.map(\.method), ["POST", "GET", "GET", "POST", "GET"])
        let exchange = requests[0]
        XCTAssertEqual(exchange.url.absoluteString, "https://api.helpscout.net/v2/oauth2/token")
        XCTAssertEqual(exchange.headers["Content-Type"], "application/x-www-form-urlencoded")
        XCTAssertNil(exchange.headers["Authorization"])
        XCTAssertEqual(
            String(decoding: exchange.body ?? Data(), as: UTF8.self),
            "grant_type=client_credentials&client_id=app-id-123&client_secret=s3cr%2Bt%26%3D%2FSecret"
        )
        XCTAssertEqual(requests[1].headers["Authorization"], "Bearer issued-token-1")
        XCTAssertEqual(requests[2].headers["Authorization"], "Bearer issued-token-1")
        XCTAssertEqual(requests[4].headers["Authorization"], "Bearer issued-token-2")
        for request in requests where request.method == "GET" {
            XCTAssertNil(request.url.query)
            XCTAssertNil(request.body)
        }

        let saved = await store.token
        let saveCount = await store.saveCount
        XCTAssertEqual(saveCount, 2)
        XCTAssertEqual(
            saved,
            CachedToken(appID: appID, accessToken: "issued-token-2", expiresAt: start.addingTimeInterval(2 * 172_800 - 30))
        )
    }

    func testReusesStoredTokenOnlyForSameAppBeforeExpiry() async throws {
        let clock = ManualClock()
        let store = InMemoryTokenStore(
            CachedToken(appID: "other-app", accessToken: "foreign-token", expiresAt: clock.now().addingTimeInterval(3600))
        )

        let first = ScriptedHTTPTransport([.token("issued-token-1", expiresIn: 3600), .json(200)])
        _ = try await client(clientCredentials, first, store: store, clock: clock).request(path: "/v2/users/me")
        let firstRequests = await first.requests
        XCTAssertEqual(firstRequests.map(\.url.path), ["/v2/oauth2/token", "/v2/users/me"])
        XCTAssertEqual(firstRequests[1].headers["Authorization"], "Bearer issued-token-1")

        let second = ScriptedHTTPTransport([.json(200)])
        _ = try await client(clientCredentials, second, store: store, clock: clock).request(path: "/v2/users/me")
        let secondRequests = await second.requests
        XCTAssertEqual(secondRequests.map { $0.headers["Authorization"] }, ["Bearer issued-token-1"])

        clock.advance(3600)
        let third = ScriptedHTTPTransport([.token("issued-token-2"), .json(200)])
        _ = try await client(clientCredentials, third, store: store, clock: clock).request(path: "/v2/users/me")
        let thirdRequests = await third.requests
        XCTAssertEqual(thirdRequests.map(\.url.path), ["/v2/oauth2/token", "/v2/users/me"])
        let saved = await store.token
        XCTAssertEqual(saved?.accessToken, "issued-token-2")
    }

    func testRenewsOnceAfter401AndRetriesOriginalRequest() async throws {
        let clock = ManualClock()
        let store = InMemoryTokenStore(
            CachedToken(appID: appID, accessToken: "stale-token-0", expiresAt: clock.now().addingTimeInterval(3600))
        )
        let transport = ScriptedHTTPTransport([
            .json(401), .token("issued-token-1"), .json(201, "", headers: ["Resource-ID": "77"]),
        ])

        let response = try await client(clientCredentials, transport, store: store, clock: clock).request(
            method: "POST", path: "/v2/conversations/5/reply", body: .object(["text": .string("Hi"), "draft": .bool(true)])
        )

        XCTAssertEqual(response.statusCode, 201)
        XCTAssertEqual(response.header("resource-id"), "77")
        let requests = await transport.requests
        XCTAssertEqual(requests.map(\.url.path), ["/v2/conversations/5/reply", "/v2/oauth2/token", "/v2/conversations/5/reply"])
        XCTAssertEqual(requests[0].headers["Authorization"], "Bearer stale-token-0")
        XCTAssertEqual(requests[2].headers["Authorization"], "Bearer issued-token-1")
        XCTAssertEqual(requests[2].body, requests[0].body)
        let saved = await store.token
        XCTAssertEqual(saved?.accessToken, "issued-token-1")
    }

    func testSecond401ExplainsInactiveOwnerAndDiscardsToken() async throws {
        let clock = ManualClock()
        let store = InMemoryTokenStore(
            CachedToken(appID: appID, accessToken: "stale-token-0", expiresAt: clock.now().addingTimeInterval(3600))
        )
        let transport = ScriptedHTTPTransport([
            .json(401, #"{"message":"Bad token stale-token-0"}"#),
            .token("issued-token-1"),
            .json(401, #"{"message":"Unauthorized issued-token-1 s3cr+t&=/Secret"}"#),
        ])

        let error = await scoutError {
            try await self.client(self.clientCredentials, transport, store: store, clock: clock).request(path: "/v2/users/me")
        }

        guard case .api(401, let message)? = error else { return XCTFail("Unexpected \(String(describing: error))") }
        XCTAssertTrue(message.contains("active, invited user"), message)
        XCTAssertTrue(message.contains("GET /v2/users/me"), message)
        assertNoSecrets(message)
        let requestCount = await transport.requests.count
        XCTAssertEqual(requestCount, 3)
        let saved = await store.token
        XCTAssertNil(saved)
    }

    func testTokenFailuresHideRawResponseAndSecrets() async throws {
        let rejected = ScriptedHTTPTransport([
            .json(401, #"{"error":"invalid_client","error_description":"RAW OAUTH DETAIL s3cr+t&=/Secret"}"#),
        ])
        let store = InMemoryTokenStore()
        let error = await scoutError { try await self.client(self.clientCredentials, rejected, store: store).request(path: "/v2/users/me") }
        guard case .api(401, let message)? = error else { return XCTFail("Unexpected \(String(describing: error))") }
        XCTAssertTrue(message.contains("invalid_client"), message)
        XCTAssertTrue(message.contains("SCOUT_APP_SECRET"), message)
        XCTAssertTrue(message.contains("fixture.env"), message)
        XCTAssertFalse(message.contains("RAW OAUTH"), message)
        assertNoSecrets(message)
        let rejectedCount = await rejected.requests.count
        let saveCount = await store.saveCount
        XCTAssertEqual(rejectedCount, 1)
        XCTAssertEqual(saveCount, 0)

        let offline = ScriptedHTTPTransport([
            .failure(URLError(.timedOut, userInfo: [NSLocalizedDescriptionKey: "timed out: client_secret=s3cr%2Bt%26%3D%2FSecret"])),
        ])
        let transportError = await scoutError { try await self.client(self.clientCredentials, offline).request(path: "/v2/users/me") }
        guard case .transport(let transportMessage)? = transportError else {
            return XCTFail("Unexpected \(String(describing: transportError))")
        }
        XCTAssertTrue(transportMessage.contains("[REDACTED]"), transportMessage)
        assertNoSecrets(transportMessage)
        let offlineCount = await offline.requests.count
        XCTAssertEqual(offlineCount, 1)
    }

    // MARK: Explicit tokens

    func testExplicitTokenWinsAndIsNeverReplacedAfter401() async throws {
        let store = InMemoryTokenStore()
        let ok = ScriptedHTTPTransport([.json(200)])
        _ = try await client(tokenConfiguration, ok, store: store).request(path: "/v2/users/me")
        let okRequests = await ok.requests
        XCTAssertEqual(okRequests.map { $0.headers["Authorization"] }, ["Bearer explicit-token-ZZZ"])

        let rejected = ScriptedHTTPTransport([.json(401, #"{"message":"Bad token explicit-token-ZZZ"}"#)])
        let error = await scoutError { try await self.client(self.tokenConfiguration, rejected, store: store).request(path: "/v2/users/me") }
        guard case .api(401, let message)? = error else { return XCTFail("Unexpected \(String(describing: error))") }
        XCTAssertTrue(message.contains("SCOUT_ACCESS_TOKEN"), message)
        XCTAssertTrue(message.contains("does not fall back"), message)
        assertNoSecrets(message)
        let rejectedCount = await rejected.requests.count
        XCTAssertEqual(rejectedCount, 1)
        let saveCount = await store.saveCount
        let removeCount = await store.removeCount
        XCTAssertEqual(saveCount, 0)
        XCTAssertEqual(removeCount, 0)
    }

    func testMissingCredentialsIdentifyConfigurationSource() async {
        let transport = ScriptedHTTPTransport([])
        let configuration = ScoutConfiguration(appID: appID, sourceDescription: "/fixture/dir/.env")
        let error = await scoutError { try await self.client(configuration, transport).request(path: "/v2/users/me") }
        guard case .configuration(let message)? = error else { return XCTFail("Unexpected \(String(describing: error))") }
        XCTAssertTrue(message.contains("SCOUT_APP_SECRET"), message)
        XCTAssertTrue(message.contains("/fixture/dir/.env"), message)
        XCTAssertTrue(message.contains("--env-file"), message)
        let requestCount = await transport.requests.count
        XCTAssertEqual(requestCount, 0)
    }

    // MARK: Writes and failures

    func testWriteServerErrorIsNotReplayed() async {
        let transport = ScriptedHTTPTransport([.json(500), .json(201)])
        let error = await scoutError {
            try await self.client(self.tokenConfiguration, transport).request(method: "POST", path: "/v2/conversations/5/reply", body: .object([:]))
        }
        guard case .api(500, let message)? = error else { return XCTFail("Unexpected \(String(describing: error))") }
        XCTAssertTrue(message.contains("may have succeeded"), message)
        let requestCount = await transport.requests.count
        XCTAssertEqual(requestCount, 1)
    }

    func testTransportFailureIsRedactedAndNotReplayed() async {
        let lost = URLError(.networkConnectionLost, userInfo: [NSLocalizedDescriptionKey: "connection lost for explicit-token-ZZZ"])
        let post = ScriptedHTTPTransport([.failure(lost), .json(201)])
        let error = await scoutError {
            try await self.client(self.tokenConfiguration, post).request(method: "POST", path: "/v2/conversations/5/reply", body: .object([:]))
        }
        guard case .transport(let message)? = error else { return XCTFail("Unexpected \(String(describing: error))") }
        XCTAssertTrue(message.contains("POST /v2/conversations/5/reply"), message)
        XCTAssertTrue(message.contains("inspect the conversation before retrying"), message)
        assertNoSecrets(message)
        let postCount = await post.requests.count
        XCTAssertEqual(postCount, 1)

        let get = ScriptedHTTPTransport([.failure(URLError(.notConnectedToInternet))])
        let getError = await scoutError { try await self.client(self.tokenConfiguration, get).request(path: "/v2/mailboxes") }
        guard case .transport(let getMessage)? = getError else { return XCTFail("Unexpected \(String(describing: getError))") }
        XCTAssertFalse(getMessage.contains("inspect the conversation"), getMessage)
    }

    func testRateLimitReportsRetryDelayWithoutRetrying() async {
        let transport = ScriptedHTTPTransport([.json(429, headers: ["x-ratelimit-retry-after": "17"]), .json(200)])
        let error = await scoutError { try await self.client(self.tokenConfiguration, transport).request(path: "/v2/mailboxes") }
        guard case .api(429, let message)? = error else { return XCTFail("Unexpected \(String(describing: error))") }
        XCTAssertTrue(message.contains("17 seconds"), message)
        XCTAssertTrue(message.contains("did not retry"), message)
        let requestCount = await transport.requests.count
        XCTAssertEqual(requestCount, 1)
    }

    func testPermissionNotFoundAndLockedErrorsAreActionable() async {
        let cases: [(Int, String, String)] = [
            (403, "/v3/customers", "Contacts and Companies"),
            (404, "/v2/conversations/5/reply", "merged or deleted"),
            (412, "/v2/conversations/5/reply", "thread limit"),
        ]
        for (status, path, expected) in cases {
            let transport = ScriptedHTTPTransport([.json(status)])
            let error = await scoutError {
                try await self.client(self.tokenConfiguration, transport).request(method: "POST", path: path, body: .object([:]))
            }
            guard case .api(status, let message)? = error else { return XCTFail("Unexpected \(String(describing: error))") }
            XCTAssertTrue(message.contains(expected), message)
            XCTAssertTrue(message.contains("POST \(path)"), message)
        }
    }

    func testServerErrorDetailsAreRedactedAndOmitQueryAndRejectedValues() async {
        let body = #"""
        {"logRef":"log-42","message":"Bad request","_embedded":{"errors":[
          {"path":"status","message":"invalid for explicit-token-ZZZ","rejectedValue":"CUSTOMER TEXT","source":"JSON"}
        ]}}
        """#
        let transport = ScriptedHTTPTransport([.json(400, body)])
        let error = await scoutError {
            try await self.client(self.tokenConfiguration, transport)
                .request(path: "/v3/conversations", query: ["query": #"email:"jane+x@example.com""#])
        }
        guard case .api(400, let message)? = error else { return XCTFail("Unexpected \(String(describing: error))") }
        XCTAssertTrue(message.contains("GET /v3/conversations."), message)
        XCTAssertTrue(message.contains("Bad request; status: invalid for [REDACTED]; logRef log-42"), message)
        XCTAssertFalse(message.contains("jane"), message)
        XCTAssertFalse(message.contains("CUSTOMER TEXT"), message)
        assertNoSecrets(message)
    }

    // MARK: Requests

    func testQueryEncodingPreservesPlusAndJSONBodies() async throws {
        let transport = ScriptedHTTPTransport([.json(200), .json(204, "")])
        let client = client(tokenConfiguration, transport)

        _ = try await client.request(path: "/v3/conversations", query: ["status": "all", "query": #"email:"jane+x@example.com""#])
        let response = try await client.request(
            method: "post", path: "/v2/conversations/5/reply", body: .object(["text": .string("<p>Hi</p>"), "draft": .bool(true)])
        )

        XCTAssertEqual(response, HTTPResponse(statusCode: 204))
        let requests = await transport.requests
        XCTAssertEqual(
            requests[0].url.absoluteString,
            "https://api.helpscout.net/v3/conversations?query=email%3A%22jane%2Bx%40example.com%22&status=all"
        )
        XCTAssertEqual(requests[0].headers["Accept"], "application/json")
        XCTAssertNil(requests[0].headers["Content-Type"])
        XCTAssertEqual(requests[1].method, "POST")
        XCTAssertEqual(requests[1].headers["Content-Type"], "application/json; charset=UTF-8")
        XCTAssertEqual(String(decoding: requests[1].body ?? Data(), as: UTF8.self), #"{"draft":true,"text":"<p>Hi</p>"}"#)
    }

    func testRejectsInvalidPathsAndMethodsBeforeSending() async {
        let transport = ScriptedHTTPTransport([])
        let client = client(tokenConfiguration, transport)
        for path in ["/v1/users/me", "v2/users/me", "/v2/../v1", "/v2/users/me?x=1", "/v2//users", "/v2/", "/v3/a%2Fb", "https://evil.example/v2/x"] {
            let error = await scoutError { try await client.request(path: path) }
            guard case .invalidInput? = error else { return XCTFail("\(path): unexpected \(String(describing: error))") }
        }
        let error = await scoutError { try await client.request(method: "TRACE", path: "/v2/users/me") }
        guard case .invalidInput? = error else { return XCTFail("Unexpected \(String(describing: error))") }
        let requestCount = await transport.requests.count
        XCTAssertEqual(requestCount, 0)
    }

    // MARK: Redirects

    func testTrustedConversationRedirectReportsMergeTarget() async {
        let cases: [(String, String, Int)] = [
            ("/v2/conversations/1", "https://api.helpscout.net/v2/conversations/2", 2),
            ("/v3/conversations/1", "/v3/conversations/3", 3),
            ("/v2/conversations/1", "https://API.helpscout.net:443/v2/conversations/4", 4),
            ("/v3/conversations/1/threads", "https://api.helpscout.net/v3/conversations/5/threads", 5),
        ]
        for (path, location, expected) in cases {
            let transport = ScriptedHTTPTransport([.json(301, "", headers: ["location": location]), .json(200)])
            let error = await scoutError { try await self.client(self.tokenConfiguration, transport).request(path: path) }
            XCTAssertEqual(error, .merged(expected), location)
            let requestCount = await transport.requests.count
            XCTAssertEqual(requestCount, 1, location)
        }
    }

    func testUntrustedRedirectsAreRejectedWithoutFollowing() async {
        let cases: [(String, String, Int, String)] = [
            ("GET", "/v2/conversations/1", 301, "http://api.helpscout.net/v2/conversations/2"),
            ("GET", "/v2/conversations/1", 301, "https://api.helpscout.net.evil.example/v2/conversations/2"),
            ("GET", "/v2/conversations/1", 301, "//evil.example/v2/conversations/2"),
            ("GET", "/v2/conversations/1", 301, "https://api.helpscout.net:8443/v2/conversations/2"),
            ("GET", "/v2/conversations/1", 301, "https://user@api.helpscout.net/v2/conversations/2"),
            ("GET", "/v2/conversations/1", 301, "https://api.helpscout.net/v2/conversations/abc"),
            ("GET", "/v2/conversations/1", 301, "https://api.helpscout.net/v2/customers/2"),
            ("GET", "/v2/conversations/1", 301, "https://api.helpscout.net/v1/conversations/2"),
            ("GET", "/v2/conversations/1", 301, "/v2/conversations/1"),
            ("GET", "/v2/conversations/1", 301, "/v2/conversations/../customers/2"),
            ("GET", "/v2/mailboxes", 301, "/v2/conversations/2"),
            ("GET", "/v2/conversations/1", 302, "/v2/conversations/2"),
            ("POST", "/v2/conversations/1/reply", 301, "/v2/conversations/2/reply"),
        ]
        for (method, path, status, location) in cases {
            let transport = ScriptedHTTPTransport([.json(status, "", headers: ["Location": location]), .json(200)])
            let error = await scoutError {
                try await self.client(self.tokenConfiguration, transport).request(method: method, path: path)
            }
            guard case .api(status, let message)? = error else {
                XCTFail("\(location): unexpected \(String(describing: error))")
                continue
            }
            XCTAssertTrue(message.contains("does not follow"), message)
            let requestCount = await transport.requests.count
            XCTAssertEqual(requestCount, 1, location)
        }
    }

    // MARK: Helpers

    private func scoutError(
        _ operation: () async throws -> HTTPResponse,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> ScoutError? {
        do {
            _ = try await operation()
            XCTFail("Expected an error", file: file, line: line)
        } catch let error as ScoutError {
            return error
        } catch {
            XCTFail("Unexpected error \(error)", file: file, line: line)
        }
        return nil
    }

    private func assertNoSecrets(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        let secrets = [
            appSecret, PercentEncoding.encode(appSecret), explicitToken, "stale-token-0", "issued-token-1", "issued-token-2",
        ]
        for secret in secrets {
            XCTAssertFalse(text.contains(secret), "Leaked secret in: \(text)", file: file, line: line)
        }
    }
}
