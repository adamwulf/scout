import ArgumentParser
import ScoutKit

@main
struct Scout: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scout", abstract: "Work with Help Scout inboxes.", version: "0.1.0",
        subcommands: [Auth.self, Inboxes.self, ListConversations.self, Show.self, Attachments.self, Search.self,
                      Customers.self, Customer.self, Templates.self, Template.self,
                      TemplateCreate.self, TemplateUpdate.self, TemplateDelete.self,
                      Draft.self, Send.self, SendDraft.self, Mark.self, ReadOnly.self]
    )
}

protocol ReadOnlyCommand: AsyncParsableCommand {}

struct ReadOnly: AsyncParsableCommand {
    static let commands: [any ReadOnlyCommand.Type] = [Inboxes.self, ListConversations.self, Show.self, Attachments.self,
        Search.self, Customers.self, Customer.self, Templates.self, Template.self, ReadOnlyAuth.self]
    static let configuration = CommandConfiguration(commandName: "ro", abstract: "Read Help Scout content (auth token cache may update; downloads write only local files).", subcommands: commands)
}

extension ListFormat: ExpressibleByArgument {}
extension DetailFormat: ExpressibleByArgument {}
extension ConversationStatus: ExpressibleByArgument {}
extension ReplyStatus: ExpressibleByArgument {}
