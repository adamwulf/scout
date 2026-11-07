extension OutputFormatter {
    /// Makes API-supplied text safe to print to a terminal.
    enum TerminalText {
        /// Collapses all whitespace, line breaks and control characters into single spaces and removes
        /// bidirectional controls, so a value cannot break a table row or move the cursor.
        static func singleLine(_ text: String) -> String {
            var result = String.UnicodeScalarView()
            var pendingSpace = false
            for scalar in text.unicodeScalars {
                if isBidiControl(scalar) { continue }
                if scalar.properties.isWhitespace || scalar.properties.generalCategory == .control {
                    pendingSpace = true
                    continue
                }
                if pendingSpace && !result.isEmpty { result.append(" ") }
                pendingSpace = false
                result.append(scalar)
            }
            return String(result)
        }

        /// Keeps line breaks and tabs, normalizes CR and CRLF to LF, maps Unicode line and paragraph
        /// separators to LF, and drops other control and bidirectional control characters.
        static func multiline(_ text: String) -> String {
            var result = String.UnicodeScalarView()
            var previousWasCR = false
            for scalar in text.unicodeScalars {
                defer { previousWasCR = scalar == "\r" }
                switch scalar {
                case "\r": result.append("\n")
                case "\n": if !previousWasCR { result.append("\n") }
                case "\t": result.append(scalar)
                case "\u{2028}", "\u{2029}": result.append("\n")
                default:
                    if scalar.properties.generalCategory == .control || isBidiControl(scalar) { continue }
                    result.append(scalar)
                }
            }
            return String(result)
        }

        /// Approximate terminal column width: wide East Asian and emoji characters count as two
        /// columns and format characters as zero.
        static func displayWidth(_ text: String) -> Int {
            text.reduce(0) { $0 + width(of: $1) }
        }

        /// Shortens text to at most `limit` columns, ending in an ellipsis when shortened.
        static func truncate(_ text: String, toWidth limit: Int) -> String {
            guard displayWidth(text) > limit else { return text }
            var result = ""
            var used = 0
            for character in text {
                let width = width(of: character)
                if used + width > limit - 1 { break }
                result.append(character)
                used += width
            }
            return result + "…"
        }

        private static func width(of character: Character) -> Int {
            let scalars = character.unicodeScalars
            guard let first = scalars.first else { return 0 }
            if scalars.contains(where: { $0.properties.isEmojiPresentation || $0 == "\u{FE0F}" }) { return 2 }
            switch first.properties.generalCategory {
            case .format, .nonspacingMark, .enclosingMark, .control: return 0
            default: break
            }
            return isWide(first.value) ? 2 : 1
        }

        private static func isWide(_ value: UInt32) -> Bool {
            switch value {
            case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
                 0xA000...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60,
                 0xFFE0...0xFFE6, 0x20000...0x3FFFD:
                return true
            default:
                return false
            }
        }

        static func isBidiControl(_ scalar: Unicode.Scalar) -> Bool {
            switch scalar.value {
            case 0x061C, 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069: return true
            default: return false
            }
        }
    }
}
