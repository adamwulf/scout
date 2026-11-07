import Foundation

/// How a client authenticates. An access token from either the env file or the process environment wins and is
/// never replaced by app credentials.
enum Authentication: Sendable, Equatable {
    case accessToken(String)
    case clientCredentials(appID: String, appSecret: String)
}

extension ScoutConfiguration {
    func authentication() throws -> Authentication {
        func present(_ value: String?) -> String? { value?.isEmpty == false ? value : nil }
        if let token = present(accessToken) { return .accessToken(token) }

        let missing: String
        switch (present(appID), present(appSecret)) {
        case let (appID?, appSecret?): return .clientCredentials(appID: appID, appSecret: appSecret)
        case (nil, nil): missing = "\(Self.appIDKey) and \(Self.appSecretKey) (or \(Self.accessTokenKey))"
        case (nil, _?): missing = Self.appIDKey
        case (_?, nil): missing = Self.appSecretKey
        }
        throw ScoutError.configuration(
            "Missing Help Scout credentials: set \(missing). Settings were loaded from \(sourceDescription). "
                + "Add them there or to the environment, or pass --env-file PATH."
        )
    }
}
