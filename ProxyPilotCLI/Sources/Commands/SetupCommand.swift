import ArgumentParser

struct SetupCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "Run guided setup workflows for ProxyPilot.",
        subcommands: [
            SetupXcodeCommand.self,
        ]
    )
}
