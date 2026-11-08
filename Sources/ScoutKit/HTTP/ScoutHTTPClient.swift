import Foundation

/// Sends authenticated requests to the Help Scout API and returns successful responses, including empty ones,
/// for the caller to decode. Failures throw `ScoutError` with secrets redacted. Only a 401 with client credentials
/// is retried, once, after renewing the token; nothing else is retried and redirects are never followed.
public actor ScoutHTTPClient {
    public static let baseURL = "https://api.helpscout.net"
    static let apiHost = "api.helpscout.net"
    static let methods: Set<String> = ["GET", "POST", "PUT", "PATCH", "DELETE"]

    let configuration: ScoutConfiguration
    let transport: any HTTPTransport
    let tokenStore: any TokenStore
    let clock: @Sendable () -> Date
    var cachedToken: CachedToken?
    var redactor: SecretRedactor

    public init(configuration: ScoutConfiguration) {
        self.init(
            configuration: configuration,
            transport: URLSessionTransport(),
            tokenStore: FileTokenStore.standard(),
            clock: { Date() }
        )
    }

    public init(
        configuration: ScoutConfiguration,
        transport: any HTTPTransport,
        tokenStore: any TokenStore,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.configuration = configuration
        self.transport = transport
        self.tokenStore = tokenStore
        self.clock = clock
        redactor = SecretRedactor([configuration.appSecret, configuration.accessToken])
    }

    /// `path` must start with `/v2/` or `/v3/` and contain no query; pass query items separately.
    public func request(
        method: String = "GET",
        path: String,
        query: [String: String] = [:],
        body: JSONValue? = nil
    ) async throws -> HTTPResponse {
        let method = method.uppercased()
        guard Self.methods.contains(method) else {
            throw ScoutError.invalidInput("Unsupported HTTP method \(method).")
        }
        let url = try Self.makeURL(path: path, query: query)
        let bodyData = try body.map(Self.encode)
        let authentication = try configuration.authentication()

        var token = try await accessToken(for: authentication)
        var response = try await send(method: method, url: url, path: path, body: bodyData, token: token)
        if response.statusCode == 401, case .clientCredentials(let appID, let appSecret) = authentication {
            // A 401 is a definite rejection, so one replay with a renewed token cannot duplicate a write.
            try await discardToken(token)
            token = try await exchangeToken(appID: appID, appSecret: appSecret)
            response = try await send(method: method, url: url, path: path, body: bodyData, token: token)
            if response.statusCode == 401 { try await discardToken(token) }
        }

        if (200..<300).contains(response.statusCode) { return response }
        if response.statusCode == 301, method == "GET",
            let id = HTTPFailure.mergedConversationID(location: response.header("Location"), requestURL: url, path: path) {
            throw ScoutError.merged(id)
        }
        let message = HTTPFailure.message(
            for: response,
            method: method,
            path: path,
            authentication: authentication,
            sourceDescription: configuration.sourceDescription,
            redactor: redactor
        )
        throw ScoutError.api(status: response.statusCode, message: redactor.redact(message))
    }

    private func send(method: String, url: URL, path: String, body: Data?, token: String) async throws -> HTTPResponse {
        var headers = ["Accept": "application/json", "Authorization": "Bearer \(token)"]
        if body != nil { headers["Content-Type"] = "application/json; charset=UTF-8" }
        do {
            return try await transport.send(HTTPRequest(method: method, url: url, headers: headers, body: body))
        } catch {
            var message = "Network request failed for \(method) \(path): \(error.localizedDescription)"
            if method != "GET" {
                message += " The request may have reached Help Scout; inspect \(HTTPFailure.writeTarget(path)) before retrying."
            }
            throw ScoutError.transport(redactor.redact(message))
        }
    }

    static func makeURL(path: String, query: [String: String]) throws -> URL {
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        guard segments.count >= 3, segments[0].isEmpty, segments[1] == "v2" || segments[1] == "v3",
            segments.dropFirst(2).allSatisfy(HTTPFailure.isPlainSegment)
        else {
            throw ScoutError.invalidInput(
                "Invalid Help Scout API path \(path); it must start with /v2/ or /v3/ and have no query string."
            )
        }
        var text = baseURL + path
        if !query.isEmpty {
            text += "?" + PercentEncoding.form(query.sorted { $0.key < $1.key }.map { ($0.key, $0.value) })
        }
        guard let url = URL(string: text) else {
            throw ScoutError.invalidInput("Could not build a URL for \(path).")
        }
        return url
    }

    private static func encode(_ body: JSONValue) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            return try encoder.encode(body)
        } catch {
            throw ScoutError.invalidInput("The request body could not be encoded as JSON.")
        }
    }
}
