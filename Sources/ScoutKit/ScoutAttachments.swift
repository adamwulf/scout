import CryptoKit
import Foundation

/// The outcome of saving a conversation's attachments and Help Scout inline images. Each selected item appears in
/// exactly one list.
public struct AttachmentDownload: Sendable, Equatable {
    /// What a saved file or problem refers to.
    public enum Source: Sendable, Equatable {
        /// A Help Scout attachment by ID; nil only when Help Scout listed an attachment without an ID.
        case attachment(Int?)
        /// An image in a thread body hosted on Help Scout's CDN, by its `src` URL. Inline images have no attachment ID.
        case inlineImage(String)
    }

    public struct Saved: Sendable, Equatable {
        public let source: Source
        public let filename: String
        /// The output directory as given, with `~` expanded, joined with the saved file name.
        public let path: String
        public let byteCount: Int
    }

    public struct Problem: Sendable, Equatable {
        public let source: Source
        public let filename: String
        public let reason: String
    }

    public internal(set) var saved: [Saved] = []
    public internal(set) var skipped: [Problem] = []
    public internal(set) var failed: [Problem] = []

    public var isEmpty: Bool { saved.isEmpty && skipped.isEmpty && failed.isEmpty }

    /// Saved file paths by attachment ID, for linking from markdown.
    public var attachmentPaths: [Int: String] {
        Dictionary(saved.compactMap { item -> (Int, String)? in
            guard case .attachment(let id?) = item.source else { return nil }
            return (id, item.path)
        }, uniquingKeysWith: { first, _ in first })
    }

    /// Saved file paths by inline image `src`, for embedding in markdown.
    public var inlineImagePaths: [String: String] {
        Dictionary(saved.compactMap { item -> (String, String)? in
            guard case .inlineImage(let source) = item.source else { return nil }
            return (source, item.path)
        }, uniquingKeysWith: { first, _ in first })
    }
}

extension ScoutClient {
    /// Saves the attachments of every thread in `view`, and every distinct Help Scout inline image shown in thread
    /// bodies, into `directory`, creating it when there is something to download, and returns what was saved,
    /// skipped and failed. Attachments are named `<attachment ID>-<filename>` and inline images
    /// `inline-<hash>-<filename>`, with the filename reduced to one safe path component, so a repeated download
    /// atomically replaces the same file. Attachments Help Scout flags as viruses are skipped. Inline images are
    /// fetched from Help Scout's CDN without credentials, oldest thread first and once per `src`; external images
    /// and tracking pixels are never fetched. One failed item does not stop the others. With `only`, just that
    /// attachment is saved and no inline images; it must exist and not be virus-flagged.
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
        let images = attachmentID == nil ? Self.inlineImages(in: view.threads) : []

        let folder = (directory as NSString).expandingTildeInPath
        if !images.isEmpty || attachments.contains(where: { ($0["id"].int ?? 0) > 0 && !Self.isVirus($0) }) {
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
                result.skipped.append(.init(source: .attachment(nil), filename: filename, reason: "Help Scout listed it without an attachment ID."))
                continue
            }
            if Self.isVirus(attachment) {
                result.skipped.append(.init(source: .attachment(id), filename: filename, reason: "Help Scout flagged it as a virus."))
                continue
            }
            let path = Self.path(in: folder, name: Self.attachmentFileName(id: id, filename: filename))
            do {
                let data = try await attachmentData(conversation: conversationID, attachment: id)
                try data.write(to: URL(fileURLWithPath: path), options: .atomic)
                result.saved.append(.init(source: .attachment(id), filename: filename, path: path, byteCount: data.count))
            } catch {
                result.failed.append(.init(source: .attachment(id), filename: filename, reason: error.localizedDescription))
            }
        }
        for image in images {
            let path = Self.path(in: folder, name: Self.inlineImageFileName(image))
            do {
                let data = try await http.inlineImageData(image.url)
                try data.write(to: URL(fileURLWithPath: path), options: .atomic)
                result.saved.append(.init(source: .inlineImage(image.source), filename: image.filename, path: path, byteCount: data.count))
            } catch {
                result.failed.append(.init(source: .inlineImage(image.source), filename: image.filename, reason: error.localizedDescription))
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

    /// The Help Scout inline images markdown shows in thread bodies, oldest thread first, without repeating a `src`.
    static func inlineImages(in threads: [JSONValue]) -> [InlineImage] {
        var seen: Set<String> = []
        return OutputFormatter.Markdown.sortedOldestFirst(threads)
            .flatMap { OutputFormatter.HTMLText.render($0["body"].string ?? "").inlineImages }
            .filter { seen.insert($0.source).inserted }
    }

    static func isVirus(_ attachment: JSONValue) -> Bool {
        attachment["state"].string == "virus"
    }

    private static func path(in folder: String, name: String) -> String {
        folder.hasSuffix("/") ? folder + name : folder + "/" + name
    }

    /// `<id>-<name>`; see `safeFileName(prefix:filename:fallback:)`.
    static func attachmentFileName(id: Int, filename: String) -> String {
        safeFileName(prefix: "\(id)-", filename: filename, fallback: "attachment")
    }

    /// `inline-<hash>-<name>`, where the hash is the first 12 hex digits of the SHA-256 of the image's `src`, so
    /// every image URL gets its own file even when URL file names repeat; see `safeFileName(prefix:filename:fallback:)`.
    static func inlineImageFileName(_ image: InlineImage) -> String {
        let hash = SHA256.hash(data: Data(image.source.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        return safeFileName(prefix: "inline-\(hash)-", filename: image.filename, fallback: "image")
    }

    /// `prefix` followed by the name as one safe path component: control and bidirectional characters are removed,
    /// whitespace is collapsed, and characters that separate paths, end markdown link destinations, or act as URL
    /// syntax in links (`#`, `?`, `%`) become `_`. The prefix keeps names unique and rules out `.`, `..` and hidden
    /// files. Long names are shortened to the 255-byte file-name limit, keeping a short extension.
    private static func safeFileName(prefix: String, filename: String, fallback: String) -> String {
        let replaced: Set<Unicode.Scalar> = ["/", "\\", ":", "<", ">", "#", "?", "%"]
        let cleaned = OutputFormatter.TerminalText.singleLine(filename).unicodeScalars.map { replaced.contains($0) ? "_" : $0 }
        var name = String(String.UnicodeScalarView(cleaned))
        if name.isEmpty { name = fallback }
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
