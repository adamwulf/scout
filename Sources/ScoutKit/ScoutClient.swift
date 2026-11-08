import Foundation

public enum ConversationStatus: String, CaseIterable, Sendable {
    case active, pending, closed, spam, all
}

/// Writable conversation statuses, shared by replies and standalone status changes.
public enum ReplyStatus: String, CaseIterable, Codable, Sendable {
    case active, pending, closed, spam
}

public enum ReplyContent: Sendable {
    case text(String, html: Bool)
    case template(Int)
}

public struct ConversationView: Sendable {
    public let conversation: JSONValue
    public let threads: [JSONValue]
}

public struct ReplyReceipt: Codable, Sendable {
    public let conversationID: Int
    public let threadID: Int?
    public let draft: Bool
}

public struct StatusReceipt: Codable, Sendable {
    public let conversationID: Int
    public let status: ReplyStatus
}

public struct TemplateReceipt: Codable, Sendable {
    public let inboxID: Int
    public let templateID: Int?
    public let operation: String
}

/// Library facade for the supported workflows. Lists return a complete server page.
public struct ScoutClient: Sendable {
    private let http: ScoutHTTPClient

    public init(http: ScoutHTTPClient) { self.http = http }
    public init(configuration: ScoutConfiguration) { self.http = ScoutHTTPClient(configuration: configuration) }

    public func identity() async throws -> JSONValue {
        try await get("/v2/users/me")
    }

    public func inboxes(page: Int = 1) async throws -> ResourcePage {
        try Self.positive(page, name: "Page")
        return try await numberedPage("/v2/mailboxes", collection: "mailboxes", page: page)
    }

    public func conversations(inbox: Int? = nil, status: ConversationStatus = .active, cursor: String? = nil) async throws -> ResourcePage {
        var query = ["status": status.rawValue]
        if let inbox { try Self.positive(inbox, name: "Inbox ID"); query["inboxId"] = String(inbox) }
        return try await cursorPage("/v3/conversations", collection: "conversations", query: query, cursor: cursor)
    }

    public func search(_ query: String, cursor: String? = nil) async throws -> ResourcePage {
        try Self.validateQuery(query, example: "subject:refund", maximum: 500)
        return try await cursorPage("/v3/conversations/search", collection: "conversations", query: ["query": query], cursor: cursor)
    }

    public func customers(email: String? = nil, query: String? = nil, cursor: String? = nil) async throws -> ResourcePage {
        guard (email != nil) != (query != nil) else {
            throw ScoutError.invalidInput("Provide exactly one of --email or --query.")
        }
        var parameters: [String: String] = [:]
        if let email {
            guard !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ScoutError.invalidInput("--email cannot be empty.")
            }
            parameters["email"] = email
        }
        if let query { try Self.validateQuery(query, example: "firstName:Jane"); parameters["query"] = query }
        return try await cursorPage("/v3/customers", collection: "customers", query: parameters, cursor: cursor)
    }

    public func customer(_ id: Int) async throws -> JSONValue {
        try Self.positive(id, name: "Customer ID")
        return try await get("/v2/customers/\(id)")
    }

    public func templates(inbox: Int, includeChat: Bool = false) async throws -> ResourcePage {
        try Self.positive(inbox, name: "Inbox ID")
        let value = try await get("/v2/mailboxes/\(inbox)/saved-replies", query: includeChat ? ["includeChatReplies": "true"] : [:])
        guard let items = value.array else { throw ScoutError.decoding("Help Scout saved replies response is not an array.") }
        return ResourcePage(items: items)
    }

    public func template(_ id: Int, inbox: Int) async throws -> JSONValue {
        try Self.positive(id, name: "Template ID")
        try Self.positive(inbox, name: "Inbox ID")
        return try await get("/v2/mailboxes/\(inbox)/saved-replies/\(id)")
    }

    public func createTemplate(inbox: Int, name: String, text: String? = nil, chatText: String? = nil) async throws -> TemplateReceipt {
        try Self.positive(inbox, name: "Inbox ID")
        let fields = try Self.templateFields(name: name, text: text, chatText: chatText)
        guard text != nil || chatText != nil else {
            throw ScoutError.invalidInput("Provide an email body or --chat-text for the saved reply.")
        }
        let response = try await http.request(method: "POST", path: "/v2/mailboxes/\(inbox)/saved-replies", body: .object(fields))
        let id = response.header("Resource-ID").flatMap(Int.init).flatMap { $0 > 0 ? $0 : nil }
        return TemplateReceipt(inboxID: inbox, templateID: id, operation: "created")
    }

    /// PUT requires a name. Read the current reply to preserve fields omitted by the caller.
    public func updateTemplate(_ id: Int, inbox: Int, name: String? = nil, text: String? = nil, chatText: String? = nil) async throws -> TemplateReceipt {
        let changes = try Self.templateFields(name: name, text: text, chatText: chatText)
        guard !changes.isEmpty else { throw ScoutError.invalidInput("Provide --name, an email body, or --chat-text to update.") }
        let current = try await template(id, inbox: inbox)
        var fields: [String: JSONValue] = [:]
        for key in ["name", "text", "chatText"] {
            if let value = current[key].string { fields[key] = .string(value) }
        }
        fields.merge(changes) { _, new in new }
        guard let name = fields["name"]?.string, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ScoutError.decoding("Saved reply has no name. Provide --name to update it.")
        }
        _ = try await http.request(method: "PUT", path: "/v2/mailboxes/\(inbox)/saved-replies/\(id)", body: .object(fields))
        return TemplateReceipt(inboxID: inbox, templateID: id, operation: "updated")
    }

    public func deleteTemplate(_ id: Int, inbox: Int) async throws -> TemplateReceipt {
        try Self.positive(id, name: "Template ID")
        try Self.positive(inbox, name: "Inbox ID")
        _ = try await http.request(method: "DELETE", path: "/v2/mailboxes/\(inbox)/saved-replies/\(id)")
        return TemplateReceipt(inboxID: inbox, templateID: id, operation: "deleted")
    }

    private static func templateFields(name: String?, text: String?, chatText: String?) throws -> [String: JSONValue] {
        var fields: [String: JSONValue] = [:]
        for (key, value) in [("name", name), ("text", text), ("chatText", chatText)] {
            if let value {
                guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ScoutError.invalidInput("Saved reply \(key) cannot be empty.")
                }
                fields[key] = .string(value)
            }
        }
        return fields
    }

    public func show(_ id: Int) async throws -> ConversationView {
        let conversation = try await conversation(id)
        var threads: [JSONValue] = []
        var number = 1
        while true {
            let page = try await numberedPage("/v3/conversations/\(id)/threads", collection: "threads", page: number)
            threads += page.items
            guard let next = page.nextPage else { break }
            number = next
        }
        return ConversationView(conversation: conversation, threads: threads)
    }

    public func createDraft(conversation id: Int, content: ReplyContent) async throws -> ReplyReceipt {
        try await createReply(conversation: id, content: content, draft: true, status: nil)
    }

    public func sendReply(conversation id: Int, content: ReplyContent, status: ReplyStatus = .active) async throws -> ReplyReceipt {
        try await createReply(conversation: id, content: content, draft: false, status: status)
    }

    /// Changes the whole conversation's status without creating or sending a reply.
    @discardableResult
    public func mark(conversation id: Int, status: ReplyStatus) async throws -> StatusReceipt {
        _ = try await conversation(id)
        _ = try await http.request(method: "PATCH", path: "/v2/conversations/\(id)", body: .object([
            "op": .string("replace"), "path": .string("/status"), "value": .string(status.rawValue)
        ]))
        return StatusReceipt(conversationID: id, status: status)
    }

    public static func positive(_ value: Int, name: String) throws {
        guard value > 0 else { throw ScoutError.invalidInput("\(name) must be a positive Help Scout API ID or page number.") }
    }

    public static func validateQuery(_ query: String, example: String, maximum: Int? = nil) throws {
        guard query.range(of: #"[A-Za-z][A-Za-z0-9]*:\S"#, options: .regularExpression) != nil else {
            throw ScoutError.invalidInput("Search needs field:value syntax, for example '\(example)' or 'email:\"jane@my-company.com\"'. Quote values containing reserved characters.")
        }
        if let maximum, query.count > maximum {
            throw ScoutError.invalidInput("Search query must be at most \(maximum) characters.")
        }
    }

    private func conversation(_ id: Int) async throws -> JSONValue {
        try Self.positive(id, name: "Conversation ID")
        let value = try await get("/v3/conversations/\(id)")
        guard try value.requiredID() == id else {
            throw ScoutError.decoding("Help Scout returned a different conversation ID. Inspect the conversation before retrying.")
        }
        return value
    }

    private func createReply(conversation id: Int, content: ReplyContent, draft: Bool, status: ReplyStatus?) async throws -> ReplyReceipt {
        // Validate literal content before any HTTP request; templates need the conversation's inbox.
        let literal: String?
        switch content {
        case .text(let text, let html): literal = try ReplyBody.prepare(text, html: html)
        case .template(let templateID): try Self.positive(templateID, name: "Template ID"); literal = nil
        }
        let conversation = try await conversation(id)
        let customerID = try conversation["primaryCustomer"].requiredID()
        let text: String
        if let literal { text = literal }
        else if case .template(let templateID) = content {
            let inbox = try conversation.requiredID("mailboxId")
            let saved = try await template(templateID, inbox: inbox)
            guard let body = saved["text"].string else {
                throw ScoutError.decoding("Saved reply has no email text. Choose an email template.")
            }
            text = try ReplyBody.prepare(body, html: true)
        } else { throw ScoutError.invalidInput("A reply body is required.") }

        let targetStatus: String
        if let status { targetStatus = status.rawValue }
        else {
            guard let current = conversation["status"].string, ReplyStatus(rawValue: current) != nil else {
                throw ScoutError.decoding("Cannot preserve the conversation status while drafting. Inspect it in Help Scout.")
            }
            targetStatus = current
        }
        let response = try await http.request(method: "POST", path: "/v2/conversations/\(id)/reply", body: .object([
            "customer": .object(["id": .integer(customerID)]),
            "text": .string(text), "draft": .bool(draft), "status": .string(targetStatus)
        ]))
        // A successful write is still successful if the server omits its identifier. Never invite a duplicate retry.
        let threadID = response.header("Resource-ID").flatMap(Int.init).flatMap { $0 > 0 ? $0 : nil }
        return ReplyReceipt(conversationID: id, threadID: threadID, draft: draft)
    }

    private func cursorPage(_ path: String, collection: String, query: [String: String], cursor: String?) async throws -> ResourcePage {
        var query = query
        if let cursor {
            guard !cursor.isEmpty else { throw ScoutError.invalidInput("--cursor cannot be empty. Omit it to restart pagination.") }
            query["cursor"] = cursor
        }
        let value = try await get(path, query: query)
        let items = try Self.items(value, collection: collection)
        var nextCursor: String?
        if let href = value["_links"]["next"]["href"].string {
            nextCursor = URLComponents(string: href)?.queryItems?.first(where: { $0.name == "cursor" })?.value
            guard let nextCursor, !nextCursor.isEmpty, nextCursor != cursor else {
                throw ScoutError.decoding("Help Scout returned an unusable pagination cursor for \(path). Restart without --cursor.")
            }
        }
        return ResourcePage(items: items, nextCursor: nextCursor)
    }

    private func numberedPage(_ path: String, collection: String, page: Int) async throws -> ResourcePage {
        let value = try await get(path, query: ["page": String(page)])
        let items = try Self.items(value, collection: collection)
        guard let total = value["page"]["totalPages"].int, total >= 0 else {
            throw ScoutError.decoding("Help Scout response has no valid pagination metadata for \(path).")
        }
        return ResourcePage(items: items, nextPage: page < total ? page + 1 : nil)
    }

    private static func items(_ value: JSONValue, collection: String) throws -> [JSONValue] {
        guard let items = value["_embedded"][collection].array else {
            throw ScoutError.decoding("Help Scout response is missing its \(collection) array.")
        }
        return items
    }

    private func get(_ path: String, query: [String: String] = [:]) async throws -> JSONValue {
        let response = try await http.request(path: path, query: query)
        do { return try JSONDecoder().decode(JSONValue.self, from: response.body) }
        catch { throw ScoutError.decoding("Help Scout returned invalid JSON for GET \(path).") }
    }
}
