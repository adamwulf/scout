import Foundation

/// Pure renderers for command output. Results are stdout data only; continuation hints come from
/// `continuation(command:page:)` for the caller to print to stderr. Every nonempty result already
/// ends with a newline, so callers print it with `terminator: ""`.
public enum OutputFormatter {
    /// Renders one API page.
    /// - `json`: a stable object with `items`, `nextCursor` and `nextPage` (null when absent).
    /// - `jsonl`: one compact JSON item per line; empty for an empty page.
    /// - `id`: one API ID per line; empty for an empty page.
    /// - `table`: aligned single-line columns with a header row, even for an empty page.
    public static func list(_ page: ResourcePage, kind: ResourceKind, format: ListFormat) throws -> String {
        switch format {
        case .json:
            return try prettyJSON(.object([
                "items": .array(page.items),
                "nextCursor": page.nextCursor.map(JSONValue.string) ?? .null,
                "nextPage": page.nextPage.map(JSONValue.integer) ?? .null,
            ]))
        case .jsonl:
            return try page.items.map { try compactJSON($0) + "\n" }.joined()
        case .id:
            return try page.items.map { "\(try $0.requiredID())\n" }.joined()
        case .table:
            return Table.render(page.items, kind: kind)
        }
    }

    /// Renders one resource. `raw` is only valid for templates and returns the saved reply's email
    /// `text` exactly, adding a final newline only when the text lacks one.
    public static func detail(_ value: JSONValue, kind: ResourceKind, format: DetailFormat) throws -> String {
        switch format {
        case .json:
            return try prettyJSON(value)
        case .raw:
            guard kind == .template else { throw rawUnavailable }
            guard let text = value["text"].string else {
                throw ScoutError.decoding("Help Scout saved reply response is missing its email text.")
            }
            return text.isEmpty || text.unicodeScalars.last == "\n" ? text : text + "\n"
        case .markdown:
            return Markdown.detail(value, kind: kind)
        }
    }

    /// Renders a conversation with its threads. JSON keeps the full API objects under
    /// `conversation` and `threads`; markdown lists threads oldest first with labeled metadata.
    public static func conversation(_ value: JSONValue, threads: [JSONValue], format: DetailFormat) throws -> String {
        switch format {
        case .json:
            return try prettyJSON(.object(["conversation": value, "threads": .array(threads)]))
        case .raw:
            throw rawUnavailable
        case .markdown:
            return Markdown.conversation(value, threads: threads)
        }
    }

    private static let rawUnavailable = ScoutError.invalidInput("The raw format is only available for templates.")

    static func prettyJSON(_ value: JSONValue) throws -> String {
        try encode(value, formatting: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) + "\n"
    }

    static func compactJSON(_ value: JSONValue) throws -> String {
        try encode(value, formatting: [.sortedKeys, .withoutEscapingSlashes])
    }

    private static func encode(_ value: JSONValue, formatting: JSONEncoder.OutputFormatting) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = formatting
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    /// Text for a scalar JSON value, or nil for null, empty strings, arrays and objects.
    static func scalarText(_ value: JSONValue) -> String? {
        switch value {
        case .string(let text): return text.isEmpty ? nil : text
        case .integer(let number): return String(number)
        case .number(let number): return String(number)
        case .bool(let flag): return flag ? "true" : "false"
        case .null, .array, .object: return nil
        }
    }

    /// `First Last <email>` for Help Scout person objects, which use `first`/`last` in conversations
    /// and threads and `firstName`/`lastName` on customers.
    static func personLabel(_ person: JSONValue) -> String? {
        let name = personName(person)
        let email = person["email"].string ?? ""
        switch (name.isEmpty, email.isEmpty) {
        case (false, false): return "\(name) <\(email)>"
        case (false, true): return name
        case (true, false): return email
        case (true, true): return nil
        }
    }

    static func personName(_ person: JSONValue) -> String {
        [person["first"].string ?? person["firstName"].string, person["last"].string ?? person["lastName"].string]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
