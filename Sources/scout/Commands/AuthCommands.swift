import ArgumentParser
import ScoutKit

struct Auth: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Authenticate and inspect the acting Help Scout user.", subcommands: [AuthLogin.self, AuthStatus.self])
}

struct ReadOnlyAuth: ReadOnlyCommand {
    static let configuration = CommandConfiguration(commandName: "auth", abstract: "Inspect auth identity (may renew the local token cache).", subcommands: [AuthStatus.self])
}

struct AuthLogin: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "login", abstract: "Obtain or reuse a token and verify the acting user. Credentials come from settings.")
    @OptionGroup var connection: ConnectionOptions
    func run() async throws {
        let identity = try await connection.context().client.identity()
        CLI.output(try OutputFormatter.detail(identity, kind: .customer, format: .json))
    }
}

struct AuthStatus: ReadOnlyCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Verify credentials and print the acting user as JSON.")
    @OptionGroup var connection: ConnectionOptions
    func run() async throws {
        let identity = try await connection.context().client.identity()
        CLI.output(try OutputFormatter.detail(identity, kind: .customer, format: .json))
    }
}
