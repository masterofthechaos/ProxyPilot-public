import ArgumentParser

struct ConfigCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Manage Xcode Agent config routing for ProxyPilot.",
        subcommands: [
            ConfigInstallCommand.self,
            ConfigRemoveCommand.self,
            ConfigStatusCommand.self,
        ]
    )
}
