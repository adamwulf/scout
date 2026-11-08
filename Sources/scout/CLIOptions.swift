import ArgumentParser
import Foundation
import ScoutKit

struct ConnectionOptions: ParsableArguments {
    @Option(help: "Credential file; otherwise use the first .env that sets credentials, searching upward from the current directory.")
    var envFile: String?

    func context() throws -> (configuration: ScoutConfiguration, client: ScoutClient) {
        let configuration = try ScoutConfiguration.load(envFile: envFile)
        return (configuration, ScoutClient(configuration: configuration))
    }

    func command(_ name: String, arguments: [String] = []) -> [String] {
        let prefix = CommandLine.arguments.dropFirst().first == "ro" ? ["scout", "ro"] : ["scout"]
        return prefix + [name] + arguments + (envFile.map { ["--env-file", $0] } ?? [])
    }
}

struct ListOptions: ParsableArguments {
    @Option(help: "Output format: table, json, jsonl, id.") var format: ListFormat = .table
}

struct DetailOptions: ParsableArguments {
    @Option(help: "Output format: md or json.") var format: DetailFormat = .markdown
    mutating func validate() throws {
        guard format != .raw else { throw ValidationError("Raw output is only available for template.") }
    }
}

enum CLI {
    static func output(_ text: String) { print(text, terminator: "") }
    static func hint(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }

    static func page(_ page: ResourcePage, kind: ResourceKind, format: ListFormat, command: [String]) throws {
        output(try OutputFormatter.list(page, kind: kind, format: format))
        if let next = OutputFormatter.continuation(command: command, page: page) { hint("Next: " + next) }
    }

    /// Prints skipped and failed attachments to stderr and exits nonzero when any download failed.
    static func report(_ download: AttachmentDownload) throws {
        OutputFormatter.attachmentProblems(download).forEach(hint)
        if !download.failed.isEmpty { throw ExitCode.failure }
    }

    static func receipt(_ receipt: ReplyReceipt) throws {
        output(try OutputFormatter.receipt(receipt))
        if receipt.threadID == nil {
            hint("Help Scout accepted the reply but returned no thread ID. Inspect the conversation before retrying.")
        }
    }
}
