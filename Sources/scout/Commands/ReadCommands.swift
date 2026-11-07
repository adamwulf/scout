import ArgumentParser
import ScoutKit

struct Inboxes: ReadOnlyCommand {
    static let configuration = CommandConfiguration(abstract: "List one page of inboxes.")
    @OptionGroup var connection: ConnectionOptions
    @OptionGroup var output: ListOptions
    @Option(help: "Page number, starting at 1.") var page = 1
    mutating func validate() throws { try ScoutClient.positive(page, name: "Page") }
    func run() async throws {
        let result = try await connection.context().client.inboxes(page: page)
        try CLI.page(result, kind: .inbox, format: output.format,
                     command: connection.command("inboxes", arguments: ["--format", output.format.rawValue]))
    }
}

struct ListConversations: ReadOnlyCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List one complete page of conversations.")
    @OptionGroup var connection: ConnectionOptions
    @OptionGroup var output: ListOptions
    @Option(help: "Inbox ID; defaults to SCOUT_INBOX_ID, or all accessible inboxes.") var inbox: Int?
    @Option(help: "Conversation status.") var status: ConversationStatus = .active
    @Option(help: "Continuation cursor from the previous page.") var cursor: String?
    mutating func validate() throws { if let inbox { try ScoutClient.positive(inbox, name: "Inbox ID") } }
    func run() async throws {
        let context = try connection.context()
        let inbox = inbox ?? context.configuration.inboxID
        let result = try await context.client.conversations(inbox: inbox, status: status, cursor: cursor)
        let flags = ["--status", status.rawValue, "--format", output.format.rawValue] + (inbox.map { ["--inbox", String($0)] } ?? [])
        try CLI.page(result, kind: .conversation, format: output.format, command: connection.command("list", arguments: flags))
    }
}

struct Show: ReadOnlyCommand {
    static let configuration = CommandConfiguration(abstract: "Read a conversation and every page of its threads.")
    @OptionGroup var connection: ConnectionOptions
    @OptionGroup var output: DetailOptions
    @Argument(help: "Help Scout API conversation ID (not its #number).") var id: Int
    mutating func validate() throws { try ScoutClient.positive(id, name: "Conversation ID") }
    func run() async throws {
        let view = try await connection.context().client.show(id)
        CLI.output(try OutputFormatter.conversation(view.conversation, threads: view.threads, format: output.format))
    }
}

struct Search: ReadOnlyCommand {
    static let configuration = CommandConfiguration(abstract: "Search field:value clauses across all inboxes/statuses unless the query restricts them.")
    @OptionGroup var connection: ConnectionOptions
    @OptionGroup var output: ListOptions
    @Argument(help: "Example: 'email:\"jane@my-company.com\"' or 'subject:refund AND status:active'.") var query: String
    @Option(help: "Continuation cursor; retain the same query.") var cursor: String?
    mutating func validate() throws { try ScoutClient.validateQuery(query, example: "subject:refund", maximum: 500) }
    func run() async throws {
        let result = try await connection.context().client.search(query, cursor: cursor)
        try CLI.page(result, kind: .conversation, format: output.format,
                     command: connection.command("search", arguments: [query, "--format", output.format.rawValue]))
    }
}

struct Customers: ReadOnlyCommand {
    static let configuration = CommandConfiguration(abstract: "Filter customers by email or an advanced field query.")
    @OptionGroup var connection: ConnectionOptions
    @OptionGroup var output: ListOptions
    @Option(help: "Help Scout customer email filter.") var email: String?
    @Option(help: "Advanced query, for example 'firstName:Jane'.") var query: String?
    @Option(help: "Continuation cursor from the previous page.") var cursor: String?
    mutating func validate() throws {
        guard (email != nil) != (query != nil) else { throw ValidationError("Provide exactly one of --email or --query.") }
        if let query { try ScoutClient.validateQuery(query, example: "firstName:Jane") }
    }
    func run() async throws {
        let result = try await connection.context().client.customers(email: email, query: query, cursor: cursor)
        let filter = email.map { ["--email", $0] } ?? ["--query", query ?? ""]
        try CLI.page(result, kind: .customer, format: output.format,
                     command: connection.command("customers", arguments: filter + ["--format", output.format.rawValue]))
    }
}

struct Customer: ReadOnlyCommand {
    static let configuration = CommandConfiguration(abstract: "Look up a Help Scout customer ID and its properties.")
    @OptionGroup var connection: ConnectionOptions
    @OptionGroup var output: DetailOptions
    @Argument(help: "Help Scout customer ID.") var id: Int
    mutating func validate() throws { try ScoutClient.positive(id, name: "Customer ID") }
    func run() async throws {
        let value = try await connection.context().client.customer(id)
        CLI.output(try OutputFormatter.detail(value, kind: .customer, format: output.format))
    }
}

struct Templates: ReadOnlyCommand {
    static let configuration = CommandConfiguration(abstract: "List email saved replies in an inbox.")
    @OptionGroup var connection: ConnectionOptions
    @OptionGroup var output: ListOptions
    @Option(help: "Inbox ID; defaults to SCOUT_INBOX_ID.") var inbox: Int?
    mutating func validate() throws { if let inbox { try ScoutClient.positive(inbox, name: "Inbox ID") } }
    func run() async throws {
        let context = try connection.context()
        let result = try await context.client.templates(inbox: context.configuration.requireInbox(override: inbox))
        CLI.output(try OutputFormatter.list(result, kind: .template, format: output.format))
    }
}

struct Template: ReadOnlyCommand {
    static let configuration = CommandConfiguration(abstract: "Export a saved reply. Raw HTML output can be edited and used with --body-file --html.")
    @OptionGroup var connection: ConnectionOptions
    @Argument(help: "Saved reply ID.") var id: Int
    @Option(help: "Inbox ID; defaults to SCOUT_INBOX_ID.") var inbox: Int?
    @Option(help: "Output format: raw, markdown, json.") var format: DetailFormat = .raw
    mutating func validate() throws {
        try ScoutClient.positive(id, name: "Template ID")
        if let inbox { try ScoutClient.positive(inbox, name: "Inbox ID") }
    }
    func run() async throws {
        let context = try connection.context()
        let value = try await context.client.template(id, inbox: context.configuration.requireInbox(override: inbox))
        CLI.output(try OutputFormatter.detail(value, kind: .template, format: format))
    }
}
