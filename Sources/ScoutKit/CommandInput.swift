import Foundation

extension ScoutConfiguration {
    public func requireInbox(override: Int?) throws -> Int {
        guard let value = override ?? inboxID else {
            throw ScoutError.invalidInput("Provide --inbox ID or set SCOUT_INBOX_ID.")
        }
        try ScoutClient.positive(value, name: "Inbox ID")
        return value
    }
}

extension ReplyBody {
    public static func validateSources(body: String?, file: String?, template: Int?, html: Bool) throws {
        guard [body != nil, file != nil, template != nil].filter({ $0 }).count == 1 else {
            throw ScoutError.invalidInput("Provide exactly one of --body, --body-file, or --template.")
        }
        if let template {
            try ScoutClient.positive(template, name: "Template ID")
            guard !html else { throw ScoutError.invalidInput("--template already contains HTML; omit --html.") }
        }
    }

    public static func content(body: String?, file: String?, template: Int?, html: Bool,
                               stdinIsTerminal: Bool, readStdin: () throws -> Data,
                               readFile: (String) throws -> Data) throws -> ReplyContent {
        try validateSources(body: body, file: file, template: template, html: html)
        if let template { return .template(template) }
        return .text(try read(body: body, file: file, stdinIsTerminal: stdinIsTerminal,
                              readStdin: readStdin, readFile: readFile), html: html)
    }
}

extension OutputFormatter {
    public static func receipt(_ receipt: ReplyReceipt) throws -> String {
        try prettyJSON(.object([
            "conversationID": .integer(receipt.conversationID),
            "threadID": receipt.threadID.map(JSONValue.integer) ?? .null,
            "draft": .bool(receipt.draft)
        ]))
    }
}
