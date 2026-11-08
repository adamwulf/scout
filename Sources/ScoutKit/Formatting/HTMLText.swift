import Foundation

extension OutputFormatter {
    /// Small, deterministic HTML-to-text conversion for readable markdown output. It is not an HTML
    /// parser: it keeps text, collapses whitespace, turns block elements into line breaks and list
    /// items into `- ` lines, skips scripts, styles and comments, and keeps http(s) and mailto links
    /// as markdown links. Text without tags keeps its line breaks but still has entities decoded,
    /// because escaped one-line replies such as `It&#39;s` contain no tags.
    ///
    /// Images are rendered where they appear, each `src` once. Help Scout inline images (see `InlineImage`)
    /// become markdown images of the downloaded file or the CDN URL, and text after one starts a new paragraph
    /// (a new line inside a list). Other images are never linked, because a
    /// markdown viewer would load them and could notify the sender: http(s) images become
    /// `[external image not fetched: host]`, other sources `[image not shown]`, and zero-size tracking pixels
    /// disappear.
    enum HTMLText {
        /// Body text and the distinct Help Scout inline images it shows, in order.
        struct Rendering: Equatable {
            var text: String
            var inlineImages: [InlineImage]
        }
        /// Checks actual body content without counting formatting tags or empty list bullets.
        /// Images with a source count as content even when there is no text.
        static func hasContent(_ input: String) -> Bool {
            let scalars = Array(input.unicodeScalars)
            var text = ""
            var skipping: String?
            var index = 0
            while index < scalars.count {
                if scalars[index] == "<", let tag = Tag.parse(scalars, at: index) {
                    index = tag.end
                    if let skipped = skipping {
                        if tag.isClosing && tag.name == skipped { skipping = nil }
                    } else if !tag.isClosing && !tag.isSelfClosing && skippedElements.contains(tag.name) {
                        skipping = tag.name
                    } else if !tag.isClosing && tag.name == "img",
                              let source = tag.attributes["src"], !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return true
                    }
                } else {
                    if skipping == nil { text.unicodeScalars.append(scalars[index]) }
                    index += 1
                }
            }
            return !decodeEntities(text).unicodeScalars.allSatisfy { $0.properties.isWhitespace || $0 == "\u{200B}" }
        }

        /// The rendered text alone; inline images show their CDN URLs.
        static func plainText(_ input: String) -> String {
            render(input).text
        }

        /// `inlineImagePaths` maps an inline image's `src` to its downloaded file, which is shown instead of the CDN URL.
        static func render(_ input: String, inlineImagePaths: [String: String] = [:]) -> Rendering {
            let normalized = TerminalText.multiline(input)
            let scalars = Array(normalized.unicodeScalars)
            guard containsMarkup(scalars) else {
                return Rendering(text: tidy(TerminalText.multiline(decodeEntities(normalized))), inlineImages: [])
            }
            var writer = Writer(inlineImagePaths: inlineImagePaths)
            var skipping: String?
            var index = 0
            while index < scalars.count {
                if scalars[index] == "<", let tag = Tag.parse(scalars, at: index) {
                    index = tag.end
                    if let skipped = skipping {
                        if tag.isClosing && tag.name == skipped { skipping = nil }
                    } else if !tag.isClosing && !tag.isSelfClosing && skippedElements.contains(tag.name) {
                        skipping = tag.name
                    } else {
                        writer.handle(tag)
                    }
                } else if skipping != nil {
                    index += 1
                } else if scalars[index] == "&", let match = entity(in: scalars, at: index) {
                    writer.write(match.text)
                    index = match.end
                } else {
                    writer.write(scalars[index])
                    index += 1
                }
            }
            return Rendering(text: tidy(TerminalText.multiline(writer.result)), inlineImages: writer.inlineImages)
        }

        /// The `src` of an image worth showing: nonempty after trimming, and not a zero-width or zero-height
        /// tracking pixel such as a read receipt.
        private static func visibleImageSource(_ attributes: [String: String]) -> String? {
            let source = (attributes["src"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let isTrackingPixel = ["width", "height"].contains { attributes[$0]?.trimmingCharacters(in: .whitespaces) == "0" }
            return source.isEmpty || isTrackingPixel ? nil : source
        }

        private static let skippedElements: Set<String> = ["script", "style", "title", "template"]
        private static let paragraphElements: Set<String> = [
            "p", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "dl", "table", "pre", "hr",
        ]
        private static let lineElements: Set<String> = [
            "div", "tr", "section", "article", "header", "footer", "address", "dt", "dd", "center",
            "form", "fieldset", "figure", "figcaption", "nav", "main", "aside", "caption",
        ]

        private struct Writer {
            private var output: [Unicode.Scalar] = []
            private var pendingSpace = false
            private var preformattedDepth = 0
            private var listDepth = 0
            /// True right after a list bullet until item text is written, so an item's opening
            /// `<p>` or `<div>` does not separate the bullet from its content.
            private var afterBullet = false
            private var links: [(href: String?, start: Int)] = []
            private let inlineImagePaths: [String: String]
            private var shownImageSources: Set<String> = []
            private(set) var inlineImages: [InlineImage] = []
            /// True after an inline image until the next text or link starts a new paragraph, so a following
            /// `--` or `==` line (such as a `-- ` signature delimiter) is not a setext underline that turns the
            /// image into a heading. Waiting for that text lets a link around the image close first, and keeps
            /// a `<br>` after the image from adding a second line break inside a list.
            private var paragraphAfterImage = false

            init(inlineImagePaths: [String: String]) {
                self.inlineImagePaths = inlineImagePaths
            }

            var result: String { String(String.UnicodeScalarView(output)) }

            mutating func write(_ text: String) {
                for scalar in text.unicodeScalars { write(scalar) }
            }

            mutating func write(_ scalar: Unicode.Scalar) {
                if preformattedDepth > 0 {
                    pendingSpace = false
                    afterBullet = false
                    output.append(scalar)
                } else if scalar.properties.isWhitespace {
                    pendingSpace = true
                } else {
                    startParagraphAfterImage()
                    flushSpace()
                    afterBullet = false
                    output.append(scalar)
                }
            }

            private mutating func startParagraphAfterImage() {
                guard paragraphAfterImage else { return }
                paragraphAfterImage = false
                paragraphBreak()
            }

            mutating func handle(_ tag: Tag) {
                let name = tag.name
                if tag.isClosing || name == "li" { afterBullet = false }
                if name == "br" {
                    if !afterBullet {
                        pendingSpace = false
                        output.append("\n")
                    }
                } else if name == "ul" || name == "ol" {
                    if tag.isClosing { listDepth = max(0, listDepth - 1) }
                    if listDepth > 0 { lineBreak() } else { paragraphBreak() }
                    if !tag.isClosing { listDepth += 1 }
                } else if HTMLText.paragraphElements.contains(name) {
                    paragraphBreak()
                    if name == "pre" { preformattedDepth = max(0, preformattedDepth + (tag.isClosing ? -1 : 1)) }
                } else if HTMLText.lineElements.contains(name) {
                    lineBreak()
                } else if name == "li" {
                    lineBreak()
                    if !tag.isClosing {
                        output.append(contentsOf: String(repeating: "  ", count: max(0, listDepth - 1)).unicodeScalars)
                        output.append("-")
                        pendingSpace = true
                        afterBullet = true
                    }
                } else if name == "td" || name == "th" {
                    pendingSpace = true
                } else if name == "a" {
                    if tag.isClosing { closeLink() } else {
                        startParagraphAfterImage()
                        flushSpace()
                        links.append((href: tag.attributes["href"], start: output.count))
                    }
                } else if name == "img" && !tag.isClosing {
                    image(tag.attributes)
                }
            }

            private mutating func image(_ attributes: [String: String]) {
                guard let source = HTMLText.visibleImageSource(attributes), shownImageSources.insert(source).inserted else { return }
                if let inline = InlineImage(source: source) {
                    inlineImages.append(inline)
                    write(Markdown.link(label: inline.filename, fallback: "image",
                                        destination: inlineImagePaths[source] ?? inline.url.absoluteString, isImage: true))
                    paragraphAfterImage = true
                } else if let url = URL(string: source), ["http", "https"].contains(url.scheme?.lowercased()),
                          let host = url.host(), !host.isEmpty {
                    write("[external image not fetched: \(host.lowercased())]")
                } else {
                    write("[image not shown]")
                }
            }

            private mutating func flushSpace() {
                if pendingSpace, let last = output.last, last != "\n", last != " " { output.append(" ") }
                pendingSpace = false
            }

            private mutating func lineBreak() {
                guard !afterBullet else { return }
                pendingSpace = false
                if let last = output.last, last != "\n" { output.append("\n") }
            }

            /// A blank line between blocks; inside a list item it is a single line break so the
            /// list stays together.
            private mutating func paragraphBreak() {
                guard !afterBullet else { return }
                lineBreak()
                if listDepth == 0 && !output.isEmpty && output.suffix(2) != ["\n", "\n"] { output.append("\n") }
            }

            private mutating func closeLink() {
                guard let link = links.popLast(), let rawHref = link.href else { return }
                let href = TerminalText.singleLine(rawHref)
                let lowered = href.lowercased()
                guard ["http://", "https://", "mailto:"].contains(where: { lowered.hasPrefix($0) }) else { return }
                var start = min(link.start, output.count)
                while start < output.count, output[start] == " " { start += 1 }
                let label = String(String.UnicodeScalarView(output[start...]))
                let target = lowered.hasPrefix("mailto:") ? String(href.dropFirst("mailto:".count)) : href
                if label == href || label == target { return }
                if label.isEmpty {
                    write(href)
                } else if label.contains("\n") {
                    write(" (\(href))")
                } else {
                    output.insert("[", at: start)
                    output.append(contentsOf: "](\(href))".unicodeScalars)
                }
            }
        }

        struct Tag {
            var name: String
            var isClosing: Bool
            var isSelfClosing: Bool
            var attributes: [String: String]
            /// Index just past the closing `>`.
            var end: Int

            /// Parses a tag, comment or declaration starting at `<`, or returns nil when the `<` is literal text.
            static func parse(_ s: [Unicode.Scalar], at start: Int) -> Tag? {
                var index = start + 1
                guard index < s.count else { return nil }
                if s[index] == "!" && index + 2 < s.count && s[index + 1] == "-" && s[index + 2] == "-" {
                    var cursor = index + 3
                    while cursor + 2 < s.count {
                        if s[cursor] == "-" && s[cursor + 1] == "-" && s[cursor + 2] == ">" { return ignored(end: cursor + 3) }
                        cursor += 1
                    }
                    return ignored(end: s.count)
                }
                if s[index] == "!" || s[index] == "?" {
                    guard let close = s[index...].firstIndex(of: ">") else { return nil }
                    return ignored(end: close + 1)
                }
                let isClosing = s[index] == "/"
                if isClosing { index += 1 }
                guard index < s.count, HTMLText.isASCIILetter(s[index]) else { return nil }
                var name = String.UnicodeScalarView()
                while index < s.count, HTMLText.isASCIILetter(s[index]) || ("0"..."9").contains(s[index]) || s[index] == "-" || s[index] == ":" {
                    name.append(s[index])
                    index += 1
                }
                var quote: Unicode.Scalar?
                var cursor = index
                while cursor < s.count {
                    if let open = quote {
                        if s[cursor] == open { quote = nil }
                    } else if s[cursor] == "\"" || s[cursor] == "'" {
                        quote = s[cursor]
                    } else if s[cursor] == ">" {
                        let body = Array(s[index..<cursor])
                        let isSelfClosing = body.last(where: { !$0.properties.isWhitespace }) == "/"
                        return Tag(name: String(name).lowercased(), isClosing: isClosing, isSelfClosing: isSelfClosing,
                                   attributes: attributes(body), end: cursor + 1)
                    }
                    cursor += 1
                }
                return nil
            }

            private static func ignored(end: Int) -> Tag {
                Tag(name: "", isClosing: false, isSelfClosing: true, attributes: [:], end: end)
            }

            private static func attributes(_ s: [Unicode.Scalar]) -> [String: String] {
                var result: [String: String] = [:]
                var index = 0
                func skipWhitespace() { while index < s.count, s[index].properties.isWhitespace { index += 1 } }
                while index < s.count {
                    skipWhitespace()
                    var name = String.UnicodeScalarView()
                    while index < s.count, !s[index].properties.isWhitespace, s[index] != "=", s[index] != "/" {
                        name.append(s[index])
                        index += 1
                    }
                    skipWhitespace()
                    var value = ""
                    if index < s.count, s[index] == "=" {
                        index += 1
                        skipWhitespace()
                        var scalars = String.UnicodeScalarView()
                        if index < s.count, s[index] == "\"" || s[index] == "'" {
                            let quote = s[index]
                            index += 1
                            while index < s.count, s[index] != quote { scalars.append(s[index]); index += 1 }
                            index += 1
                        } else {
                            while index < s.count, !s[index].properties.isWhitespace { scalars.append(s[index]); index += 1 }
                        }
                        value = HTMLText.decodeEntities(String(scalars))
                    }
                    if name.isEmpty {
                        index += 1
                    } else {
                        result[String(name).lowercased()] = value
                    }
                }
                return result
            }
        }

        private static func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
            ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
        }

        /// True when the text has something shaped like a tag (`<p`, `</p`, `<!`) followed later by `>`.
        private static func containsMarkup(_ s: [Unicode.Scalar]) -> Bool {
            guard let lastClose = s.lastIndex(of: ">") else { return false }
            for index in s.indices where index < lastClose && s[index] == "<" {
                let next = s[index + 1]
                if isASCIILetter(next) || next == "!" { return true }
                if next == "/", isASCIILetter(s[index + 2]) { return true }
            }
            return false
        }

        static func decodeEntities(_ text: String) -> String {
            let scalars = Array(text.unicodeScalars)
            var result = ""
            var index = 0
            while index < scalars.count {
                if scalars[index] == "&", let match = entity(in: scalars, at: index) {
                    result += match.text
                    index = match.end
                } else {
                    result.unicodeScalars.append(scalars[index])
                    index += 1
                }
            }
            return result
        }

        /// Decodes `&name;`, `&#123;` or `&#x7B;` at `start`; unknown or unterminated entities stay literal.
        private static func entity(in s: [Unicode.Scalar], at start: Int) -> (text: String, end: Int)? {
            var index = start + 1
            var name = ""
            while index < s.count, index - start <= 32, s[index] != ";" {
                guard s[index].isASCII, s[index] == "#" || isASCIILetter(s[index]) || ("0"..."9").contains(s[index]) else { return nil }
                name.unicodeScalars.append(s[index])
                index += 1
            }
            guard index < s.count, s[index] == ";", !name.isEmpty else { return nil }
            if name.hasPrefix("#") {
                let digits = name.dropFirst()
                let isHex = digits.hasPrefix("x") || digits.hasPrefix("X")
                guard let value = isHex ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits, radix: 10) else { return nil }
                let scalar = value == 0 ? nil : Unicode.Scalar(value)
                return (String(scalar ?? "\u{FFFD}"), index + 1)
            }
            guard let decoded = namedEntities[name] else { return nil }
            return (decoded, index + 1)
        }

        private static let namedEntities: [String: String] = [
            "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
            "ndash": "–", "mdash": "—", "hellip": "…", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”",
            "sbquo": "‚", "bdquo": "„", "laquo": "«", "raquo": "»", "bull": "•", "middot": "·",
            "copy": "©", "reg": "®", "trade": "™", "euro": "€", "pound": "£", "cent": "¢", "yen": "¥",
            "deg": "°", "times": "×", "divide": "÷", "shy": "",
        ]

        /// Trims trailing whitespace on each line, keeps at most one blank line in a row and removes
        /// leading and trailing blank lines.
        static func tidy(_ text: String) -> String {
            var lines: [Substring] = []
            var sawBlank = false
            for var line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                while let last = line.last, last.isWhitespace { line.removeLast() }
                if line.isEmpty {
                    sawBlank = true
                    continue
                }
                if sawBlank && !lines.isEmpty { lines.append("") }
                sawBlank = false
                lines.append(line)
            }
            return lines.joined(separator: "\n")
        }
    }
}
