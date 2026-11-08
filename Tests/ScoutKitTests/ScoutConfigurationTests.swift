import Foundation
import XCTest
@testable import ScoutKit

/// Every fixture lives in a fresh temporary directory, and discovery is bounded to it, so no real env file is read.
final class ScoutConfigurationTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("scout-config-tests-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func write(_ text: String, to relativePath: String) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func directory(_ relativePath: String) throws -> URL {
        let url = root.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func load(
        envFile: String? = nil,
        environment: [String: String] = [:],
        from start: URL
    ) throws -> ScoutConfiguration {
        try ScoutConfiguration.load(envFile: envFile, environment: environment, startingDirectory: start, searchBoundary: root, discoveryFileName: "scout-fixture.env")
    }

    private func configurationError(_ operation: () throws -> ScoutConfiguration) -> String? {
        do {
            _ = try operation()
            XCTFail("Expected a configuration error")
        } catch ScoutError.configuration(let message) {
            return message
        } catch {
            XCTFail("Unexpected error \(error)")
        }
        return nil
    }

    func testParsesDotEnvSubsetWithoutShellEvaluation() throws {
        let text = "\u{FEFF}# comment\r\n"
            + "export SCOUT_APP_ID=first-id\r\n"
            + "SCOUT_APP_ID = 'single $HOME # kept' # trailing comment\n"
            + #"SCOUT_APP_SECRET="dq \"quoted\" \\ $(whoami) #kept"   # comment"# + "\n"
            + "SCOUT_ACCESS_TOKEN=plain#hash-kept # comment\n"
            + "SCOUT_INBOX_ID=\n"
            + "OTHER_TOOL_SETTING=\"unterminated\n"
            + "this line belongs to another tool\n"
            + "exporter=ignored\n"
        let entries = try DotEnvParser.parse(text, keys: ScoutConfiguration.keys, source: "fixture.env")

        XCTAssertEqual(entries["SCOUT_APP_ID"], .init(value: "single $HOME # kept", line: 3))
        XCTAssertEqual(entries["SCOUT_APP_SECRET"], .init(value: #"dq "quoted" \ $(whoami) #kept"#, line: 4))
        XCTAssertEqual(entries["SCOUT_ACCESS_TOKEN"], .init(value: "plain#hash-kept", line: 5))
        XCTAssertEqual(entries["SCOUT_INBOX_ID"], .init(value: "", line: 6))
        XCTAssertEqual(entries.count, 4)
    }

    func testCommentAfterBlankFollowingEqualsLeavesValueEmpty() throws {
        let text = "SCOUT_ACCESS_TOKEN= # optional\n"
            + "SCOUT_APP_SECRET=\t# optional\n"
            + "SCOUT_APP_ID=#literal\n"
        let entries = try DotEnvParser.parse(text, keys: ScoutConfiguration.keys, source: "fixture.env")
        XCTAssertEqual(entries["SCOUT_ACCESS_TOKEN"]?.value, "")
        XCTAssertEqual(entries["SCOUT_APP_SECRET"]?.value, "")
        XCTAssertEqual(entries["SCOUT_APP_ID"]?.value, "#literal")

        let file = try write("SCOUT_APP_ID=file-id\nSCOUT_APP_SECRET=file-secret\nSCOUT_ACCESS_TOKEN= # optional\n", to: "a/scout-fixture.env")
        let configuration = try load(from: file.deletingLastPathComponent())
        XCTAssertNil(configuration.accessToken)
        XCTAssertEqual(try configuration.authentication(), .clientCredentials(appID: "file-id", appSecret: "file-secret"))
    }

    func testMalformedRelevantSettingsAreRejectedWithoutShowingValues() throws {
        let start = try directory("project")
        let cases = [
            ("SCOUT_APP_SECRET=\"hidden-value\n", "line 1 is malformed"),
            ("SCOUT_APP_SECRET='hidden-value' trailing\n", "line 1 is malformed"),
            ("\nSCOUT_APP_SECRET hidden-value\n", "line 2 is malformed"),
            ("SCOUT_APP_SECRET=hidden value\n", "whitespace or non-ASCII"),
            ("SCOUT_INBOX_ID=hidden-value\n", "positive Help Scout inbox ID"),
            ("SCOUT_INBOX_ID=-5\n", "positive Help Scout inbox ID"),
        ]
        for (text, expected) in cases {
            let file = try write(text, to: "project/scout-fixture.env")
            let message = configurationError { try load(from: start) }
            XCTAssertEqual(message?.contains(expected), true, message ?? text)
            XCTAssertEqual(message?.contains(file.path), true, message ?? text)
            XCTAssertEqual(message?.contains("hidden"), false, message ?? text)
        }

        try FileManager.default.removeItem(at: start.appendingPathComponent("scout-fixture.env"))
        let message = configurationError { try load(environment: ["SCOUT_ACCESS_TOKEN": "hidden token\n"], from: start) }
        XCTAssertEqual(message?.contains("SCOUT_ACCESS_TOKEN from the process environment"), true, message ?? "")
        XCTAssertEqual(message?.contains("hidden"), false, message ?? "")
    }

    func testDiscoveryContinuesUpwardPastFilesWithoutCredentials() throws {
        let outer = try write("SCOUT_APP_ID=outer-id\nSCOUT_APP_SECRET=outer-secret\nSCOUT_INBOX_ID=9\n", to: "scout-fixture.env")
        let nearest = try write("OTHER_TOOL_SETTING=1\nSCOUT_APP_ID=\nSCOUT_INBOX_ID=5\n", to: "project/scout-fixture.env")
        let start = try directory("project/Sources/deep")

        let configuration = try load(from: start)

        XCTAssertEqual(try configuration.authentication(), .clientCredentials(appID: "outer-id", appSecret: "outer-secret"))
        XCTAssertEqual(configuration.inboxID, 5, "the nearer file's value wins")
        XCTAssertEqual(
            configuration.sourceDescription,
            "\(nearest.path), \(outer.path) (nearer files override farther ones; "
                + "nonempty process environment values override them all)"
        )
    }

    func testDiscoveryStopsAtFirstFileWithAnyCredential() throws {
        let outer = try write("SCOUT_ACCESS_TOKEN=outer-token\nSCOUT_INBOX_ID=9\n", to: "scout-fixture.env")
        _ = try write("SCOUT_APP_ID=project-id\nSCOUT_APP_SECRET=project-secret\n", to: "project/scout-fixture.env")
        let start = try directory("project/sub")

        let configuration = try load(from: start)

        XCTAssertEqual(try configuration.authentication(), .clientCredentials(appID: "project-id", appSecret: "project-secret"))
        XCTAssertNil(configuration.accessToken)
        XCTAssertNil(configuration.inboxID)
        XCTAssertFalse(configuration.sourceDescription.contains(outer.path), configuration.sourceDescription)

        // Credentials from the environment also end discovery after the first file.
        _ = try write("OTHER_TOOL_SETTING=1\n", to: "project/sub/scout-fixture.env")
        let fromEnvironment = try load(environment: ["SCOUT_ACCESS_TOKEN": "env-token"], from: start)
        XCTAssertEqual(try fromEnvironment.authentication(), .accessToken("env-token"))
        XCTAssertNil(fromEnvironment.appID)

        // A file with half of the app pair still ends discovery: the pair never mixes files, and the
        // farther secret and access token are not read.
        _ = try write("SCOUT_APP_SECRET=split-secret\n", to: "split/scout-fixture.env")
        let inner = try write("SCOUT_APP_ID=inner-id\n", to: "split/inner/scout-fixture.env")
        let partial = try load(from: try directory("split/inner"))
        XCTAssertEqual(partial.appID, "inner-id")
        XCTAssertNil(partial.appSecret)
        XCTAssertNil(partial.accessToken)
        XCTAssertThrowsError(try partial.authentication()) { error in
            guard case ScoutError.configuration(let message) = error else { return XCTFail("Unexpected \(error)") }
            XCTAssertTrue(message.contains("set SCOUT_APP_SECRET."), message)
            XCTAssertTrue(message.contains("from \(inner.path) (nonempty"), message)
        }
    }

    func testMissingCredentialsErrorNamesEveryFileRead() throws {
        let outer = try write("OTHER_TOOL_SETTING=1\n", to: "scout-fixture.env")
        let nearest = try write("SCOUT_INBOX_ID=5\n", to: "project/scout-fixture.env")

        let configuration = try load(from: try directory("project"))

        XCTAssertThrowsError(try configuration.authentication()) { error in
            guard case ScoutError.configuration(let message) = error else { return XCTFail("Unexpected \(error)") }
            XCTAssertTrue(message.contains("SCOUT_APP_ID and SCOUT_APP_SECRET"), message)
            XCTAssertTrue(message.contains("\(nearest.path), \(outer.path)"), message)
        }
    }

    func testNonemptyEnvironmentValuesOverrideFileValues() throws {
        _ = try write("SCOUT_APP_ID=file-id\nSCOUT_APP_SECRET=file-secret\nSCOUT_INBOX_ID=5\n", to: "project/scout-fixture.env")
        let start = try directory("project")

        let configuration = try load(
            environment: ["SCOUT_APP_ID": "env-id", "SCOUT_APP_SECRET": "", "SCOUT_INBOX_ID": "42", "UNRELATED": "x y"],
            from: start
        )

        XCTAssertEqual(configuration.appID, "env-id")
        XCTAssertEqual(configuration.appSecret, "file-secret")
        XCTAssertEqual(configuration.inboxID, 42)
        XCTAssertNil(configuration.accessToken)
        XCTAssertEqual(try configuration.authentication(), .clientCredentials(appID: "env-id", appSecret: "file-secret"))
    }

    func testAccessTokenFromEitherSourceWinsOverAppCredentials() throws {
        _ = try write("SCOUT_APP_ID=file-id\nSCOUT_APP_SECRET=file-secret\nSCOUT_ACCESS_TOKEN=file-token\n", to: "a/scout-fixture.env")
        let fromFile = try load(from: try directory("a"))
        XCTAssertEqual(try fromFile.authentication(), .accessToken("file-token"))

        _ = try write("SCOUT_APP_ID=file-id\nSCOUT_APP_SECRET=file-secret\n", to: "b/scout-fixture.env")
        let fromEnvironment = try load(environment: ["SCOUT_ACCESS_TOKEN": "env-token"], from: try directory("b"))
        XCTAssertEqual(try fromEnvironment.authentication(), .accessToken("env-token"))
    }

    func testExplicitEnvFileResolvesFromStartingDirectoryAndSkipsDiscovery() throws {
        _ = try write("SCOUT_APP_ID=discovered\nSCOUT_APP_SECRET=discovered-secret\n", to: "elsewhere/scout-fixture.env")
        let file = try write("SCOUT_APP_ID=explicit-id\nSCOUT_APP_SECRET=explicit-secret\n", to: "config/scout-fixture.env")
        let start = try directory("elsewhere")

        let relative = try load(envFile: "../config/scout-fixture.env", from: start)
        XCTAssertEqual(relative.appID, "explicit-id")
        XCTAssertTrue(relative.sourceDescription.contains(file.path), relative.sourceDescription)

        let absolute = try load(envFile: file.path, from: start)
        XCTAssertEqual(absolute.appSecret, "explicit-secret")

        // An explicit file without complete credentials is still the only file read.
        let partial = try write("SCOUT_APP_ID=explicit-id\n", to: "config/partial-fixture.env")
        let incomplete = try load(envFile: partial.path, from: start)
        XCTAssertEqual(incomplete.appID, "explicit-id")
        XCTAssertNil(incomplete.appSecret)
        XCTAssertEqual(incomplete.sourceDescription, "\(partial.path) (nonempty process environment values override it)")

        let message = configurationError { try load(envFile: "missing-fixture.env", from: start) }
        XCTAssertEqual(message, "Env file not found: \(start.appendingPathComponent("missing-fixture.env").path)")
    }

    func testWithoutEnvFileUsesProcessEnvironmentOnly() throws {
        let start = try directory("project/sub")

        let configuration = try load(environment: ["SCOUT_ACCESS_TOKEN": "env-token", "SCOUT_INBOX_ID": "7"], from: start)

        XCTAssertEqual(configuration.accessToken, "env-token")
        XCTAssertEqual(configuration.inboxID, 7)
        XCTAssertTrue(configuration.sourceDescription.contains("no .env file found"), configuration.sourceDescription)

        let empty = try load(from: start)
        XCTAssertEqual(empty, ScoutConfiguration(sourceDescription: empty.sourceDescription))
    }

    func testDescriptionsNeverShowSecrets() {
        let configuration = ScoutConfiguration(appID: "id", appSecret: "secret-value", accessToken: "token-value", inboxID: 3)
        let token = CachedToken(appID: "id", accessToken: "token-value", expiresAt: Date(timeIntervalSince1970: 0))
        for text in [String(describing: configuration), String(reflecting: configuration), "\(token)", String(reflecting: token)] {
            XCTAssertFalse(text.contains("secret-value"), text)
            XCTAssertFalse(text.contains("token-value"), text)
        }
        let request = HTTPRequest(
            method: "POST", url: URL(string: "https://api.helpscout.net/v2/x?q=jane")!,
            headers: ["Authorization": "Bearer token-value"], body: Data("secret-value".utf8)
        )
        XCTAssertEqual("\(request)", "HTTPRequest(POST /v2/x, headers: [\"Authorization\"], body: 12 bytes)")
    }
}
