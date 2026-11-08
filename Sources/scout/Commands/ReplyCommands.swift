import ArgumentParser
import Foundation
import ScoutKit

struct BodyOptions: ParsableArguments {
    @Option(help: "Literal reply text.") var body: String?
    @Option(help: "UTF-8 reply file, or - for piped standard input.") var bodyFile: String?
    @Option(help: "Saved reply ID from the conversation's inbox.") var template: Int?
    @Flag(help: "Treat body/file text as HTML. Templates are already HTML.") var html = false

    func validateSource() throws {
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
    static let configuration = CommandConfiguration(
        abstract: "Create or update a reply draft, or send an existing draft with --send.",
        discussion: "Selects the only draft automatically; use --thread when several exist. Sending schedules an unscheduled draft 24 hours ahead, then publishes it immediately. A failure or interruption can leave a future send queued; inspect Help Scout before retrying. Delete drafts in Help Scout.")
    @OptionGroup var connection: ConnectionOptions
    @OptionGroup var body: BodyOptions
    @Argument(help: "Help Scout API conversation ID.") var id: Int
    @Option(help: "Existing draft thread ID; required when multiple drafts exist.") var thread: Int?
    @Flag(help: "Send the existing draft without supplying a body.") var send = false
    mutating func validate() throws {
        try ScoutClient.positive(id, name: "Conversation ID")
        if let thread { try ScoutClient.positive(thread, name: "Thread ID") }
        if send {
            guard body.body == nil, body.bodyFile == nil, body.template == nil, !body.html else {
                throw ValidationError("--send cannot be combined with --body, --body-file, --template, or --html.")
            }
        } else { try body.validateSource() }
    }
    func run() async throws {
        let receipt: DraftReceipt
        if send {
            receipt = try await connection.context().client.sendDraft(conversation: id, thread: thread)
        } else {
            let content = try body.content()
            receipt = try await connection.context().client.saveDraft(conversation: id, thread: thread, content: content)
        }
        CLI.output(try OutputFormatter.receipt(receipt))
        if receipt.threadID == nil {
            CLI.hint("Help Scout accepted the draft but returned no thread ID. Inspect the conversation before retrying.")
        }
    }
}

struct Send: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Send a NEW reply immediately. Does not publish an existing draft.")
    @OptionGroup var connection: ConnectionOptions
    @OptionGroup var body: BodyOptions
    @Argument(help: "Help Scout API conversation ID.") var id: Int
    @Option(help: "Conversation status after sending; active reopens a closed conversation.") var status: ReplyStatus = .active
    mutating func validate() throws {
        try ScoutClient.positive(id, name: "Conversation ID")
        try body.validateSource()
    }
    func run() async throws {
        let content = try body.content()
        let receipt = try await connection.context().client.sendReply(conversation: id, content: content, status: status)
        try CLI.receipt(receipt)
    }
}
