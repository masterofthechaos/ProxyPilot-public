import ArgumentParser

struct AuthCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "auth",
        abstract: "Manage stored upstream API keys.",
        subcommands: [
            AuthSetCommand.self,
            AuthStatusCommand.self,
            AuthRemoveCommand.self,
        ]
    )
}
