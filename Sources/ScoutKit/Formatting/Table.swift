extension OutputFormatter {
    /// Aligned, single-line, terminal-safe tables with a header row and no trailing spaces.
    enum Table {
        private struct Column {
            var title: String
            var maxWidth: Int?
            var value: (JSONValue) -> String?
        }

        static func render(_ items: [JSONValue], kind: ResourceKind) -> String {
            var columns = columns(for: kind)
            if kind == .template, items.contains(where: { $0["chatPreview"].string != nil }) {
                columns.append(Column(title: "CHAT PREVIEW", maxWidth: 80) { $0["chatPreview"].string })
            }
            let header = columns.map(\.title)
            let rows = items.map { item in
                columns.map { column -> String in
                    let text = TerminalText.singleLine(column.value(item) ?? "")
                    guard let limit = column.maxWidth else { return text }
                    return TerminalText.truncate(text, toWidth: limit)
                }
            }
            let allRows = [header] + rows
            let widths = columns.indices.map { index in
                allRows.map { TerminalText.displayWidth($0[index]) }.max() ?? 0
            }
            return allRows.map { row in
                var line = ""
                for (index, cell) in row.enumerated() {
                    line += cell
                    if index < row.count - 1 {
                        line += String(repeating: " ", count: widths[index] - TerminalText.displayWidth(cell) + 2)
                    }
                }
                while line.last == " " { line.removeLast() }
                return line + "\n"
            }.joined()
        }

        private static func columns(for kind: ResourceKind) -> [Column] {
            let id = Column(title: "ID") { scalarText($0["id"]) }
            switch kind {
            case .conversation:
                return [
                    id,
                    Column(title: "NUMBER") { scalarText($0["number"]) },
                    Column(title: "STATUS") { $0["status"].string },
                    Column(title: "CUSTOMER") { conversation in
                        let customer = conversation["primaryCustomer"]
                        let email = customer["email"].string ?? ""
                        return email.isEmpty ? personName(customer) : email
                    },
                    Column(title: "SUBJECT", maxWidth: 80) { $0["subject"].string },
                    Column(title: "PREVIEW", maxWidth: 200) { $0["preview"].string },
                ]
            case .customer:
                return [
                    id,
                    Column(title: "NAME", maxWidth: 40) { personName($0) },
                    Column(title: "EMAIL") { customer in
                        (customer["_embedded"]["emails"].array ?? [])
                            .compactMap { $0["value"].string }
                            .joined(separator: ", ")
                    },
                ]
            case .inbox:
                return [
                    id,
                    Column(title: "NAME", maxWidth: 40) { $0["name"].string },
                    Column(title: "EMAIL") { $0["email"].string },
                ]
            case .template:
                return [
                    id,
                    Column(title: "NAME", maxWidth: 40) { $0["name"].string },
                    Column(title: "PREVIEW", maxWidth: 80) { $0["preview"].string },
                ]
            }
        }
    }
}
