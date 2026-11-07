import Foundation

/// Replaces every known secret, raw or percent-encoded, before text leaves the client in an error.
struct SecretRedactor: Sendable {
    private(set) var secrets: Set<String> = []

    init(_ values: [String?]) {
        for value in values { if let value { insert(value) } }
    }

    mutating func insert(_ secret: String) {
        if !secret.isEmpty { secrets.insert(secret) }
    }

    func redact(_ text: String) -> String {
        var result = text
        for secret in secrets.sorted(by: { $0.count > $1.count }) {
            for form in Set([secret, PercentEncoding.encode(secret)]) {
                result = result.replacingOccurrences(of: form, with: "[REDACTED]")
            }
        }
        return result
    }
}

/// Builds actionable error text for unsuccessful responses. Messages name the method and path but never the query
/// string, response body, or rejected values; server-provided messages are redacted and shortened.
enum HTTPFailure {
    static func message(
        for response: HTTPResponse,
        method: String,
        path: String,
        authentication: Authentication,
        sourceDescription: String,
        redactor: SecretRedactor
    ) -> String {
        let endpoint = "\(method) \(path)"
        let summary: String
        switch response.statusCode {
        case 300..<400:
            return "\(endpoint) returned a redirect that Scout does not follow."
        case 401:
            switch authentication {
            case .accessToken:
                summary = "Help Scout rejected \(ScoutConfiguration.accessTokenKey) for \(endpoint). "
                    + "Update or unset \(ScoutConfiguration.accessTokenKey) (settings from \(sourceDescription)); "
                    + "Scout does not fall back to app credentials while an access token is set. "
                    + "The token's user must be active and invited in Help Scout."
            case .clientCredentials:
                summary = "Help Scout rejected \(endpoint) even with a newly issued access token. "
                    + "The app owner must be an active, invited user in the Help Scout account; "
                    + "renewing the token cannot fix an inactive owner."
            }
        case 403:
            summary = "Help Scout denied permission for \(endpoint). The user behind these credentials needs access "
                + "to this inbox or resource; customer lookups also need the Contacts and Companies permission."
        case 404:
            summary = "Help Scout could not find \(endpoint)."
                + (conversationID(inPath: path) == nil
                    ? "" : " The conversation may have been merged or deleted; check its ID in Help Scout.")
        case 412:
            summary = "Help Scout refused \(endpoint) because the conversation is locked: it reached its thread "
                + "limit or a company locking policy applies."
        case 429:
            summary = "Help Scout's rate limit was reached for \(endpoint). \(retryHint(response))"
        case 500...:
            summary = "Help Scout had a server error for \(endpoint)."
                + (method == "GET"
                    ? " Try again shortly."
                    : " The write may have succeeded; inspect the conversation before retrying.")
        default:
            summary = "Help Scout rejected \(endpoint)."
        }
        guard let detail = serverDetail(response.body, redactor: redactor) else { return summary }
        return "\(summary) Help Scout said: \(detail)"
    }

    /// The raw OAuth response is never shown; only a plain OAuth error code such as `invalid_client`.
    static func tokenMessage(for response: HTTPResponse, sourceDescription: String) -> String {
        switch response.statusCode {
        case 400, 401:
            let code = oauthErrorCode(response.body).map { " (\($0))" } ?? ""
            return "Help Scout rejected the app credentials\(code). Check \(ScoutConfiguration.appIDKey) and "
                + "\(ScoutConfiguration.appSecretKey) (settings from \(sourceDescription)); the app owner must be "
                + "an active, invited Help Scout user."
        case 300..<400:
            return "The Help Scout token request returned a redirect that Scout does not follow."
        case 429:
            return "Help Scout's rate limit was reached while obtaining an access token. \(retryHint(response))"
        default:
            return "Help Scout could not issue an access token."
        }
    }

    static func retryHint(_ response: HTTPResponse) -> String {
        if let raw = response.header("X-RateLimit-Retry-After")?.trimmingCharacters(in: .whitespaces),
            let seconds = Int(raw), seconds >= 0 {
            return "Scout did not retry; try again after \(seconds) seconds."
        }
        return "Scout did not retry; wait a minute before trying again."
    }

    /// A 301 for a GET of a conversation reports a merge only when `Location` resolves to an HTTPS conversation
    /// on the exact API host and default port. Anything else is treated as an unexpected redirect.
    static func mergedConversationID(location: String?, requestURL: URL, path: String) -> Int? {
        guard let originalID = conversationID(inPath: path),
            let location,
            let target = URL(string: location, relativeTo: requestURL)?.absoluteURL,
            target.scheme?.lowercased() == "https",
            target.host()?.lowercased() == ScoutHTTPClient.apiHost,
            target.port == nil || target.port == 443,
            target.user() == nil, target.password() == nil,
            let id = conversationID(inPath: target.path(percentEncoded: true)),
            id != originalID
        else { return nil }
        return id
    }

    /// Matches `/v2|v3/conversations/{positive id}` optionally followed by plain path segments.
    static func conversationID(inPath path: String) -> Int? {
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        guard segments.count >= 4, segments[0].isEmpty, segments[1] == "v2" || segments[1] == "v3",
            segments[2] == "conversations",
            segments[3].utf8.allSatisfy({ (0x30...0x39).contains($0) }),
            let id = Int(segments[3]), id > 0,
            segments.dropFirst(4).allSatisfy(isPlainSegment)
        else { return nil }
        return id
    }

    static func isPlainSegment(_ segment: Substring) -> Bool {
        !segment.isEmpty && segment != "." && segment != ".." && segment.utf8.allSatisfy(PercentEncoding.isUnreserved)
    }

    /// Help Scout error JSON: `message`, `_embedded.errors[].path/message` and `logRef`. Rejected values are
    /// skipped because they can contain customer text.
    static func serverDetail(_ body: Data, redactor: SecretRedactor) -> String? {
        guard !body.isEmpty, let json = try? JSONDecoder().decode(JSONValue.self, from: body), json.object != nil
        else { return nil }
        var parts: [String] = []
        if let message = json["message"].string, !message.isEmpty { parts.append(message) }
        for error in json["_embedded"]["errors"].array ?? [] {
            guard let message = error["message"].string, !message.isEmpty else { continue }
            if let field = error["path"].string, !field.isEmpty {
                parts.append("\(field): \(message)")
            } else {
                parts.append(message)
            }
        }
        if let logRef = json["logRef"].string, !logRef.isEmpty { parts.append("logRef \(logRef)") }
        guard !parts.isEmpty else { return nil }

        // Redact before shortening so a truncated secret cannot slip through.
        let detail = String(redactor.redact(parts.joined(separator: "; ")).unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) ? " " : Character($0)
        })
        return detail.count > 400 ? String(detail.prefix(400)) + "…" : detail
    }

    private static func oauthErrorCode(_ body: Data) -> String? {
        guard let code = (try? JSONDecoder().decode(JSONValue.self, from: body))?["error"].string,
            (1...64).contains(code.count),
            code.utf8.allSatisfy({ (0x61...0x7A).contains($0) || $0 == UInt8(ascii: "_") })
        else { return nil }
        return code
    }
}
