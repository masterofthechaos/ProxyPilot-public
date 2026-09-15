import ArgumentParser

@main
struct ProxyPilotCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "proxypilot",
        abstract: "Local AI proxy server for Xcode and agentic coding.",
        version: "1.16.2",
        subcommands: [CapabilitiesCommand.self, ProvidersCommand.self, RouteCommand.self, RuntimeCommand.self, TelemetryCommand.self, RequestCommand.self, StartCommand.self, StopCommand.self, StatusCommand.self, ModelsCommand.self, LogsCommand.self, ConfigCommand.self, AgentCommand.self, ACPCommand.self, AuthCommand.self, SetupCommand.self, LaunchCommand.self, UpdateCommand.self, ServeCommand.self, SessionsCommand.self]
    )
}
