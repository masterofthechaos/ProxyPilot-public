import ArgumentParser

@main
struct ProxyPilotCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "proxypilot",
        abstract: "Local AI proxy server for Xcode and agentic coding.",
        version: "1.5.0",
        subcommands: [StartCommand.self, StopCommand.self, StatusCommand.self, ModelsCommand.self, LogsCommand.self, ConfigCommand.self, AuthCommand.self, SetupCommand.self, LaunchCommand.self, UpdateCommand.self, ServeCommand.self]
    )
}
