import Foundation

public struct HTTPRequest: Sendable, Equatable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data?

    public init(method: String, url: URL, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

public struct HTTPResponse: Sendable, Equatable {
    public var statusCode: Int
    public var headers: [String: String]
    public var body: Data

    public init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    /// Looks up a header ignoring case, as HTTP header names are case-insensitive.
    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

// Headers carry tokens and bodies carry secrets or customer text, so descriptions show neither.
extension HTTPRequest: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "HTTPRequest(\(method) \(url.path), headers: \(headers.keys.sorted()), body: \(body?.count ?? 0) bytes)"
    }
    public var debugDescription: String { description }
}

extension HTTPResponse: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "HTTPResponse(\(statusCode), headers: \(headers.keys.sorted()), body: \(body.count) bytes)"
    }
    public var debugDescription: String { description }
}

public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

/// Production transport: an ephemeral session without caching or cookies that returns redirects to the caller
/// instead of following them.
public final class URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public convenience init() {
        self.init(configuration: .ephemeral)
    }

    init(configuration: URLSessionConfiguration) {
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        session = URLSession(configuration: configuration, delegate: RedirectRefusingDelegate(), delegateQueue: nil)
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        var headers: [String: String] = [:]
        for (name, value) in http.allHeaderFields {
            if let name = name as? String { headers[name] = "\(value)" }
        }
        return HTTPResponse(statusCode: http.statusCode, headers: headers, body: data)
    }
}

private final class RedirectRefusingDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}
