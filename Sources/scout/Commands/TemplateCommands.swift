import ArgumentParser
import Foundation
import ScoutKit

struct TemplateWriteOptions: ParsableArguments {
    @Option(help: "Saved reply name.") var name: String?
    @Option(help: "Email body as plain text; variables are allowed.") var body: String?
    @Option(help: "UTF-8 email body file, or - for standard input.") var bodyFile: String?
    @Flag(help: "Treat the email body as HTML.") var html = false
    @Option(help: "Plain-text chat content; variables are allowed.") var chatText: String?

    mutating func validate() throws {
        guard body == nil || bodyFile == nil else { throw ValidationError("Use either --body or --body-file, not both.") }
        guard !html || body != nil || bodyFile != nil else { throw ValidationError("--html requires --body or --body-file.") }
        guard name != nil || body != nil || bodyFile != nil || chatText != nil else {
            throw ValidationError("Provide --name, --body, --body-file, or --chat-text.")
        }
        for (option, value) in [("--name", name), ("--body", body), ("--body-file", bodyFile), ("--chat-text", chatText)] {
            if let value, value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ValidationError("\(option) cannot be empty.")
            }
        }
    }

    func emailText() throws -> String? {
        guard body != nil || bodyFile != nil else { return nil }
        let text = try ReplyBody.read(body: body, file: bodyFile,
                                      stdinIsTerminal: isatty(STDIN_FILENO) != 0,
                                      readStdin: { FileHandle.standardInput.readDataToEndOfFile() },
                                      readFile: { try Data(contentsOf: URL(fileURLWithPath: $0)) })
        return try ReplyBody.prepareTemplate(text, html: html)
    }
}

struct TemplateCreate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "template-create", abstract: "Create a saved reply in an inbox.")
    @OptionGroup var connection: ConnectionOptions
    @OptionGroup var fields: TemplateWriteOptions
    @Option(help: "Inbox ID; defaults to SCOUT_INBOX_ID.") var inbox: Int?

    mutating func validate() throws {
        if let inbox { try ScoutClient.positive(inbox, name: "Inbox ID") }
        guard fields.name != nil else { throw ValidationError("Provide --name for the new saved reply.") }
        guard fields.body != nil || fields.bodyFile != nil || fields.chatText != nil else {
            throw ValidationError("Provide an email body or --chat-text for the new saved reply.")
        }
    }

    func run() async throws {
        let text = try fields.emailText()
        let context = try connection.context()
        let receipt = try await context.client.createTemplate(inbox: context.configuration.requireInbox(override: inbox),
                                                              name: fields.name ?? "", text: text, chatText: fields.chatText)
        CLI.output(try OutputFormatter.receipt(receipt))
        if receipt.templateID == nil {
            CLI.hint("Help Scout accepted the saved reply but returned no ID. List templates to find it; do not repeat the create command.")
        }
    }
}

struct TemplateUpdate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "template-update", abstract: "Update a saved reply, preserving fields you omit.")
    @OptionGroup var connection: ConnectionOptions
    @OptionGroup var fields: TemplateWriteOptions
    @Argument(help: "Saved reply ID.") var id: Int
    @Option(help: "Inbox ID; defaults to SCOUT_INBOX_ID.") var inbox: Int?

    mutating func validate() throws {
        try ScoutClient.positive(id, name: "Template ID")
        if let inbox { try ScoutClient.positive(inbox, name: "Inbox ID") }
    }

    func run() async throws {
        let text = try fields.emailText()
        let context = try connection.context()
        let receipt = try await context.client.updateTemplate(id, inbox: context.configuration.requireInbox(override: inbox),
                                                              name: fields.name, text: text, chatText: fields.chatText)
        CLI.output(try OutputFormatter.receipt(receipt))
    }
}

struct TemplateDelete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "template-delete", abstract: "Delete a saved reply from an inbox.")
    @OptionGroup var connection: ConnectionOptions
    @Argument(help: "Saved reply ID.") var id: Int
    @Option(help: "Inbox ID; defaults to SCOUT_INBOX_ID.") var inbox: Int?

    mutating func validate() throws {
        try ScoutClient.positive(id, name: "Template ID")
        if let inbox { try ScoutClient.positive(inbox, name: "Inbox ID") }
    }

    func run() async throws {
        let context = try connection.context()
        let receipt = try await context.client.deleteTemplate(id, inbox: context.configuration.requireInbox(override: inbox))
        CLI.output(try OutputFormatter.receipt(receipt))
    }
}
