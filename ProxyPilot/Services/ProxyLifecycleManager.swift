import Combine
import Foundation
import ProxyPilotCore

@MainActor
final class ProxyLifecycleManager: ObservableObject {

    // MARK: - Callbacks (set by AppViewModel after init)

    var onClearIssue: (() -> Void)?
    var onApplyIssue: ((AppIssue) -> Void)?
    var onRefreshStatus: (() -> Void)?
    var telemetryTracker: ((_ name: String, _ payload: [String: String]) -> Void)?

    /// AppViewModel provides this closure so ProxyLifecycleManager can build a
    /// `LocalProxyServer.Config` from the current AppViewModel state without
    /// needing direct access to all the properties involved.
    var builtInProxyConfigBuilder: (() throws -> LocalProxyServer.Config)?

    /// AppViewModel provides this closure for proxy URL validation (localhost).
    var proxyURLValidator: ((_ requireLocalhost: Bool) throws -> ProxyURLValidation)?

    // MARK: - Dependencies

    let localProxyServer: LocalProxyServer
    let proxyService: ProxyService
    let healthMonitor: HealthMonitor

    // MARK: - Published Properties

    @Published var isRunning: Bool = false
    @Published var statusText: String = "Unknown"
    @Published var recoveryState: RecoveryState = .idle

    @Published var autoRestartEnabled: Bool = true {
        didSet {
            defaults.set(autoRestartEnabled, forKey: Self.autoRestartEnabledDefaultsKey)
        }
    }

    // MARK: - Internal State

    private let defaults: UserDefaults
    private(set) var expectedProxyRunning: Bool = false
    private var recoveryTask: Task<Void, Never>?
    private var proxyStateCancellable: AnyCancellable?

    private static let autoRestartEnabledDefaultsKey = "proxypilot.autoRestartEnabled"

    // MARK: - Computed Properties

    /// Whether the proxy is using built-in mode. Set by AppViewModel when it changes.
    var useBuiltInProxy: Bool = true

    // MARK: - Init

    init(
        defaults: UserDefaults = .standard,
        localProxyServer: LocalProxyServer,
        proxyService: ProxyService,
        healthMonitor: HealthMonitor
    ) {
        self.defaults = defaults
        self.localProxyServer = localProxyServer
        self.proxyService = proxyService
        self.healthMonitor = healthMonitor
        self.autoRestartEnabled = defaults.object(forKey: Self.autoRestartEnabledDefaultsKey) as? Bool ?? true

        // Bridge LocalProxyState → ProxyLifecycleManager so the menu bar icon updates
        // immediately when the NWListener state changes, without waiting for
        // an explicit refreshStatus() call.
        proxyStateCancellable = localProxyServer.state.$isRunning
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] running in
                guard let self, self.useBuiltInProxy else { return }
                self.isRunning = running
                self.statusText = self.statusTextForState(isRunning: running)
            }
    }

    // MARK: - Lifecycle Methods

    func startProxy() async {
        onClearIssue?()
        telemetryTracker?("proxy_start_clicked", ["mode": useBuiltInProxy ? "builtin" : "litellm"])

        do {
            if useBuiltInProxy {
                try startBuiltInProxy()
                try await validateBuiltInProxyCameUp()
            } else {
                try await proxyService.start()
                try await validateProxyCameUp()
            }
            expectedProxyRunning = true
            recoveryState = .monitoring
            telemetryTracker?("proxy_start_succeeded", ["mode": useBuiltInProxy ? "builtin" : "litellm"])
        } catch {
            expectedProxyRunning = false
            recoveryState = .idle
            let issue = issueFor(
                error,
                fallbackCode: .generic,
                fallbackTitle: String(localized: "Failed to Start Proxy"),
                fallbackActions: [.retryStart, .runPreflight, .exportDiagnostics]
            )
            onApplyIssue?(issue)
            telemetryTracker?("proxy_start_failed", ["code": issue.code.rawValue])
        }

        onRefreshStatus?()
    }

    func restartProxy() async {
        onClearIssue?()
        recoveryTask?.cancel()
        recoveryTask = nil
        do {
            if useBuiltInProxy {
                try stopBuiltInProxyIfRunning()
                try startBuiltInProxy()
                try await validateBuiltInProxyCameUp()
            } else {
                try await proxyService.restart()
                try await validateProxyCameUp()
            }
            expectedProxyRunning = true
            recoveryState = .monitoring
        } catch {
            expectedProxyRunning = false
            let issue = issueFor(
                error,
                fallbackCode: .generic,
                fallbackTitle: String(localized: "Failed to Restart Proxy"),
                fallbackActions: [.retryStart, .exportDiagnostics]
            )
            onApplyIssue?(issue)
        }
        onRefreshStatus?()
    }

    func stopProxy() async {
        onClearIssue?()
        expectedProxyRunning = false
        recoveryState = .idle
        recoveryTask?.cancel()
        recoveryTask = nil

        do {
            if useBuiltInProxy {
                try stopBuiltInProxyIfRunning()
            } else {
                try await proxyService.stop()
            }
        } catch {
            let issue = issueFor(
                error,
                fallbackCode: .generic,
                fallbackTitle: String(localized: "Failed to Stop Proxy"),
                fallbackActions: [.exportDiagnostics]
            )
            onApplyIssue?(issue)
        }

        onRefreshStatus?()
    }

    // MARK: - Recovery / Watchdog

    func handleUnexpectedStop() async {
        onRefreshStatus?()

        guard expectedProxyRunning else { return }
        guard autoRestartEnabled else {
            recoveryState = .degraded(reason: String(localized: "Proxy stopped unexpectedly and auto-restart is disabled."))
            onApplyIssue?(AppIssue(
                code: .generic,
                title: String(localized: "Proxy Stopped Unexpectedly"),
                message: String(localized: "Auto-restart is disabled. Start the proxy manually or enable auto-restart."),
                actions: [.retryStart, .exportDiagnostics]
            ))
            return
        }

        guard recoveryTask == nil else { return }

        recoveryTask = Task { [weak self] in
            guard let self else { return }
            let recovered = await self.healthMonitor.attemptRecovery(onState: { state in
                self.recoveryState = state
            }, operation: { _ in
                do {
                    if self.useBuiltInProxy {
                        try self.stopBuiltInProxyIfRunning()
                        try self.startBuiltInProxy()
                        try await self.validateBuiltInProxyCameUp()
                    } else {
                        try await self.proxyService.restart()
                        try await self.validateProxyCameUp()
                    }
                    self.expectedProxyRunning = true
                    self.onRefreshStatus?()
                    return true
                } catch {
                    self.onRefreshStatus?()
                    return false
                }
            })

            if !recovered {
                self.onApplyIssue?(AppIssue(
                    code: .generic,
                    title: String(localized: "Auto-Recovery Failed"),
                    message: String(localized: "Proxy stopped unexpectedly and automatic recovery exhausted all retries."),
                    actions: [.retryStart, .exportDiagnostics]
                ))
            }

            self.recoveryTask = nil
        }
    }

    func statusTextForState(isRunning: Bool) -> String {
        if isRunning {
            return recoveryState == .recovered ? String(localized: "Running (Recovered)") : String(localized: "Running")
        }

        switch recoveryState {
        case .recovering(let attempt, _):
            return String(localized: "Recovering") + " (\(attempt))"
        case .degraded:
            return String(localized: "Degraded")
        default:
            return String(localized: "Stopped")
        }
    }

    /// Called by AppViewModel during reset to clear lifecycle state.
    func resetForFreshInstall() {
        recoveryTask?.cancel()
        recoveryTask = nil
        expectedProxyRunning = false
        recoveryState = .idle
        autoRestartEnabled = true
    }

    // MARK: - Health Monitor Integration

    func startHealthMonitor() {
        healthMonitor.start(
            isRunning: { [weak self] in
                guard let self else { return false }
                return self.useBuiltInProxy ? self.localProxyServer.state.isRunning : self.proxyService.isRunning()
            },
            onUnexpectedStop: { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    await self.handleUnexpectedStop()
                }
            }
        )
    }

    func stopHealthMonitor() {
        healthMonitor.stop()
    }

    // MARK: - Private Helpers

    private func startBuiltInProxy() throws {
        guard let configBuilder = builtInProxyConfigBuilder else {
            preconditionFailure("builtInProxyConfigBuilder must be set before calling startBuiltInProxy()")
        }

        let config = try configBuilder()

        do {
            try localProxyServer.start(config: config)
        } catch {
            if let serverError = error as? LocalProxyServer.ServerError,
               case .bindFailed(let message) = serverError,
               message.lowercased().contains("address already in use") {
                throw IssueError(issue: AppIssue(
                    code: .portInUse,
                    title: String(localized: "Proxy Port Already In Use"),
                    message: String(localized: "Port") + " \(config.port) " + String(localized: "is already in use. Choose another port (for example 4001)."),
                    actions: [.setProxyURLTo4001, .runPreflight]
                ))
            }
            throw error
        }
    }

    private func stopBuiltInProxyIfRunning() throws {
        if localProxyServer.state.isRunning {
            try localProxyServer.stop()
        }
    }

    private func validateBuiltInProxyCameUp() async throws {
        guard let validator = proxyURLValidator else {
            preconditionFailure("proxyURLValidator must be set before calling validateBuiltInProxyCameUp()")
        }
        let baseURL = try validator(true).url

        for _ in 0..<10 {
            if localProxyServer.state.isRunning { return }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }

        do {
            _ = try await proxyService.probe(baseURL: baseURL)
            localProxyServer.state.isRunning = true
        } catch {
            let status = localProxyServer.state.lastStatus
            if status.lowercased().contains("address already in use") {
                throw IssueError(issue: AppIssue(
                    code: .portInUse,
                    title: String(localized: "Proxy Port Already In Use"),
                    message: String(localized: "Port appears to be in use. Switch to 4001 or stop the process using the current port."),
                    actions: [.setProxyURLTo4001, .runPreflight]
                ))
            }

            if status.isEmpty {
                throw IssueError(issue: AppIssue(
                    code: .generic,
                    title: String(localized: "Built-In Proxy Did Not Start"),
                    message: String(localized: "Built-in proxy did not start (no listener on") + " " + baseURL.absoluteString + ").",
                    actions: [.runPreflight, .exportDiagnostics]
                ))
            }

            throw IssueError(issue: AppIssue(
                code: .generic,
                title: String(localized: "Built-In Proxy Did Not Start"),
                message: String(localized: "Built-in proxy did not start. Status:") + " " + status,
                actions: [.runPreflight, .exportDiagnostics]
            ))
        }
    }

    private func validateProxyCameUp() async throws {
        guard let validator = proxyURLValidator else {
            preconditionFailure("proxyURLValidator must be set before calling validateProxyCameUp()")
        }
        let baseURL = try validator(false).url

        try? await Task.sleep(nanoseconds: 450_000_000)

        do {
            _ = try await proxyService.probe(baseURL: baseURL)
        } catch {
            let tail = proxyService.readLogTail()
            if tail.isEmpty {
                throw IssueError(issue: AppIssue(
                    code: .generic,
                    title: String(localized: "Proxy Did Not Start"),
                    message: String(localized: "Proxy did not respond on") + " " + baseURL.absoluteString + ".",
                    actions: [.runPreflight, .exportDiagnostics]
                ))
            }

            throw IssueError(issue: AppIssue(
                code: .generic,
                title: String(localized: "Proxy Did Not Start"),
                message: String(localized: "Proxy did not start. Check logs in the Log section for details."),
                actions: [.runPreflight, .exportDiagnostics]
            ))
        }
    }

    // MARK: - Issue Helpers

    typealias IssueError = AppIssueError

    private func issueFor(
        _ error: Error,
        fallbackCode: AppIssue.Code,
        fallbackTitle: String,
        fallbackActions: [AppIssue.Action]
    ) -> AppIssue {
        if let issueError = error as? IssueError {
            return issueError.issue
        }

        if let serviceError = error as? ProxyServiceError {
            switch serviceError {
            case .httpStatus(let status, let body):
                if status == 401 || status == 403 {
                    return AppIssue(
                        code: .upstreamUnauthorized,
                        title: String(localized: "Upstream Authorization Failed"),
                        message: String(localized: "Upstream provider returned HTTP") + " \(status). " + String(localized: "Verify your API key and provider URL."),
                        actions: [.openUpstreamKeyEditor, .resetUpstreamURL]
                    )
                }
                if status == 413 {
                    return AppIssue(
                        code: .requestTooLarge,
                        title: String(localized: "Request Too Large"),
                        message: String(localized: "Upstream provider rejected request size (HTTP 413)."),
                        actions: [.exportDiagnostics]
                    )
                }
                return AppIssue(
                    code: fallbackCode,
                    title: fallbackTitle,
                    message: body.isEmpty ? "HTTP \(status)" : "HTTP \(status): \(body)",
                    actions: fallbackActions
                )
            default:
                break
            }
        }

        if let urlError = error as? URLError, urlError.code == .timedOut {
            return AppIssue(
                code: .upstreamTimeout,
                title: String(localized: "Request Timed Out"),
                message: String(localized: "The request timed out. Check network connectivity and upstream provider availability."),
                actions: [.retryStart, .exportDiagnostics]
            )
        }

        if let serverError = error as? LocalProxyServer.ServerError,
           case .bindFailed(let message) = serverError,
           message.lowercased().contains("address already in use") {
            return AppIssue(
                code: .portInUse,
                title: String(localized: "Proxy Port Already In Use"),
                message: String(localized: "Another process is using this port. Switch to 4001 or free the current port."),
                actions: [.setProxyURLTo4001, .runPreflight]
            )
        }

        let text = error.localizedDescription.lowercased()
        if text.contains("timed out") {
            return AppIssue(
                code: .upstreamTimeout,
                title: String(localized: "Request Timed Out"),
                message: String(localized: "The request timed out. Retry after checking your network and provider status."),
                actions: [.retryStart, .exportDiagnostics]
            )
        }

        if text.contains("unauthorized") {
            return AppIssue(
                code: .upstreamUnauthorized,
                title: String(localized: "Unauthorized"),
                message: String(localized: "Authorization failed. Verify credentials and provider settings."),
                actions: [.openUpstreamKeyEditor, .resetUpstreamURL]
            )
        }

        if text.contains("too large") {
            return AppIssue(
                code: .requestTooLarge,
                title: String(localized: "Request Too Large"),
                message: String(localized: "Request exceeded the configured size limits."),
                actions: [.exportDiagnostics]
            )
        }

        return AppIssue(
            code: fallbackCode,
            title: fallbackTitle,
            message: error.localizedDescription,
            actions: fallbackActions
        )
    }
}
