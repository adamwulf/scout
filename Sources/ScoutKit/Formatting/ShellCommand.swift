import Foundation

extension OutputFormatter {
    /// Quotes one argument for POSIX shells and zsh. Arguments made only of safe characters stay
    /// bare; anything else is single-quoted, with embedded apostrophes written as `'\''`.
    public static func shellQuote(_ value: String) -> String {
        guard !value.isEmpty else { return "''" }
        let safe = value.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (scalar.properties.isAlphabetic || ("0"..."9").contains(scalar) || "_@%+:,./-".unicodeScalars.contains(scalar))
        }
        if safe { return value }
        return "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// A runnable, shell-quoted command for the next page, or nil on the last page. `command` is the
    /// full original invocation (for example `["scout", "list", "--status", "all"]`) without any
    /// `--cursor` or `--page` option; this appends `--cursor` when the page has a next cursor,
    /// otherwise `--page` when it has a next page number. The caller prints it to stderr.
    public static func continuation(command: [String], page: ResourcePage) -> String? {
        let next: [String]
        if let cursor = page.nextCursor, !cursor.isEmpty {
            next = ["--cursor", cursor]
        } else if let number = page.nextPage {
            next = ["--page", String(number)]
        } else {
            return nil
        }
        return (command + next).map(shellQuote).joined(separator: " ")
    }
}
