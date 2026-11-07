import Foundation

public enum ScoutError: Error, LocalizedError, Equatable, Sendable {
    case invalidInput(String)
    case configuration(String)
    case api(status: Int, message: String)
    case transport(String)
    case decoding(String)
    case merged(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidInput(let message), .configuration(let message), .transport(let message), .decoding(let message):
            return message
        case .api(let status, let message): return "HTTP \(status): \(message)"
        case .merged(let id): return "Conversation was merged into \(id). Inspect and rerun with that conversation ID."
        }
    }
}
