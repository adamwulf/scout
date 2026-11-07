import ArgumentParser
import Foundation
import ScoutKit

struct BodyOptions: ParsableArguments {
    @Option(help: "Literal reply text.") var body: String?
    @Option(help: "UTF-8 reply file, or - for piped standard input.") var bodyFile: String?
    @Option(help: "Saved reply ID from the conversation's inbox.") var template: Int?
    @Flag(help: "Treat body/file text as HTML. Templates are already HTML.") var html = false

    mutating func validate() throws {
        try ReplyBody.validateSources(body: body, file: bodyFile, template: template, html: html)
    }
    func content() throws -> ReplyContent {
        try ReplyBody.content(body: body, file: bodyFile, template: template, html: html,
                              stdinIsTerminal: isatty(STDIN_FILENO) != 0,
                              readStdin: { try FileHandle.standardInput.readToEnd() ?? Data() },
                              readFile: { try Data(contentsOf: URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)) })
    }
}

struct Draft: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Save a reply draft in Help Scout, preserving conversation status. Does not send.")
    @OptionGroup var connection: ConnectionOptions
    @OptionGroup var body: BodyOptions
    @Argument(help: "Help Scout API conversation ID.") var id: Int
    mutating func validate() throws { try ScoutClient.positive(id, name: "Conversation ID") }
    func run() async throws {
        let content = try body.content()
        let receipt = try await connection.context().client.createDraft(conversation: id, content: content)
        try CLI.receipt(receipt)
    }
}

struct Send: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Send a NEW reply immediately. Does not publish an existing draft.")
    @OptionGroup var connection: ConnectionOptions
    @OptionGroup var body: BodyOptions
    @Argument(help: "Help Scout API conversation ID.") var id: Int
    @Option(help: "Conversation status after sending; active reopens a closed conversation.") var status: ReplyStatus = .active
    mutating func validate() throws { try ScoutClient.positive(id, name: "Conversation ID") }
    func run() async throws {
        let content = try body.content()
        let receipt = try await connection.context().client.sendReply(conversation: id, content: content, status: status)
        try CLI.receipt(receipt)
    }
}
