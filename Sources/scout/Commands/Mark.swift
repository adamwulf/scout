import ArgumentParser
import ScoutKit

struct Mark: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Change a conversation's status without sending a reply.")
    @OptionGroup var connection: ConnectionOptions
    @Argument(help: "Target status: active (reopen), pending, closed, or spam.") var status: ReplyStatus
    @Argument(help: "Help Scout API conversation ID.") var id: Int

    mutating func validate() throws { try ScoutClient.positive(id, name: "Conversation ID") }

    func run() async throws {
        let receipt = try await connection.context().client.mark(conversation: id, status: status)
        CLI.output(try OutputFormatter.receipt(receipt))
    }
}
