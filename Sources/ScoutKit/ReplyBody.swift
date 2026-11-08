import Foundation

/// Reads and validates reply bodies before any request is made.
public enum ReplyBody {
    /// Reads the body from exactly one of `--body` text or `--body-file` (a path, or `-` for standard
    /// input). Refuses `-` when standard input is a terminal instead of waiting for input, and
    /// rejects invalid UTF-8 and empty or whitespace-only bodies. Templates are handled by the caller.
    public static func read(
        body: String?,
        file: String?,
        stdinIsTerminal: Bool,
        readStdin: () throws -> Data,
        readFile: (String) throws -> Data
    ) throws -> String {
        let text: String
        switch (body, file) {
        case (nil, nil):
            throw ScoutError.invalidInput("Provide a reply body with --body TEXT or --body-file PATH.")
        case (.some, .some):
            throw ScoutError.invalidInput("Use either --body or --body-file, not both.")
        case (let body?, nil):
            text = body
        case (nil, "-"):
            guard !stdinIsTerminal else {
                throw ScoutError.invalidInput(
                    "--body-file - reads the body from standard input, but standard input is a terminal. Pipe or redirect the body instead, for example: --body-file - < reply.txt"
                )
            }
            text = try decode(load("standard input", readStdin), source: "standard input")
        case (nil, let path?):
            guard !path.isEmpty else { throw ScoutError.invalidInput("--body-file needs a file path, or - for standard input.") }
            text = try decode(load("body file \(path)") { try readFile(path) }, source: "body file \(path)")
        }
        guard !isBlank(text) else { throw ScoutError.invalidInput("The reply body is empty.") }
        return text
    }

    /// Validates a body from any source (text, file, standard input or saved reply) and returns the
    /// HTML to send. Rejects empty bodies and unresolved Help Scout `{%...%}` variables. HTML is
    /// returned unchanged. Plain text is trimmed, HTML-escaped (`&`, `<`, `>`, `"`, `'`) and its line
    /// breaks become `<br>`.
    public static func prepare(_ text: String, html: Bool) throws -> String {
        guard !isBlank(text) else { throw ScoutError.invalidInput("The reply body is empty.") }
        if let open = text.range(of: "{%") {
            throw ScoutError.invalidInput(
                "The reply body contains an unresolved Help Scout variable\(variableMarker(in: text, from: open)). Replace variables with literal text before drafting or sending, for example: scout template ID > reply.html, edit it, then use --body-file reply.html --html."
            )
        }
        return html ? text : escapedPlainText(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func load(_ source: String, _ read: () throws -> Data) throws -> Data {
        do {
            return try read()
        } catch let error as ScoutError {
            throw error
        } catch {
            throw ScoutError.invalidInput("Could not read \(source): \(error.localizedDescription)")
        }
    }

    private static func decode(_ data: Data, source: String) throws -> String {
        let text = String(decoding: data, as: UTF8.self)
        guard text.utf8.elementsEqual(data) else {
            throw ScoutError.invalidInput("The reply body from \(source) is not valid UTF-8 text.")
        }
        return text
    }

    private static func isBlank(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy(\.properties.isWhitespace)
    }

    /// ` {%name%}` for the variable starting at `open`, or "" when it is unclosed, long or multiline,
    /// so the error names the variable without echoing message text. An unclosed `{%` is still
    /// rejected as unresolved.
    private static func variableMarker(in text: String, from open: Range<String.Index>) -> String {
        guard let close = text.range(of: "%}", range: open.upperBound..<text.endIndex) else { return "" }
        let marker = text[open.lowerBound..<close.upperBound]
        return marker.count <= 80 && !marker.contains(where: \.isNewline) ? " \(marker)" : ""
    }

    private static func escapedPlainText(_ text: String) -> String {
        var result = ""
        var previousWasCR = false
        for scalar in text.unicodeScalars {
            defer { previousWasCR = scalar == "\r" }
            switch scalar {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&#39;"
            case "\r": result += "<br>"
            case "\n": if !previousWasCR { result += "<br>" }
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result
    }
}
