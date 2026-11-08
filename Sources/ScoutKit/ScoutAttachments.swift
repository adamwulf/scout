import Foundation

/// The outcome of saving a conversation's attachments. Each selected attachment appears in exactly one list.
public struct AttachmentDownload: Sendable, Equatable {
    public struct Saved: Sendable, Equatable {
        public let attachmentID: Int
        public let filename: String
        /// The output directory as given, with `~` expanded, joined with the saved file name.
        public let path: String
        public let byteCount: Int
    }

    public struct Problem: Sendable, Equatable {
        /// Nil only when Help Scout listed an attachment without an ID.
        public let attachmentID: Int?
        public let filename: String
        public let reason: String
    }

    public internal(set) var saved: [Saved] = []
    public internal(set) var skipped: [Problem] = []
    public internal(set) var failed: [Problem] = []

    public var isEmpty: Bool { saved.isEmpty && skipped.isEmpty && failed.isEmpty }

    /// Saved file paths by attachment ID, for linking from markdown.
    public var paths: [Int: String] {
        Dictionary(saved.map { ($0.attachmentID, $0.path) }, uniquingKeysWith: { first, _ in first })
    }
}

extension ScoutClient {
    /// Saves the attachments of every thread in `view` into `directory`, creating it when needed, and returns
    /// what was saved, skipped and failed. Files are named `<attachment ID>-<filename>` with the filename reduced
    /// to one safe path component, so a repeated download atomically replaces the same file. Attachments
    /// Help Scout flags as viruses are skipped. One failed attachment does not stop the others. With `only`,
    /// just that attachment is saved; it must exist and not be virus-flagged.
    public func downloadAttachments(in view: ConversationView, to directory: String, only attachmentID: Int? = nil) async throws -> AttachmentDownload {
        try Self.validateOutputDirectory(directory)
        if let attachmentID { try Self.positive(attachmentID, name: "Attachment ID") }
        let conversationID = try view.conversation.requiredID()
        var attachments = Self.attachments(in: view.threads)
        if let attachmentID {
            attachments = attachments.filter { $0["id"].int == attachmentID }
            guard let selected = attachments.first else {
                throw ScoutError.invalidInput("Attachment \(attachmentID) is not in conversation \(conversationID). Run show to list attachment IDs.")
            }
            if Self.isVirus(selected) {
                throw ScoutError.invalidInput("Help Scout flagged attachment \(attachmentID) as a virus. Scout does not download it.")
            }
        }

        let folder = (directory as NSString).expandingTildeInPath
        if attachments.contains(where: { ($0["id"].int ?? 0) > 0 && !Self.isVirus($0) }) {
            do {
                try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            } catch {
                throw ScoutError.invalidInput("Could not create the output directory \(folder): \(error.localizedDescription)")
            }
        }

        var result = AttachmentDownload()
        for attachment in attachments {
            let filename = attachment["filename"].string ?? ""
            guard let id = attachment["id"].int, id > 0 else {
                result.skipped.append(.init(attachmentID: nil, filename: filename, reason: "Help Scout listed it without an attachment ID."))
                continue
            }
            if Self.isVirus(attachment) {
                result.skipped.append(.init(attachmentID: id, filename: filename, reason: "Help Scout flagged it as a virus."))
                continue
            }
            let name = Self.attachmentFileName(id: id, filename: filename)
            let path = folder.hasSuffix("/") ? folder + name : folder + "/" + name
            do {
                let data = try await attachmentData(conversation: conversationID, attachment: id)
                try data.write(to: URL(fileURLWithPath: path), options: .atomic)
                result.saved.append(.init(attachmentID: id, filename: filename, path: path, byteCount: data.count))
            } catch {
                result.failed.append(.init(attachmentID: id, filename: filename, reason: error.localizedDescription))
            }
        }
        return result
    }

    public static func validateOutputDirectory(_ directory: String) throws {
        guard !directory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ScoutError.invalidInput("The output directory cannot be empty.")
        }
    }

    /// Help Scout returns attachment contents as base64 in a JSON `data` field.
    func attachmentData(conversation: Int, attachment: Int) async throws -> Data {
        let value = try await get("/v2/conversations/\(conversation)/attachments/\(attachment)/data")
        guard let text = value["data"].string, let data = Data(base64Encoded: text, options: .ignoreUnknownCharacters) else {
            throw ScoutError.decoding("Help Scout returned no valid base64 data for attachment \(attachment).")
        }
        return data
    }

    /// Attachments from threads oldest first, matching markdown order, without repeating an ID.
    static func attachments(in threads: [JSONValue]) -> [JSONValue] {
        var seen: Set<Int> = []
        return OutputFormatter.Markdown.sortedOldestFirst(threads)
            .flatMap { $0["_embedded"]["attachments"].array ?? [] }
            .filter { attachment in attachment["id"].int.map { seen.insert($0).inserted } ?? true }
    }

    static func isVirus(_ attachment: JSONValue) -> Bool {
        attachment["state"].string == "virus"
    }

    /// `<id>-<name>`, where the name is one safe path component: control and bidirectional characters are
    /// removed, whitespace is collapsed, and characters that separate paths, end markdown link destinations,
    /// or act as URL syntax in links (`#`, `?`, `%`) become `_`. The ID prefix keeps names unique and rules
    /// out `.`, `..` and hidden files. Long names are shortened to the 255-byte file-name limit, keeping a
    /// short extension.
    static func attachmentFileName(id: Int, filename: String) -> String {
        let replaced: Set<Unicode.Scalar> = ["/", "\\", ":", "<", ">", "#", "?", "%"]
        let cleaned = OutputFormatter.TerminalText.singleLine(filename).unicodeScalars.map { replaced.contains($0) ? "_" : $0 }
        var name = String(String.UnicodeScalarView(cleaned))
        if name.isEmpty { name = "attachment" }
        let prefix = "\(id)-"
        let limit = 255 - prefix.utf8.count
        if name.utf8.count > limit {
            let pathExtension = (name as NSString).pathExtension
            let suffix = pathExtension.isEmpty || pathExtension.utf8.count > 16 ? "" : "." + pathExtension
            var stem = String(name.dropLast(suffix.count))
            while stem.utf8.count + suffix.utf8.count > limit { stem.removeLast() }
            name = stem + suffix
        }
        return prefix + name
    }
}
