import Foundation

/// Single-account settings from one env file plus nonempty process environment values.
/// Loading never requires credentials, so commands can validate their arguments first.
public struct ScoutConfiguration: Sendable, Equatable {
    public static let appIDKey = "SCOUT_APP_ID"
    public static let appSecretKey = "SCOUT_APP_SECRET"
    public static let accessTokenKey = "SCOUT_ACCESS_TOKEN"
    public static let inboxIDKey = "SCOUT_INBOX_ID"
    static let keys: Set<String> = [appIDKey, appSecretKey, accessTokenKey, inboxIDKey]

    public var appID: String?
    public var appSecret: String?
    public var accessToken: String?
    public var inboxID: Int?
    /// Where the settings came from, for actionable errors. Never contains setting values.
    public var sourceDescription: String

    public init(
        appID: String? = nil,
        appSecret: String? = nil,
        accessToken: String? = nil,
        inboxID: Int? = nil,
        sourceDescription: String = "explicit configuration"
    ) {
        self.appID = appID
        self.appSecret = appSecret
        self.accessToken = accessToken
        self.inboxID = inboxID
        self.sourceDescription = sourceDescription
    }

    /// Reads `envFile` when given (relative paths resolve against `startingDirectory`), otherwise the nearest
    /// `.env` found searching upward from `startingDirectory`. Discovery stops at the first file found.
    public static func load(
        envFile: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        startingDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ) throws -> ScoutConfiguration {
        try load(envFile: envFile, environment: environment, startingDirectory: startingDirectory, searchBoundary: nil)
    }

    /// `searchBoundary` is the last directory discovery checks; tests use it so discovery never leaves fixtures.
    static func load(
        envFile: String?,
        environment: [String: String],
        startingDirectory: URL,
        searchBoundary: URL?
    ) throws -> ScoutConfiguration {
        let start = startingDirectory.standardizedFileURL
        let file: URL?
        if let envFile {
            file = try explicitFile(envFile, relativeTo: start)
        } else {
            file = discoverFile(from: start, boundary: searchBoundary?.standardizedFileURL)
        }

        var settings: [String: Setting] = [:]
        if let file {
            for (key, entry) in try DotEnvParser.parse(readText(file), keys: keys, source: file.path) {
                settings[key] = Setting(value: entry.value, location: "\(file.path) line \(entry.line)")
            }
        }
        for key in keys {
            if let value = environment[key], !value.isEmpty {
                settings[key] = Setting(value: value, location: "the process environment")
            }
        }

        let source = file.map { "\($0.path) (nonempty process environment values override it)" }
            ?? "the process environment only (no .env file found in \(start.path) or its parent directories)"
        return ScoutConfiguration(
            appID: try credential(appIDKey, settings),
            appSecret: try credential(appSecretKey, settings),
            accessToken: try credential(accessTokenKey, settings),
            inboxID: try inboxID(settings),
            sourceDescription: source
        )
    }

    /// Credentials and tokens are sent in headers and form bodies, so only visible ASCII is accepted.
    static func isPlainCredential(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (0x21...0x7E).contains($0) }
    }

    private struct Setting {
        var value: String
        var location: String
    }

    private static func credential(_ key: String, _ settings: [String: Setting]) throws -> String? {
        guard let setting = settings[key], !setting.value.isEmpty else { return nil }
        guard isPlainCredential(setting.value) else {
            throw ScoutError.configuration(
                "\(key) from \(setting.location) contains whitespace or non-ASCII characters. The value is not shown."
            )
        }
        return setting.value
    }

    private static func inboxID(_ settings: [String: Setting]) throws -> Int? {
        guard let setting = settings[inboxIDKey], !setting.value.isEmpty else { return nil }
        guard setting.value.utf8.allSatisfy({ (0x30...0x39).contains($0) }), let id = Int(setting.value), id > 0 else {
            throw ScoutError.configuration(
                "\(inboxIDKey) from \(setting.location) must be a positive Help Scout inbox ID. The value is not shown."
            )
        }
        return id
    }

    private static func explicitFile(_ path: String, relativeTo start: URL) throws -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        let url = (expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : start.appendingPathComponent(expanded))
            .standardizedFileURL
        guard isRegularFile(url) else {
            throw ScoutError.configuration("Env file not found: \(url.path)")
        }
        return url
    }

    private static func discoverFile(from start: URL, boundary: URL?) -> URL? {
        var directory = start
        while true {
            let candidate = directory.appendingPathComponent(".env")
            if isRegularFile(candidate) { return candidate }
            let parent = directory.deletingLastPathComponent().standardizedFileURL
            if directory.path == boundary?.path || directory.path == "/" || parent.path == directory.path { return nil }
            directory = parent
        }
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    private static func readText(_ file: URL) throws -> String {
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch {
            throw ScoutError.configuration("Cannot read env file \(file.path): \(error.localizedDescription)")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw ScoutError.configuration("Env file \(file.path) is not valid UTF-8 text.")
        }
        return text
    }
}

extension ScoutConfiguration: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        func state(_ value: String?) -> String { value?.isEmpty == false ? "set" : "unset" }
        return "ScoutConfiguration(appID: \(state(appID)), appSecret: \(state(appSecret)), "
            + "accessToken: \(state(accessToken)), inboxID: \(inboxID.map(String.init) ?? "unset"), "
            + "source: \(sourceDescription))"
    }

    public var debugDescription: String { description }
}
