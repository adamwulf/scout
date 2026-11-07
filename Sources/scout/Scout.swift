import ArgumentParser
import ScoutKit

@main
struct Scout: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "scout", abstract: "Work with Help Scout inboxes.")
}
