#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import ArgumentParser
import Foundation
import ProxyPilotCore

struct RouteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "route", abstract: "Manage the shared CLI-owned route.", subcommands: [RouteStatusCommand.self, RouteSetCommand.self, RouteEnsureCommand.self])
}

// `RouteSelection` and the route.json/route.lock accessors live in
// Support/RouteStateStore.swift so the MCP `proxy_route_set` tool writes through
// the same store and lock as this command.
private typealias RouteState = RouteStateStore

private enum RouteReadiness {
    static func models(port: UInt16) async -> Set<String>? {
        guard let url = URL(string: "http://127.0.0.1:\(port)/v1/models"),
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = object["data"] as? [[String: Any]] else { return nil }
        return Set(entries.compactMap { $0["id"] as? String })
    }
    static func selected(port: UInt16, model: String) async -> Bool {
        guard PidFile.read() != nil, let ids = await models(port: port) else { return false }
        return ids.contains(model) && ids.contains(ActiveModelAlias.id)
    }
}

struct RouteStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status")
    @Flag(name: .long) var json = false
    func run() async throws {
        try await RouteStatusReporter.run(json: json)
    }
}

/// Emits route status without constructing an ArgumentParser command by hand.
/// Property-wrapper-backed commands are valid only after ArgumentParser parses
/// them; direct initialization traps as soon as a wrapped property is read.
enum RouteStatusReporter {
    static func run(json: Bool) async throws {
        let selected = RouteState.load(); let selectedPort = selected?.port ?? 4000; let probe = await CLIProxyRuntime.probeProxy(on: selectedPort); let pid = PidFile.read()
        let applied = if let selected { await RouteReadiness.selected(port: selected.port, model: selected.model) } else { false }
        let verificationState = applied ? "models_ready" : (probe.reachable ? "mismatched" : "stopped")
        let metadata = selected.flatMap { selection -> UpstreamModel? in
            guard let provider = UpstreamProvider(rawValue: selection.provider) else { return nil }
            return provider.knownModelMetadata(for: selection.model)
        }
        let contextValue: Any = (metadata?.contextLength as Any?) ?? NSNull()
        let inputPriceValue: Any = (metadata?.promptPricePer1M as Any?) ?? NSNull()
        let outputPriceValue: Any = (metadata?.completionPricePer1M as Any?) ?? NSNull()
        let cacheReadPriceValue: Any = (metadata?.promptCacheHitPricePer1M as Any?) ?? NSNull()
        let cacheMissPriceValue: Any = (metadata?.promptCacheMissPricePer1M as Any?) ?? NSNull()
        let cacheWritePriceValue: Any = (metadata?.promptCacheWritePricePer1M as Any?) ?? NSNull()
        let currencyValue: Any = metadata == nil ? (NSNull() as Any) : ("USD" as Any)
        guard json else {
            if let selected {
                print("Route:   \(selected.provider) / \(selected.model) (port \(selected.port))")
            } else {
                print("Route:   none selected (port \(selectedPort))")
            }
            print("Applied: \(applied ? "yes" : "no")")
            print("Proxy:   \(probe.reachable ? "reachable" : "not reachable"), owner \(pid == nil ? "none" : "cli")")
            print("State:   \(verificationState)")
            return
        }
        let payload: [String: Any] = [
            "selected": selected != nil,
            "applied": applied,
            "reachable": probe.reachable,
            "owner": pid == nil ? "none" : "cli",
            "provider": selected?.provider ?? NSNull(),
            "model": selected?.model ?? NSNull(),
            "selected_model": selected?.model ?? NSNull(),
            "applied_model": applied ? (selected?.model ?? NSNull()) : NSNull(),
            "port": Int(selectedPort),
            "verification_state": verificationState,
            "limits": ["context": contextValue, "output": NSNull()],
            "pricing": [
                "input_per_million": inputPriceValue,
                "output_per_million": outputPriceValue,
                "cache_read_per_million": cacheReadPriceValue,
                "cache_miss_per_million": cacheMissPriceValue,
                "cache_write_per_million": cacheWritePriceValue,
                "currency": currencyValue,
            ],
            "metadata_provenance": metadata == nil ? "unavailable" : "provider_known_catalog",
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]); print(String(decoding: data, as: UTF8.self))
    }
}

struct RouteSetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set")
    @Option(name: .long) var provider: String
    @Option(name: .long) var model: String
    @Option(name: .long) var port: UInt16 = 4000
    @Flag(name: .long) var json = false
    func run() async throws {
        do {
            try await RouteState.withExclusiveLock {
                let previous = RouteState.load()
                if let pid = PidFile.read() {
                    guard kill(pid, SIGTERM) == 0 else { throw ValidationError("Could not stop CLI-owned route") }
                    for _ in 0..<100 { if !PidFile.isProcessRunning(pid: pid), await RouteReadiness.models(port: port) == nil { break }; try? await Task.sleep(for: .milliseconds(100)) }
                    if await RouteReadiness.models(port: port) != nil {
                        guard kill(pid, SIGKILL) == 0 else { throw ValidationError("Previous CLI-owned route did not release port \(port), and force-stop failed") }
                        for _ in 0..<50 { if await RouteReadiness.models(port: port) == nil { break }; try? await Task.sleep(for: .milliseconds(100)) }
                    }
                    PidFile.remove()
                    guard await RouteReadiness.models(port: port) == nil else { throw ValidationError("Previous CLI-owned route did not release port \(port)") }
                }
                else if (await CLIProxyRuntime.probeProxy(on: port)).reachable { throw ValidationError("Port \(port) is owned by the GUI or an unmanaged listener; refusing to stop it") }
                do { try await start(provider: provider, model: model, port: port); try RouteState.save(.init(provider: provider, model: model, port: port, updatedAt: Date())) }
                catch { if let previous { try? await start(provider: previous.provider, model: previous.model, port: previous.port) }; throw error }
            }
        } catch is RouteLockUnavailable {
            throw ValidationError("Another route switch is in progress")
        }
        try await RouteStatusReporter.run(json: json)
    }
    private func start(provider: String, model: String, port: UInt16) async throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]); process.arguments = ["start", "--provider", provider, "--model", model, "--port", String(port), "--daemon", "--json"]
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe; try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ValidationError(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)) }
        for _ in 0..<100 { if await RouteReadiness.selected(port: port, model: model) { return }; try? await Task.sleep(for: .milliseconds(100)) }
        throw ValidationError("Route became reachable without the requested model and managed PID")
    }
}

struct RouteEnsureCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ensure")
    @Flag(name: .long) var json = false
    func run() async throws {
        if let selected = RouteState.load(), !(await CLIProxyRuntime.probeProxy(on: selected.port)).reachable {
            let process = Process(); process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]); process.arguments = ["route", "set", "--provider", selected.provider, "--model", selected.model, "--port", String(selected.port), "--json"]
            process.standardOutput = FileHandle.standardOutput; process.standardError = FileHandle.standardError
            try process.run(); process.waitUntilExit(); guard process.terminationStatus == 0 else { throw ExitCode.failure }
        } else {
            // Deliberately unconditional JSON: `rgps` invokes `route ensure`
            // directly and predates the --json flag being honored, so switching
            // this to human output on a bare invocation would break it. Revisit
            // once the RepoGPS side is known to pass --json.
            try await RouteStatusReporter.run(json: true)
        }
    }
}
