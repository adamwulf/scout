import Foundation

public struct DraftReceipt: Codable, Sendable {
    public enum Operation: String, Codable, Sendable {
        case created, updated, sent
    }

    public let conversationID: Int
    public let threadID: Int?
    public let operation: Operation
}

extension ScoutClient {
    /// Creates a draft only when none exists; otherwise updates the selected draft's body.
    /// Refuses scheduled drafts, because changing their text changes a reply Help Scout will send automatically.
    public func saveDraft(conversation id: Int, thread threadID: Int? = nil, content: ReplyContent) async throws -> DraftReceipt {
        if let threadID { try Self.positive(threadID, name: "Thread ID") }
        let literal = try Self.literalReply(content)
        let view = try await show(id)
        let draft = try Self.selectDraft(in: view, threadID: threadID)
        if let draft, draft["scheduled"] != .null {
            let selectedID = try draft.requiredID()
            throw ScoutError.invalidInput("Draft \(selectedID) in conversation \(id) is scheduled to send automatically. Scout does not edit scheduled drafts; change or unschedule it in Help Scout.")
        }
        let text = try await replyText(content, literal: literal, conversation: view.conversation)
        if let draft {
            let selectedID = try draft.requiredID()
            _ = try await http.request(method: "PATCH", path: "/v2/conversations/\(id)/threads/\(selectedID)", body: .object([
                "op": .string("replace"), "path": .string("/text"), "value": .string(text)
            ]))
            return DraftReceipt(conversationID: id, threadID: selectedID, operation: .updated)
        }
        let receipt = try await postReply(conversation: view.conversation, text: text, draft: true, status: nil)
        return DraftReceipt(conversationID: id, threadID: receipt.threadID, operation: .created)
    }

    /// Publishes an existing reply draft, scheduling it first if necessary. This is not atomic:
    /// a failure or interruption can leave a scheduled send, or publication may already have succeeded.
    public func sendDraft(conversation id: Int, thread threadID: Int? = nil) async throws -> DraftReceipt {
        if let threadID { try Self.positive(threadID, name: "Thread ID") }
        let view = try await show(id)
        guard let draft = try Self.selectDraft(in: view, threadID: threadID) else {
            throw ScoutError.invalidInput("No draft found in conversation \(id).")
        }
        let selectedID = try draft.requiredID()
        try Self.validateDraftForSending(draft)
        let path = "/v2/conversations/\(id)/threads/\(selectedID)/schedule"
        let schedule = draft["scheduled"]
        if schedule == .null {
            let scheduledFor = ISO8601DateFormatter().string(from: clock().addingTimeInterval(24 * 60 * 60))
            do {
                _ = try await http.request(method: "PUT", path: path, body: .object([
                    "scheduledFor": .string(scheduledFor),
                    "unscheduleOnCustomerReply": .bool(true), "sendAsCreator": .bool(false)
                ]))
            } catch {
                throw Self.draftSendFailure(error, conversation: id, thread: selectedID, publishing: false)
            }
        } else {
            guard schedule.object != nil, let time = schedule["scheduledFor"].string,
                  !time.isEmpty else {
                throw ScoutError.decoding("Draft \(selectedID) has incomplete schedule data. Inspect conversation \(id) in Help Scout before sending.")
            }
        }
        do {
            _ = try await http.request(method: "PATCH", path: path, body: .object([
                "op": .string("replace"), "path": .string("/state"), "value": .string("published")
            ]))
        } catch {
            throw Self.draftSendFailure(error, conversation: id, thread: selectedID, publishing: true)
        }
        return DraftReceipt(conversationID: id, threadID: selectedID, operation: .sent)
    }

    private static func selectDraft(in view: ConversationView, threadID: Int?) throws -> JSONValue? {
        let id = try view.conversation.requiredID()
        let selected: JSONValue
        if let threadID {
            guard let thread = view.threads.first(where: { $0["id"].int == threadID }),
                  thread["state"].string == "draft" else {
                throw ScoutError.invalidInput("Thread \(threadID) is not a draft in conversation \(id). Inspect the conversation and select an existing draft.")
            }
            selected = thread
        } else {
            // Count every draft type so unsupported drafts never trigger accidental creation.
            let drafts = view.threads.filter { $0["state"].string == "draft" }
            guard !drafts.isEmpty else { return nil }
            guard drafts.count == 1 else {
                let ids = try drafts.map { String(try $0.requiredID()) }.joined(separator: ", ")
                throw ScoutError.invalidInput("Multiple drafts found in conversation \(id): \(ids). Select one with --thread ID.")
            }
            selected = drafts[0]
        }
        let selectedID = try selected.requiredID()
        guard selected["type"].string == "message" else {
            throw ScoutError.invalidInput("Draft \(selectedID) in conversation \(id) is not a supported reply draft. Edit or send this draft in Help Scout.")
        }
        return selected
    }

    private static func validateDraftForSending(_ draft: JSONValue) throws {
        let body = draft["body"].string ?? ""
        // Decode entities for validation only; never replace or echo the server-side body.
        let decoded = OutputFormatter.HTMLText.decodeEntities(body)
        guard !decoded.contains("{%"), !OutputFormatter.HTMLText.plainText(body).contains("{%") else {
            throw ScoutError.invalidInput("The draft contains an unresolved Help Scout variable. Update it with literal text before sending.")
        }
        let hasAttachments = !(draft["_embedded"]["attachments"].array ?? []).isEmpty
        guard hasAttachments || OutputFormatter.HTMLText.hasContent(body) else {
            throw ScoutError.invalidInput("The draft body is empty. Update the draft before sending.")
        }
    }

    private static func draftSendFailure(_ error: Error, conversation: Int, thread: Int, publishing: Bool) -> ScoutError {
        let rejected: Bool
        if case ScoutError.api(let status, _) = error {
            rejected = (400..<500).contains(status) && status != 408
        } else { rejected = false }
        let outcome: String
        if publishing {
            outcome = rejected
                ? "Publication was rejected. The draft was scheduled and may still send at its scheduled time."
                : "Publication could not be confirmed. The reply may already have been sent, or the draft may remain scheduled and send later."
        } else {
            outcome = rejected
                ? "Scheduling was rejected. This command did not attempt publication."
                : "Scheduling could not be confirmed. The draft may be scheduled and send later. This command did not attempt publication."
        }
        return .draftSend("Could not complete sending draft \(thread) in conversation \(conversation). \(outcome) Inspect the thread in Help Scout and cancel any remaining schedule before retrying. \(error.localizedDescription)")
    }
}
