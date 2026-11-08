import Foundation

extension OutputFormatter {
    /// Labeled, readable markdown for single resources and conversations.
    enum Markdown {
        static func detail(_ value: JSONValue, kind: ResourceKind) -> String {
            var document = Document()
            switch kind {
            case .inbox: inbox(value, into: &document)
            case .conversation: conversationHeader(value, into: &document)
            case .customer: customer(value, into: &document)
            case .template: template(value, into: &document)
            }
            return document.text
        }

        static func conversation(_ value: JSONValue, threads: [JSONValue]) -> String {
            var document = Document()
            conversationHeader(value, into: &document)
            let sorted = sortedOldestFirst(threads)
            document.heading(2, sorted.isEmpty ? "Threads" : "Threads (\(sorted.count), oldest first)")
            if sorted.isEmpty { document.paragraph("No threads.") }
            for (offset, thread) in sorted.enumerated() {
                self.thread(thread, number: offset + 1, into: &document)
            }
            return document.text
        }

        // MARK: Resources

        private static func inbox(_ value: JSONValue, into document: inout Document) {
            document.heading(1, value["name"].string ?? "Inbox")
            document.fields([
                ("ID", scalarText(value["id"])),
                ("Email", value["email"].string),
                ("Slug", value["slug"].string),
                ("Created", value["createdAt"].string),
                ("Updated", value["updatedAt"].string),
            ])
        }

        private static func template(_ value: JSONValue, into document: inout Document) {
            document.heading(1, value["name"].string ?? "Saved reply")
            document.fields([("ID", scalarText(value["id"]))])
            document.paragraph(HTMLText.plainText(value["text"].string ?? ""))
        }

        private static func customer(_ value: JSONValue, into document: inout Document) {
            let embedded = value["_embedded"]
            let name = personName(value)
            document.heading(1, name.isEmpty ? "Customer" : name)
            document.fields([
                ("ID", scalarText(value["id"])),
                ("Emails", contactList(embedded["emails"])),
                ("Phones", contactList(embedded["phones"])),
                ("Chats", contactList(embedded["chats"])),
                ("Social profiles", contactList(embedded["social_profiles"])),
                ("Websites", contactList(embedded["websites"])),
                ("Organization", value["organization"].string),
                ("Job title", value["jobTitle"].string),
                ("Location", value["location"].string),
                ("Address", address(embedded["address"])),
                ("Conversations", scalarText(value["conversationCount"])),
                ("Created", value["createdAt"].string),
                ("Updated", value["updatedAt"].string),
            ])
            let properties = embedded["properties"].array ?? []
            if !properties.isEmpty {
                document.heading(2, "Properties")
                document.fields(properties.map { property in
                    let label = property["name"].string ?? property["slug"].string ?? "Property"
                    return (label, scalarText(property["text"]) ?? scalarText(property["value"]) ?? "(none)")
                })
            }
            if let background = value["background"].string, !background.isEmpty {
                document.heading(2, "Background")
                // Background is plain-text notes, not HTML: keep angle brackets and line breaks.
                document.paragraph(background)
            }
        }

        private static func contactList(_ entries: JSONValue) -> String? {
            let items = (entries.array ?? []).compactMap { entry -> String? in
                guard let value = scalarText(entry["value"]) else { return nil }
                guard let type = entry["type"].string, !type.isEmpty else { return value }
                return "\(value) (\(type))"
            }
            return items.isEmpty ? nil : items.joined(separator: ", ")
        }

        private static func address(_ address: JSONValue) -> String? {
            let lines = (address["lines"].array ?? []).compactMap(\.string)
            let parts = lines + ["city", "state", "postalCode", "country"].compactMap { address[$0].string }
            let nonempty = parts.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            return nonempty.isEmpty ? nil : nonempty.joined(separator: ", ")
        }

        // MARK: Conversations

        private static func conversationHeader(_ value: JSONValue, into document: inout Document) {
            let subject = value["subject"].string ?? ""
            document.heading(1, subject.isEmpty ? "(no subject)" : subject)
            let tags = (value["tags"].array ?? []).compactMap { $0["tag"].string ?? $0.string }
            document.fields([
                ("ID", scalarText(value["id"])),
                ("Number", scalarText(value["number"])),
                ("Status", value["status"].string),
                ("State", value["state"].string),
                ("Type", value["type"].string),
                ("Inbox ID", scalarText(value["mailboxId"])),
                ("Customer", personLabel(value["primaryCustomer"])),
                ("Assignee", personLabel(value["assignee"])),
                ("Tags", tags.isEmpty ? nil : tags.joined(separator: ", ")),
                ("Created", value["createdAt"].string),
                ("Updated", value["userUpdatedAt"].string),
                ("Closed", value["closedAt"].string),
            ])
            let customFields = value["customFields"].array ?? []
            if !customFields.isEmpty {
                document.heading(2, "Custom fields")
                document.fields(customFields.map { field in
                    let label = field["name"].string ?? scalarText(field["id"]).map { "Field \($0)" } ?? "Field"
                    return (label, scalarText(field["text"]) ?? scalarText(field["value"]) ?? "(none)")
                })
            }
        }

        private static func thread(_ thread: JSONValue, number: Int, into document: inout Document) {
            document.heading(3, "\(number). \(threadTitle(thread))")
            let author = thread["createdBy"]
            let authorLabel = personLabel(author).map { label in
                author["type"].string.map { "\(label) (\($0))" } ?? label
            }
            let attachments = (thread["_embedded"]["attachments"].array ?? []).compactMap { attachment -> String? in
                guard let name = attachment["filename"].string else { return nil }
                let details = [attachment["mimeType"].string, attachment["state"].string == "virus" ? "virus detected" : nil]
                    .compactMap { $0 }
                return details.isEmpty ? name : "\(name) (\(details.joined(separator: ", ")))"
            }
            let actionText = thread["action"]["text"].string
            document.fields([
                ("Author", authorLabel ?? "Unknown"),
                ("Type", thread["type"].string),
                ("State", thread["state"].string),
                ("Status", thread["status"].string),
                ("Time", thread["createdAt"].string),
                ("To", addressList(thread["to"])),
                ("Cc", addressList(thread["cc"])),
                ("Bcc", addressList(thread["bcc"])),
                ("Action", actionText),
                ("Scheduled for", thread["scheduled"]["scheduledFor"].string),
                ("Attachments", attachments.isEmpty ? nil : attachments.joined(separator: ", ")),
            ])
            let body = HTMLText.plainText(thread["body"].string ?? "")
            if !body.isEmpty {
                document.paragraph(body)
            } else if actionText?.isEmpty ?? true {
                document.paragraph("(no body)")
            }
        }

        /// A heading that keeps drafts, unsent and sent replies visibly distinct.
        static func threadTitle(_ thread: JSONValue) -> String {
            let type = thread["type"].string ?? ""
            let base = threadTypeNames[type] ?? (type.isEmpty ? "Thread" : "Thread (\(type))")
            switch thread["state"].string ?? "" {
            case "draft": return "DRAFT \(base.lowercased()) (not sent)"
            case "review": return "\(base) awaiting review (not sent)"
            case "hidden": return "\(base) (hidden)"
            case "bounced": return "\(base) (bounced)"
            case "published", "": return type == "message" ? "\(base) (sent)" : base
            case let state: return "\(base) (state: \(state))"
            }
        }

        private static let threadTypeNames: [String: String] = [
            "customer": "Customer message", "message": "Reply", "note": "Note", "lineitem": "Activity",
            "chat": "Chat", "beaconchat": "Beacon chat", "phone": "Phone call",
            "forwardparent": "Forward", "forwardchild": "Forwarded conversation",
        ]

        private static func addressList(_ value: JSONValue) -> String? {
            let addresses = (value.array ?? []).compactMap { $0.string ?? $0["email"].string }
            return addresses.isEmpty ? nil : addresses.joined(separator: ", ")
        }

        /// Oldest first by `createdAt`, then by ID and original position so output is deterministic.
        /// Threads without a parseable timestamp go last.
        static func sortedOldestFirst(_ threads: [JSONValue]) -> [JSONValue] {
            let plain = ISO8601DateFormatter()
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let keyed = threads.enumerated().map { offset, thread in
                let date = thread["createdAt"].string.flatMap { plain.date(from: $0) ?? fractional.date(from: $0) }
                return (date: date, id: thread["id"].int ?? Int.max, offset: offset, thread: thread)
            }
            return keyed.sorted { lhs, rhs in
                switch (lhs.date, rhs.date) {
                case let (left?, right?) where left != right: return left < right
                case (.some, nil): return true
                case (nil, .some): return false
                default: return (lhs.id, lhs.offset) < (rhs.id, rhs.offset)
                }
            }.map(\.thread)
        }

        // MARK: Document

        struct Document {
            private var blocks: [String] = []

            var text: String { blocks.isEmpty ? "" : blocks.joined(separator: "\n\n") + "\n" }

            mutating func heading(_ level: Int, _ title: String) {
                blocks.append(String(repeating: "#", count: level) + " " + TerminalText.singleLine(title))
            }

            /// A `- Label: value` list that omits missing values.
            mutating func fields(_ fields: [(String, String?)]) {
                let lines = fields.compactMap { label, value -> String? in
                    let text = TerminalText.singleLine(value ?? "")
                    return text.isEmpty ? nil : "- \(TerminalText.singleLine(label)): \(text)"
                }
                if !lines.isEmpty { blocks.append(lines.joined(separator: "\n")) }
            }

            /// Body text. Lines that would start a markdown heading are escaped so message text
            /// cannot pose as another thread's heading.
            mutating func paragraph(_ text: String) {
                let safe = HTMLText.tidy(TerminalText.multiline(text))
                guard !safe.isEmpty else { return }
                let lines = safe.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
                    guard let hash = line.firstIndex(where: { $0 != " " }), line[hash] == "#" else { return String(line) }
                    return String(line[..<hash]) + "\\" + String(line[hash...])
                }
                blocks.append(lines.joined(separator: "\n"))
            }
        }
    }
}
