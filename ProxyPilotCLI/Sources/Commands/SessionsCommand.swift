import ArgumentParser

struct SessionsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sessions",
        abstract: "Browse recorded proxy sessions and, when enabled, their input/output logs.",
        subcommands: [
            SessionsListCommand.self,
            SessionsShowCommand.self,
            SessionsExportCommand.self,
            SessionsImportCommand.self,
        ]
    )
}
