#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import ProxyPilotCore

@main
struct ProxyPilotAgent {
    static func main() async {
        let settings = AgentLaunchSettings.resolve()
        record("launcher_started", settings: settings)

        do {
            let bootstrap = try await ProxyDaemonBootstrapper.ensureRunning(settings: settings)
            record(
                bootstrap.outcome == .started ? "proxy_started" : "proxy_already_running",
                settings: settings
            )
            let localProxyCredential = try LocalProxyCredential.resolveOrCreate(
                using: SecretsProviderFactory.make()
            )
            let plan = try AgentAdapterLaunchPlan.make(
                settings: settings,
                localProxyCredential: localProxyCredential
            )
            record("adapter_exec", settings: settings, detail: plan.adapterTelemetryDetail)
            exec(plan: plan, settings: settings)
        } catch {
            fail(code: errorCode(for: error), message: error.localizedDescription, settings: settings)
        }
    }

    private static func exec(plan: AgentAdapterLaunchPlan, settings: AgentLaunchSettings) -> Never {
        let arguments = plan.arguments.map { strdup($0) } + [nil]
        let environment = plan.environment
            .sorted { $0.key < $1.key }
            .map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            arguments.forEach { pointer in
                if let pointer { free(pointer) }
            }
            environment.forEach { pointer in
                if let pointer { free(pointer) }
            }
        }

        execve(plan.executable.path, arguments, environment)
        let message = String(cString: strerror(errno))
        fail(code: "E4-EXEC", message: "Could not launch the managed adapter: \(message)", settings: settings)
    }

    private static func errorCode(for error: Error) -> String {
        switch error {
        case is ProxyDaemonBootstrapError:
            "E2-DAEMON"
        case AgentAdapterLaunchError.nodeMissing:
            "E4-RUNTIME"
        case AgentAdapterLaunchError.adapterMissing:
            "E4-ADAPTER"
        case is AgentAdapterLaunchError:
            "E4-RUNTIME"
        default:
            "E4-LAUNCH"
        }
    }

    private static func fail(
        code: String,
        message: String,
        settings: AgentLaunchSettings
    ) -> Never {
        record("launcher_failed", settings: settings, detail: "\(code): \(message)")
        let line = "ProxyPilot Agent error [\(code)]: \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
        exit(EXIT_FAILURE)
    }

    private static func record(
        _ name: String,
        settings: AgentLaunchSettings,
        detail: String? = nil
    ) {
        try? AgentLaunchTelemetry.record(.init(
            name: name,
            settings: settings,
            detail: detail
        ))
    }
}

private extension AgentAdapterLaunchPlan {
    var adapterTelemetryDetail: String {
        arguments.dropFirst().first ?? "unknown adapter"
    }
}
