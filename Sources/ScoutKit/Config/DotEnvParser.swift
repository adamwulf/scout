import Foundation

/// Parses the small dotenv subset Scout documents: `KEY=value`, optional `export`, single or double quotes and
/// `#` comments. Nothing is shell-evaluated. Only Scout's keys are returned; other lines belong to other tools,
/// so they are ignored even when malformed.
enum DotEnvParser {
    struct Entry: Equatable {
        var value: String
        var line: Int
    }

    static func parse(_ text: String, keys: Set<String>, source: String) throws -> [String: Entry] {
        let text = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        var entries: [String: Entry] = [:]
        for (index, rawLine) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            let lineNumber = index + 1
            var line = rawLine.drop(while: isBlank)
            if line.isEmpty || line.first == "#" { continue }
            if line.hasPrefix("export"), let next = line.dropFirst(6).first, isBlank(next) {
                line = line.dropFirst(6).drop(while: isBlank)
            }
            guard let equals = line.firstIndex(of: "=") else {
                let word = String(line.prefix { !isBlank($0) })
                if keys.contains(word) { throw malformed(word, source: source, line: lineNumber) }
                continue
            }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            guard keys.contains(key) else { continue }
            guard let value = parseValue(line[line.index(after: equals)...]) else {
                throw malformed(key, source: source, line: lineNumber)
            }
            entries[key] = Entry(value: value, line: lineNumber)
        }
        return entries
    }

    /// Returns nil for an unterminated quote or text after a closing quote.
    static func parseValue(_ raw: Substring) -> String? {
        let text = raw.drop(while: isBlank)
        guard let quote = text.first else { return "" }
        guard quote == "\"" || quote == "'" else {
            // An unquoted value ends at a `#` that follows whitespace.
            var end = text.endIndex
            var previousWasBlank = false
            for index in text.indices {
                if text[index] == "#" && previousWasBlank {
                    end = index
                    break
                }
                previousWasBlank = isBlank(text[index])
            }
            return text[..<end].trimmingCharacters(in: .whitespaces)
        }

        var value = ""
        var index = text.index(after: text.startIndex)
        while index < text.endIndex {
            let character = text[index]
            if character == quote {
                let remainder = text[text.index(after: index)...].drop(while: isBlank)
                return remainder.isEmpty || remainder.first == "#" ? value : nil
            }
            let next = text.index(after: index)
            if quote == "\"", character == "\\", next < text.endIndex, text[next] == "\"" || text[next] == "\\" {
                value.append(text[next])
                index = text.index(after: next)
                continue
            }
            value.append(character)
            index = next
        }
        return nil
    }

    private static func isBlank(_ character: Character) -> Bool {
        character == " " || character == "\t"
    }

    private static func malformed(_ key: String, source: String, line: Int) -> ScoutError {
        .configuration("\(key) in \(source) line \(line) is malformed; check its quotes and comments. The value is not shown.")
    }
}
