import Foundation
@testable import ScoutKit

/// Returns scripted replies in order and records every request. Running out of replies fails the request, so
/// tests can assert that nothing was replayed.
actor ScriptedHTTPTransport: HTTPTransport {
    enum Reply: Sendable {
        case response(HTTPResponse)
        case failure(URLError)

        static func json(_ status: Int, _ text: String = "{}", headers: [String: String] = [:]) -> Reply {
            .response(HTTPResponse(statusCode: status, headers: headers, body: Data(text.utf8)))
        }

        static func token(_ value: String, expiresIn: Int = 172_800) -> Reply {
            json(200, #"{"token_type":"bearer","access_token":"\#(value)","expires_in":\#(expiresIn)}"#)
        }
    }

    private var replies: [Reply]
    private(set) var requests: [HTTPRequest] = []

    init(_ replies: [Reply]) {
        self.replies = replies
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        guard !replies.isEmpty else { throw URLError(.resourceUnavailable) }
        switch replies.removeFirst() {
        case .response(let response): return response
        case .failure(let error): throw error
        }
    }
}

actor InMemoryTokenStore: TokenStore {
    private(set) var token: CachedToken?
    private(set) var saveCount = 0
    private(set) var removeCount = 0

    init(_ token: CachedToken? = nil) {
        self.token = token
    }

    func load() -> CachedToken? { token }

    func save(_ token: CachedToken) {
        self.token = token
        saveCount += 1
    }

    func remove() {
        token = nil
        removeCount += 1
    }
}

final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        current = start
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        current = current.addingTimeInterval(seconds)
    }
}
