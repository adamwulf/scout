import Foundation

extension ScoutHTTPClient {
    static let tokenPath = "/v2/oauth2/token"
    /// Renew slightly early so a token does not lapse while a request is in flight.
    static let expiryMargin: TimeInterval = 60

    /// Explicit tokens are used as given. Client-credential tokens come from memory, then the store when they
    /// belong to the configured app and have not expired, and otherwise from a new exchange.
    func accessToken(for authentication: Authentication) async throws -> String {
        switch authentication {
        case .accessToken(let token):
            return token
        case .clientCredentials(let appID, let appSecret):
            if let cachedToken, isUsable(cachedToken, appID: appID) { return cachedToken.accessToken }
            if let stored = try await tokenStore.load(), isUsable(stored, appID: appID) {
                redactor.insert(stored.accessToken)
                cachedToken = stored
                return stored.accessToken
            }
            return try await exchangeToken(appID: appID, appSecret: appSecret)
        }
    }

    /// Client-credentials grant sent as a form body, never a query string.
    func exchangeToken(appID: String, appSecret: String) async throws -> String {
        let form = PercentEncoding.form([
            ("grant_type", "client_credentials"), ("client_id", appID), ("client_secret", appSecret),
        ])
        let request = HTTPRequest(
            method: "POST",
            url: try Self.makeURL(path: Self.tokenPath, query: [:]),
            headers: ["Accept": "application/json", "Content-Type": "application/x-www-form-urlencoded"],
            body: Data(form.utf8)
        )
        let response: HTTPResponse
        do {
            response = try await transport.send(request)
        } catch {
            throw ScoutError.transport(
                redactor.redact("Could not reach Help Scout to obtain an access token: \(error.localizedDescription)")
            )
        }
        guard (200..<300).contains(response.statusCode) else {
            let message = HTTPFailure.tokenMessage(for: response, sourceDescription: configuration.sourceDescription)
            throw ScoutError.api(status: response.statusCode, message: redactor.redact(message))
        }
        guard let issued = try? JSONDecoder().decode(TokenResponse.self, from: response.body),
            ScoutConfiguration.isPlainCredential(issued.accessToken), issued.expiresIn > 0
        else {
            throw ScoutError.decoding("Help Scout returned an unusable access token response.")
        }

        redactor.insert(issued.accessToken)
        let token = CachedToken(
            appID: appID,
            accessToken: issued.accessToken,
            expiresAt: clock().addingTimeInterval(TimeInterval(issued.expiresIn))
        )
        cachedToken = token
        try await tokenStore.save(token)
        return token.accessToken
    }

    /// Forgets a rejected token in memory and in the store, leaving any newer token alone.
    func discardToken(_ rejected: String) async throws {
        if cachedToken?.accessToken == rejected { cachedToken = nil }
        if let stored = try await tokenStore.load(), stored.accessToken == rejected {
            try await tokenStore.remove()
        }
    }

    private func isUsable(_ token: CachedToken, appID: String) -> Bool {
        token.appID == appID && clock() < token.expiresAt.addingTimeInterval(-Self.expiryMargin)
    }
}

private struct TokenResponse: Decodable {
    let accessToken: String
    let expiresIn: Int

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
    }
}
