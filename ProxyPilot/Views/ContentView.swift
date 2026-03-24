import AppKit
import ProxyPilotCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var vm: AppViewModel
    @EnvironmentObject private var updateService: SoftwareUpdateService
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var routingVerificationCopied: Bool = false
    @State private var showInstallConfirmation: Bool = false
    @State private var recoveryCommandsCopied: Bool = false
    @State private var diyCommandsCopied: Bool = false
    @State private var shimmerActive: Bool = false
    @AppStorage("proxypilot.preflightExpanded") private var preflightExpanded: Bool = true
    @State private var showNuclearResetConfirm: Bool = false
    @State private var sessionCSVExportStatus: String = ""
    @State private var expandedSessionRequestIDs: Set<UUID> = []
    @State private var copiedSessionRequestID: UUID?

    private enum SettingsTab: Hashable {
        case general
        case keys
        case advanced
    }
    @State private var selectedTab: SettingsTab = .general

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            TabView(selection: $selectedTab) {
                generalTab
                    .tabItem { Label("General", systemImage: "gearshape") }
                    .tag(SettingsTab.general)

                keysTab
                    .tabItem { Label("Keys", systemImage: "key") }
                    .tag(SettingsTab.keys)

                advancedTab
                    .tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
                    .tag(SettingsTab.advanced)
            }

            Divider()
            HStack(spacing: 6) {
                Text("ProxyPilot v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Text("Beta")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.15), in: Capsule())
                    .foregroundStyle(.orange)
            }
            .padding(.bottom, 6)
        }
        .onAppear {
            vm.refreshStatus()
            vm.startLogUpdates()
            vm.maybeShowKeychainAccessPrimerOnLaunch()
            vm.maybeShowAnalyticsPrompt()
        }
        .onDisappear {
            vm.stopLogUpdates()
        }
        .sheet(isPresented: Binding(
            get: { vm.showOnboardingWizard },
            set: { vm.showOnboardingWizard = $0 }
        )) {
            OnboardingWizardView()
                .environmentObject(vm)
        }
        .sheet(isPresented: Binding(
            get: { vm.showKeychainAccessPrimer },
            set: { vm.showKeychainAccessPrimer = $0 }
        )) {
            KeychainAccessPrimerView()
                .environmentObject(vm)
        }
        .sheet(isPresented: Binding(
            get: { vm.showAnalyticsPrompt },
            set: { vm.showAnalyticsPrompt = $0 }
        )) {
            AnalyticsOptInView(
                onEnable: { vm.dismissAnalyticsPrompt(optIn: true) },
                onDisable: { vm.dismissAnalyticsPrompt(optIn: false) }
            )
            .interactiveDismissDisabled(true)
        }
        .frame(minWidth: 700, minHeight: 620)
    }

    // MARK: - General Tab

    private var generalTab: some View {
        Form {
            Section("Proxy") {
                TextField("Proxy URL", text: Binding(
                    get: { vm.proxyURLString },
                    set: { vm.proxyURLString = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .help("Use http://127.0.0.1:4000 for built-in mode.")

                HStack(spacing: 12) {
                    Button("Start") { Task { await vm.startProxy() } }
                        .disabled(vm.isRunning)
                        .accessibilityLabel("Start local proxy server")
                        .accessibilityHint("Starts ProxyPilot local proxy for Xcode.")

                    Button("Stop") { Task { await vm.stopProxy() } }
                        .disabled(!vm.isRunning)
                        .accessibilityLabel("Stop local proxy server")
                        .accessibilityHint("Stops the local proxy server.")

                    Button("Restart") { Task { await vm.restartProxy() } }
                        .disabled(!vm.isRunning)
                        .accessibilityLabel("Restart local proxy server")
                        .accessibilityHint("Restarts the local proxy server.")

                    Spacer()

                    Button("Refresh") { vm.refreshStatus() }
                        .accessibilityLabel("Refresh proxy status")
                }

                LabeledContent("Status") {
                    Text(vm.statusText)
                        .foregroundStyle(vm.isRunning ? .green : .secondary)
                }
                .accessibilityLabel("Proxy status \(vm.statusText)")

                switch vm.recoveryState {
                case .recovering(let attempt, let delaySeconds):
                    Text(verbatim: String(localized: "Auto-recovery attempt") + " \(attempt) " + String(localized: "queued in") + " \(delaySeconds)s.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .degraded(let reason):
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.orange)
                default:
                    EmptyView()
                }

                if vm.useBuiltInProxy {
                    Text("Built-in proxy serves `GET /v1/models`, forwards `POST /v1/chat/completions`, and translates `POST /v1/messages`.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(verbatim: String(localized: "Anthropic translator mode:") + " " + vm.anthropicTranslatorModeText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("LiteLLM mode requires scripts in `~/tools/litellm/`.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Button { selectedTab = .advanced } label: {
                Text("Local auth, startup behavior, and more in **Advanced**.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            Section {
                if preflightExpanded {
                    if let lastRun = vm.preflightLastRun {
                        Text(verbatim: String(localized: "Last checked:") + " " + lastRun.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    ForEach(vm.preflightResults) { result in
                        preflightRow(result)
                    }
                }
            } header: {
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        preflightExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text("Preflight")
                        Image(systemName: preflightExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .onAppear {
                vm.runPreflightChecks()
            }

            Section("Session Report Card") {
                if vm.sessionReportCard.totalRequests == 0 {
                    Text("Start the proxy and send requests to see session metrics.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            LabeledContent("Requests") {
                                Text("\(vm.sessionReportCard.totalRequests)")
                                    .font(.system(.body, design: .monospaced))
                            }
                            Spacer()
                            LabeledContent("Total Tokens") {
                                Text(vm.sessionReportCard.totalTokensFormatted)
                                    .font(.system(.body, design: .monospaced))
                            }
                        }

                        if vm.sessionReportCard.totalTokens > 0 {
                            HStack {
                                LabeledContent("Prompt") {
                                    Text("\(vm.sessionReportCard.totalPromptTokens)")
                                        .font(.system(.caption, design: .monospaced))
                                }
                                Spacer()
                                LabeledContent("Completion") {
                                    Text("\(vm.sessionReportCard.totalCompletionTokens)")
                                        .font(.system(.caption, design: .monospaced))
                                }
                            }
                            .foregroundStyle(.secondary)
                        }

                        if let latency = vm.sessionLatencySummary {
                            HStack {
                                LabeledContent("Avg") {
                                    Text(formatLatency(latency.average))
                                        .font(.system(.caption, design: .monospaced))
                                }
                                Spacer()
                                LabeledContent("P50") {
                                    Text(formatLatency(latency.p50))
                                        .font(.system(.caption, design: .monospaced))
                                }
                                Spacer()
                                LabeledContent("P95") {
                                    Text(formatLatency(latency.p95))
                                        .font(.system(.caption, design: .monospaced))
                                }
                            }
                            .foregroundStyle(.secondary)

                            LabeledContent("Max Latency") {
                                Text(formatLatency(latency.max))
                                    .font(.system(.caption, design: .monospaced))
                            }
                            .foregroundStyle(.secondary)
                        }

                        LabeledContent("Estimated Cost") {
                            Text(vm.formatUSD(vm.sessionEstimatedCostUSD))
                                .font(.system(.caption, design: .monospaced))
                        }
                        .foregroundStyle(.secondary)

                        if !vm.sessionCostCoverageText.isEmpty {
                            Text(vm.sessionCostCoverageText)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        if !vm.sessionModelLatencyBreakdown.isEmpty {
                            Divider()
                            Text("Per-Model Latency")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ForEach(vm.sessionModelLatencyBreakdown) { entry in
                                HStack {
                                    Text(entry.model)
                                        .font(.system(.caption, design: .monospaced))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer()
                                    Text("p95 \(formatLatency(entry.p95))")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Text("avg \(formatLatency(entry.average))")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Text("\(entry.requestCount) req")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        if !vm.sessionReportCard.modelDistribution.isEmpty {
                            Divider()
                            Text("Model Distribution")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ForEach(vm.sessionReportCard.modelDistribution, id: \.model) { entry in
                                HStack {
                                    Text(entry.model)
                                        .font(.system(.caption, design: .monospaced))
                                    Spacer()
                                    Text("\(entry.count) req")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        Divider()
                        HStack {
                            Text("Recent Requests")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Export CSV") {
                                exportSessionRequestsCSV()
                            }
                            .font(.caption)
                            Button("Reset") {
                                vm.resetSessionStats()
                                sessionCSVExportStatus = ""
                                expandedSessionRequestIDs.removeAll()
                                copiedSessionRequestID = nil
                            }
                            .font(.caption)
                        }

                        if !sessionCSVExportStatus.isEmpty {
                            Text(sessionCSVExportStatus)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }

                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 8) {
                                ForEach(Array(vm.sessionReportCard.requests.suffix(40).reversed())) { request in
                                    DisclosureGroup(
                                        isExpanded: sessionRequestDisclosureBinding(for: request.id)
                                    ) {
                                        VStack(alignment: .leading, spacing: 4) {
                                            requestDetailRow(label: "Path", value: request.path)
                                            requestDetailRow(label: "Streaming", value: request.wasStreaming ? "Yes" : "No")
                                            requestDetailRow(label: "Prompt", value: "\(request.promptTokens)")
                                            requestDetailRow(label: "Completion", value: "\(request.completionTokens)")
                                            requestDetailRow(label: "Total", value: "\(request.totalTokens)")
                                            requestDetailRow(label: "Latency", value: formatLatency(request.durationSeconds))
                                            requestDetailRow(label: "Estimated Cost", value: vm.formatUSD(vm.estimatedCostUSD(for: request)))

                                            HStack {
                                                Spacer()
                                                Button(copiedSessionRequestID == request.id ? "Copied JSON" : "Copy JSON") {
                                                    copySessionRequestJSON(request)
                                                }
                                                .font(.caption2)
                                            }
                                        }
                                        .padding(.top, 4)
                                    } label: {
                                        VStack(alignment: .leading, spacing: 4) {
                                            HStack {
                                                Text(request.timestamp, format: .dateTime.hour().minute().second())
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                                Spacer()
                                                Text(formatLatency(request.durationSeconds))
                                                    .font(.system(.caption2, design: .monospaced))
                                                    .foregroundStyle(.secondary)
                                            }
                                            HStack {
                                                Text(request.model.isEmpty ? "(unknown model)" : request.model)
                                                    .font(.system(.caption, design: .monospaced))
                                                    .lineLimit(1)
                                                    .truncationMode(.middle)
                                                Spacer()
                                                Text("\(request.totalTokens) tok")
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                                Text(vm.formatUSD(vm.estimatedCostUSD(for: request)))
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                    .padding(8)
                                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                                }
                            }
                        }
                        .frame(maxHeight: 260)
                    }
                }
            }

            Section("Models (Upstream Provider)") {
                Picker("Upstream Preset", selection: Binding(
                    get: { vm.upstreamProvider },
                    set: { vm.upstreamProvider = $0 }
                )) {
                    ForEach(UpstreamProvider.allCases.filter { !$0.isLocal }) { provider in
                        Text(provider.isPreview ? "\(provider.title) (Preview)" : provider.title).tag(provider)
                    }
                    Divider()
                    ForEach(UpstreamProvider.allCases.filter { $0.isLocal }) { provider in
                        Text(provider.title).tag(provider)
                    }
                }
                .pickerStyle(.menu)

                if vm.upstreamProvider.isPreview {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.caption)
                        Text("\(vm.upstreamProvider.title) support is in **Preview** and may be unstable. [Report issues on GitHub.](https://github.com/masterofthechaos/ProxyPilot)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Button { selectedTab = .keys } label: {
                    Text("Manage API keys in the **Keys** tab.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                TextField("Upstream API base URL", text: Binding(
                    get: { vm.upstreamAPIBaseURLString },
                    set: { vm.upstreamAPIBaseURLString = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .help("Endpoint-style URLs are normalized automatically.")

                HStack {
                    Spacer()
                    Button(String(localized: "Reset to") + " " + vm.upstreamProvider.title) {
                        vm.resetUpstreamAPIBaseURL()
                    }
                    .font(.caption)
                    .disabled(
                        vm.upstreamAPIBaseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
                            == vm.selectedUpstreamProviderDefaultAPIBaseURL
                    )
                }

                if vm.upstreamProvider == .google {
                    Text("Google direct uses a beta OpenAI-compatible endpoint and may be less stable than OpenRouter.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if vm.upstreamProvider.isMiniMax {
                    HStack(spacing: 8) {
                        Picker("Routing Mode", selection: $vm.miniMaxRoutingMode) {
                            Text("Standard").tag(MiniMaxRoutingMode.standard)
                            Text("Anthropic Passthrough").tag(MiniMaxRoutingMode.anthropicPassthrough)
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                    }
                    Text(vm.miniMaxRoutingMode == .anthropicPassthrough
                         ? "Forwards /v1/messages directly to MiniMax's Anthropic-compatible endpoint. Skips translation but validates responses for Xcode compatibility."
                         : "Translates Anthropic requests to OpenAI format before forwarding to MiniMax.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    Button("Fetch Live Models") { Task { await vm.fetchUpstreamModels() } }
                        .accessibilityLabel("Fetch models from upstream provider")
                    Button("Sync To Proxy + Restart") { Task { await vm.syncProxyModelsFromSelection() } }
                        .disabled(!vm.canSyncProxyModels)
                    Button("Save as Defaults") { vm.saveSelectedModelsAsDefaults() }
                        .disabled(vm.selectedUpstreamModels.isEmpty)
                    Spacer()
                    if vm.upstreamModels.isEmpty {
                        if vm.hasSavedDefaultModels {
                            Text(verbatim: "\(vm.savedDefaultModels.count) saved defaults")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("No models configured — fetch to get started")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    } else {
                        Text(verbatim: "\(vm.selectedUpstreamModels.count)/\(vm.filteredUpstreamModels.count) " + String(localized: "selected"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if !vm.upstreamModels.isEmpty {
                    Toggle("Show model metadata", isOn: Binding(
                        get: { vm.showModelMetadata },
                        set: { vm.showModelMetadata = $0 }
                    ))
                    .toggleStyle(.switch)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    if vm.upstreamProvider == .openRouter {
                        Toggle("Show :exacto models only", isOn: Binding(
                            get: { vm.exactoFilterEnabled },
                            set: { vm.exactoFilterEnabled = $0 }
                        ))
                        .toggleStyle(.switch)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        Toggle("Show ProxyPilot Verified only", isOn: Binding(
                            get: { vm.verifiedFilterEnabled },
                            set: { vm.verifiedFilterEnabled = $0 }
                        ))
                        .toggleStyle(.switch)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                if !vm.upstreamModels.isEmpty {
                    HStack(spacing: 12) {
                        Button("Select All") { vm.selectAllUpstreamModels() }
                            .font(.caption)
                            .disabled(vm.selectedUpstreamModels.count == vm.filteredUpstreamModels.count)
                        Button("Clear Selection") { vm.clearUpstreamModelSelection() }
                            .font(.caption)
                            .disabled(vm.selectedUpstreamModels.isEmpty)
                        Spacer()
                    }
                }

                if vm.upstreamModels.isEmpty {
                    if vm.hasSavedDefaultModels {
                        Text("Live fetch is optional. Sync uses your saved defaults plus Xcode Agent model.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Fetch models from your provider, select the ones you want, then save as defaults.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    List(vm.filteredUpstreamModels) { model in
                        Toggle(isOn: Binding(
                            get: { vm.selectedUpstreamModels.contains(model.id) },
                            set: { isOn in
                                if isOn {
                                    vm.selectedUpstreamModels.insert(model.id)
                                } else {
                                    vm.selectedUpstreamModels.remove(model.id)
                                }
                                vm.reconcileXcodeAgentModelSelection()
                            }
                        )) {
                            HStack(spacing: 6) {
                                Text(model.id)
                                    .font(.system(.body, design: .monospaced))

                                if vm.showModelMetadata {
                                    modelMetadataView(
                                        model,
                                        estimatedCostPerRequest: vm.estimatedRequestCostUSD(for: model)
                                    )
                                }
                            }
                        }
                    }
                    .frame(minHeight: 120)
                }
            }

            Section("Xcode") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("In Xcode -> Settings -> Intelligence -> Add a Model Provider:")
                        .font(.subheadline)
                    Text(verbatim: "URL: " + vm.proxyURLString)
                    Text(verbatim: "API Key Header: Authorization")
                    Text(verbatim: "API Key: Bearer <Local Proxy Password>")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Xcode Agent Mode (Xcode 26.3+)") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Route Claude Agent in Xcode through ProxyPilot. Translates Anthropic /v1/messages to OpenAI format for upstream providers.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    // Xcode Installations
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Detected Xcode Installations")
                                .font(.subheadline)
                            Spacer()
                            Button("Rescan") {
                                Task { await vm.detectXcodeInstallations() }
                            }
                            .font(.caption)
                        }

                        if vm.xcodeInstallations.isEmpty {
                            Text("No Xcode installations found.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        } else {
                            ForEach(vm.xcodeInstallations) { xcode in
                                HStack(spacing: 8) {
                                    Image(systemName: xcode.supportsAgenticCoding
                                        ? "checkmark.circle.fill" : "xmark.circle")
                                        .foregroundStyle(xcode.supportsAgenticCoding ? .green : .red)

                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 4) {
                                            Text("Xcode \(xcode.version)")
                                                .font(.subheadline)
                                            if xcode.isBeta {
                                                Text("Beta")
                                                    .font(.caption2)
                                                    .padding(.horizontal, 5)
                                                    .padding(.vertical, 1)
                                                    .background(Capsule().fill(Color.orange.opacity(0.2)))
                                                    .foregroundStyle(.orange)
                                            }
                                        }
                                        Text("Build \(xcode.buildNumber)")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(xcode.supportsAgenticCoding ? "Agent Ready" : "No Agent Support")
                                        .font(.caption)
                                        .foregroundStyle(xcode.supportsAgenticCoding ? .green : .secondary)
                                }
                            }
                        }
                    }

                    Divider()

                    Picker("Xcode Agent Upstream Model", selection: Binding(
                        get: { vm.selectedXcodeAgentModel },
                        set: { vm.selectedXcodeAgentModel = $0 }
                    )) {
                        ForEach(vm.xcodeAgentModelCandidates, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                    .pickerStyle(.menu)

                    Text(verbatim: String(localized: "Effective routed model:") + " " + vm.effectiveXcodeAgentModel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    // --- DIY Setup ---
                    DisclosureGroup(String(localized: "DIY Setup")) {
                        Text(vm.diyInstallCommands)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 6))

                        HStack {
                            Button(diyCommandsCopied ? String(localized: "Copied!") : String(localized: "Copy Commands")) {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(vm.diyInstallCommands, forType: .string)
                                diyCommandsCopied = true
                            }
                            .font(.caption)
                            Spacer()
                        }

                        Text("These are the exact commands ProxyPilot runs on your behalf.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    // --- Helper text ---
                    (Text("ProxyPilot works by modifying two system settings non-destructively to re-route LLM traffic. You ")
                     + Text("must").bold()
                     + Text(" revert these changes to restore native behavior. You can revert by copying the reversion script above or by clicking ")
                     + Text("Remove").foregroundStyle(.red).bold()
                     + Text(" below. ProxyPilot will remind you to do this each time you quit the app."))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    // --- Install / Remove buttons ---
                    HStack(spacing: 12) {
                        Button("Install") {
                            showInstallConfirmation = true
                        }
                        .disabled(!vm.hasCompatibleXcode)

                        Button("Remove") {
                            vm.removeXcodeAgentConfig()
                        }
                        .foregroundStyle(.red)

                        Spacer()
                    }

                    // --- Post-install persistent banner ---
                    if vm.agentConfigInstalled {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Xcode Agent is routed through ProxyPilot. Remember to click Remove or run the reversion script before uninstalling.")
                                    .font(.caption)
                                Button(recoveryCommandsCopied ? String(localized: "Copied!") : String(localized: "Copy Recovery Commands")) {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(vm.recoveryCommands, forType: .string)
                                    recoveryCommandsCopied = true
                                }
                                .font(.caption)
                            }
                        }
                        .padding(8)
                        .background(Color.orange.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }

                    if !vm.agentConfigStatus.isEmpty {
                        Text(vm.agentConfigStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Verify GLM Routing (Terminal)")
                                .font(.subheadline)
                            Spacer()
                            Button("Copy Commands") {
                                copyRoutingVerificationCommands()
                            }
                        }

                        Text("Run the first command in one terminal tab, then run the two `rg` commands after one Xcode Agent request.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text(routingVerificationCommands)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 6))

                        if routingVerificationCopied {
                            Text("Copied verification commands.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .alert(
                    String(localized: "ProxyPilot Needs to Make a Reversible System Change"),
                    isPresented: $showInstallConfirmation
                ) {
                    Button(String(localized: "Cancel"), role: .cancel) { }
                    Button(String(localized: "Proceed")) {
                        vm.installXcodeAgentConfig()
                    }
                } message: {
                    Text("ProxyPilot is about to modify system files on your behalf. Please note that while these changes are reversible, quitting or uninstalling ProxyPilot will not revert them automatically.")
                }
            }

            Section("Checklist") {
                if vm.upstreamProvider.requiresAPIKey {
                    checklistRow(String(localized: "Upstream API key saved") + " (\(vm.upstreamProvider.title))", isOn: vm.hasUpstreamKey)
                }
                checklistRow(vm.masterKeyChecklistTitle, isOn: vm.hasRequiredMasterKey)
                checklistRow(String(localized: "Proxy URL looks valid"), isOn: vm.checklistIsProxyURLValid)
                HStack {
                    checklistRow(String(localized: "Proxy is running"), isOn: vm.isRunning)
                    if !vm.isRunning {
                        Button("Start Proxy") { Task { await vm.startProxy() } }
                            .font(.caption)
                    }
                }

                Toggle(isOn: Binding(
                    get: { vm.xcodeProviderConfirmed },
                    set: { vm.xcodeProviderConfirmed = $0 }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("I added the provider in Xcode")
                        Text("Xcode -> Settings -> Intelligence -> Add a Model Provider")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)

                HStack(spacing: 12) {
                    Button("Fetch Proxy Models") { Task { await vm.testModels() } }
                    Button("Test Upstream Response") { Task { await vm.testUpstreamResponse() } }
                    Spacer()
                }

                if !vm.upstreamTestOutput.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(verbatim: String(localized: "Upstream test output") + " (" + String(localized: "model:") + " " + vm.upstreamTestModelUsed + ")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(vm.upstreamTestOutput)
                            .font(.system(.body, design: .monospaced))
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
            }

            Section("Diagnostics") {
                HStack(spacing: 8) {
                    Button("Export Diagnostics") { vm.exportDiagnostics() }
                        .accessibilityLabel("Export diagnostics bundle")
                    Button("Copy Support Summary") { vm.copySupportSummaryToPasteboard() }
                        .accessibilityLabel("Copy support summary")
                    Button("Send Feedback") { vm.openFeedbackDraft() }
                        .accessibilityLabel("Send app feedback")
                    Spacer()
                }
                if !vm.diagnosticsArchivePath.isEmpty {
                    Text(verbatim: String(localized: "Archive:") + " " + vm.diagnosticsArchivePath)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text("Send Feedback opens a prefilled email draft and copies the current support summary to your clipboard.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section("Updates") {
                HStack(spacing: 8) {
                    Button("Check for Updates") { updateService.checkForUpdates() }
                        .disabled(!updateService.canCheckForUpdates)
                        .accessibilityLabel("Check for software updates")
                    Button(vm.isUpdatingCLITool ? "Updating..." : "Update CLI Tool") {
                        Task { await vm.updateCLITool() }
                    }
                    .disabled(vm.isUpdatingCLITool)
                    .accessibilityLabel("Update ProxyPilot CLI tool")
                    if vm.isUpdatingCLITool {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Spacer()
                }
                if !vm.cliUpdateStatusText.isEmpty {
                    Text(vm.cliUpdateStatusText)
                        .font(.caption2)
                        .foregroundStyle(vm.cliUpdateStatusIsError ? .orange : .secondary)
                        .textSelection(.enabled)
                }
            }

            Section("Links") {
                HStack(spacing: 8) {
                    Button("README") { vm.openReadme() }
                    Button("Website") { vm.openWebsite() }
                    Button("GitHub") {
                        if let url = URL(string: "https://github.com/masterofthechaos/ProxyPilot") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    Spacer()
                }

                if !vm.supportSummary.isEmpty {
                    TextEditor(text: Binding(get: { vm.supportSummary }, set: { _ in }))
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 100)
                }
            }

            Section("Log") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(verbatim: String(localized: "Source:") + " " + vm.currentLogSourcePath)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Clear") { vm.clearLog() }
                            .font(.caption)
                        Button("Refresh") { vm.refreshStatus() }
                            .font(.caption)
                    }

                    TextEditor(text: Binding(get: { vm.logText.isEmpty ? String(localized: "(no log lines yet)") : vm.logText }, set: { _ in }))
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 160)
                }
            }

            if let issue = vm.activeIssue {
                Section(String(localized: "Issue") + " " + issue.code.rawValue) {
                    Text(issue.title)
                        .font(.headline)
                    Text(issue.message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)

                    if !issue.actions.isEmpty {
                        HStack(spacing: 12) {
                            ForEach(issue.actions) { action in
                                Button(action.title) {
                                    vm.performIssueAction(action)
                                }
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Keys Tab

    @State private var showAddCustomProviderSheet = false

    private var keysTab: some View {
        Form {
            Section {
                Text("API keys are stored in macOS Keychain under the \"proxypilot\" service.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(UpstreamProvider.allCases.filter { $0.requiresAPIKey }, id: \.self) { provider in
                    providerKeyRow(provider)
                }
            } header: {
                Text("Supported Providers")
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Always check official provider documentation for accurate API base URLs. Some providers may be incompatible with ProxyPilot.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Link("Want to request official support for a new provider? Submit a GitHub Issue.",
                         destination: URL(string: "https://github.com/masterofthechaos/ProxyPilot-public/issues")!)
                        .font(.caption)
                }

                if vm.customProviders.isEmpty {
                    Text("No custom providers added.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                } else {
                    ForEach(vm.customProviders) { provider in
                        customProviderKeyRow(provider)
                    }
                }
            } header: {
                HStack {
                    Text("Custom Providers (Preview)")
                    Spacer()
                    Button {
                        showAddCustomProviderSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.plain)
                }
            }

            Section("Local Proxy Password") {
                keyRow(
                    title: vm.masterKeyKeychainTitle,
                    isPresent: vm.hasMasterKey,
                    isEditing: vm.showingMasterKeyField,
                    draft: Binding(get: { vm.masterKeyDraft }, set: { vm.masterKeyDraft = $0 }),
                    onEditToggle: { vm.showingMasterKeyField.toggle() },
                    onSave: { vm.saveMasterKey() },
                    onDelete: { vm.deleteMasterKey() }
                )
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showAddCustomProviderSheet) {
            AddCustomProviderView { name, url, key in
                vm.addCustomProvider(name: name, apiBaseURL: url, apiKey: key)
            }
        }
    }

    @ViewBuilder
    private func customProviderKeyRow(_ provider: CustomProvider) -> some View {
        let hasKey = vm.customProviderHasKey(provider)

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.name)
                        .font(.subheadline.bold())
                    Text(provider.apiBaseURL)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if hasKey {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Key stored")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("No key")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            HStack(spacing: 12) {
                Button("Delete") {
                    vm.deleteCustomProvider(provider)
                }
                .foregroundStyle(.red)
                Spacer()
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func providerKeyRow(_ provider: UpstreamProvider) -> some View {
        let hasKey = vm.hasKey(for: provider)
        let isEditing = vm.providerKeyEditing[provider] ?? false
        let testState = vm.providerKeyTestStates[provider] ?? .idle

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(provider.title)
                    .font(.subheadline.bold())
                Spacer()
                if hasKey {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Key for \(provider.title) is stored safely in Keychain")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("No key")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            if isEditing {
                SecureField("Paste API key", text: Binding(
                    get: { vm.providerKeyDrafts[provider] ?? "" },
                    set: { vm.providerKeyDrafts[provider] = $0 }
                ))
                .textFieldStyle(.roundedBorder)

                HStack {
                    Button("Cancel") {
                        vm.providerKeyDrafts[provider] = nil
                        vm.providerKeyEditing[provider] = nil
                    }
                    Button("Save") { vm.saveKey(for: provider) }
                        .disabled((vm.providerKeyDrafts[provider] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Spacer()
                }
            } else {
                HStack(spacing: 12) {
                    Button(hasKey ? "Change" : "Set") {
                        vm.providerKeyEditing[provider] = true
                    }
                    if hasKey {
                        Button("Delete") { vm.deleteKey(for: provider) }
                            .foregroundStyle(.red)
                        Button(testState == .testing ? "Testing..." : "Test") {
                            Task { await vm.testKey(for: provider) }
                        }
                        .disabled(testState == .testing)
                    }
                    if let url = provider.apiKeyPageURL {
                        Button("Get Key") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    Spacer()
                }
                if hasKey {
                    providerKeyTestStatusView(testState)
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func providerKeyTestStatusView(_ state: AppViewModel.KeyTestState) -> some View {
        switch state {
        case .idle:
            EmptyView()
        case .testing:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Testing key...")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        case .success(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.green)
        case .failure(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    // MARK: - Advanced Tab

    private var advancedTab: some View {
        Form {
            Section("Advanced") {
                DisclosureGroup("LiteLLM Mode (Advanced)") {
                    Toggle("Use LiteLLM scripts instead of built-in proxy", isOn: Binding(
                        get: { !vm.useBuiltInProxy },
                        set: { vm.useBuiltInProxy = !$0 }
                    ))
                    .toggleStyle(.switch)
                    .accessibilityLabel("Use LiteLLM mode")
                    .accessibilityHint("Disables built-in proxy and uses external LiteLLM scripts.")

                    Text("Requires `start_zai_proxy.sh`, `stop_zai_proxy.sh`, and `restart_zai_proxy.sh` in `~/tools/litellm/`.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Toggle("Require auth for local proxy (advanced)", isOn: Binding(
                    get: { vm.requireLocalAuth },
                    set: { vm.requireLocalAuth = $0 }
                ))
                .toggleStyle(.switch)
                .help("Xcode Locally Hosted mode may fail when auth is required.")
                .accessibilityLabel("Require local proxy authentication")

                Toggle("Use legacy Anthropic translator fallback", isOn: Binding(
                    get: { vm.anthropicTranslatorFallbackEnabled },
                    set: { vm.anthropicTranslatorFallbackEnabled = $0 }
                ))
                .toggleStyle(.switch)
                .help("Default is Hardened mode. Enable only for A/B debugging.")

                Toggle("Auto-restart proxy on unexpected stop", isOn: Binding(
                    get: { vm.autoRestartEnabled },
                    set: { vm.autoRestartEnabled = $0 }
                ))
                .toggleStyle(.switch)

                Toggle("Share anonymous diagnostics telemetry", isOn: Binding(
                    get: { vm.telemetryOptIn },
                    set: { vm.telemetryOptIn = $0 }
                ))
                .toggleStyle(.switch)
                .help("Default off. Local event logs are always recorded for support diagnostics.")
            }

            Section("Startup") {
                Toggle("Launch at Login", isOn: Binding(
                    get: { vm.launchAtLogin },
                    set: { _ in vm.toggleLaunchAtLogin() }
                ))
                .toggleStyle(.switch)
                .help("Automatically start ProxyPilot when you log in.")
            }

            Section("Danger Zone") {
                Text("This will remove Xcode Agent config, delete all stored keys, reset proxy URLs and settings, and return ProxyPilot to first-run state.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Reset ProxyPilot (Nuclear)") {
                    showNuclearResetConfirm = true
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
        }
        .formStyle(.grouped)
        .alert("Reset ProxyPilot to Fresh Install?", isPresented: $showNuclearResetConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Reset Everything", role: .destructive) {
                Task { await vm.resetToFreshInstall() }
            }
        } message: {
            Text("This will remove Xcode Agent config, delete all Keychain keys, disable Launch at Login, clear logs, and reset all preferences.")
        }
    }

    // MARK: - Helpers

    private func preflightRow(_ result: PreflightCheckResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: symbolForPreflightStatus(result.status))
                    .foregroundStyle(colorForPreflightStatus(result.status))
                Text(result.title)
                    .font(.subheadline)
                Spacer()
                if result.fixAction != .none {
                    Button("Fix") {
                        handlePreflightFixAction(result.fixAction)
                    }
                    .font(.caption)
                }
            }
            Text(result.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func symbolForPreflightStatus(_ status: PreflightCheckStatus) -> String {
        switch status {
        case .pass:
            return "checkmark.circle.fill"
        case .info:
            return "info.circle.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        case .fail:
            return "xmark.octagon.fill"
        }
    }

    private func colorForPreflightStatus(_ status: PreflightCheckStatus) -> Color {
        switch status {
        case .pass:
            return .green
        case .info:
            return .secondary
        case .warning:
            return .orange
        case .fail:
            return .red
        }
    }

    private func checklistRow(_ title: String, isOn: Bool) -> some View {
        HStack {
            Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isOn ? .green : .secondary)
            Text(title)
            Spacer()
        }
        .font(.subheadline)
    }

    private func handlePreflightFixAction(_ action: PreflightFixAction) {
        switch action {
        case .openUpstreamKeyEditor:
            selectedTab = .keys
            if vm.upstreamProvider.requiresAPIKey {
                vm.providerKeyEditing[vm.upstreamProvider] = true
                vm.providerKeyDrafts[vm.upstreamProvider] = nil
            }
        case .openMasterKeyEditor:
            selectedTab = .keys
            vm.showingMasterKeyField = true
        default:
            vm.applyPreflightFixAction(action)
        }
    }

    private func formatLatency(_ seconds: TimeInterval) -> String {
        if seconds < 1 {
            return "\(Int((seconds * 1000).rounded()))ms"
        }
        return String(format: "%.2fs", seconds)
    }

    private func requestDetailRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(.caption2, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func sessionRequestDisclosureBinding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { expandedSessionRequestIDs.contains(id) },
            set: { isExpanded in
                if isExpanded {
                    expandedSessionRequestIDs.insert(id)
                } else {
                    expandedSessionRequestIDs.remove(id)
                }
            }
        )
    }

    private func copySessionRequestJSON(_ request: SessionReportCard.RequestRecord) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(vm.sessionRequestJSON(request), forType: .string)
        copiedSessionRequestID = request.id
    }

    private func exportSessionRequestsCSV() {
        let csv = vm.sessionRequestsCSV()
        guard !csv.isEmpty else {
            sessionCSVExportStatus = "No session requests to export."
            return
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let suggestedName = "proxypilot-session-requests-\(formatter.string(from: Date())).csv"

        let panel = NSSavePanel()
        panel.title = "Export Session Requests CSV"
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
            sessionCSVExportStatus = "Exported \(vm.sessionReportCard.totalRequests) requests to \(url.path)"
        } catch {
            sessionCSVExportStatus = "CSV export failed: \(error.localizedDescription)"
        }
    }

    @ViewBuilder
    private func modelMetadataView(_ model: UpstreamModel, estimatedCostPerRequest: Double?) -> some View {
        if let ctx = model.contextFormatted {
            Text(ctx)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
        }

        let tier = model.pricingTier
        if !tier.label.isEmpty {
            Text(tier.label)
                .font(.caption2)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(
                    Capsule().fill(tier == .free ? Color.green.opacity(0.2) : Color.secondary.opacity(0.15))
                )
                .foregroundStyle(tier == .free ? .green : .secondary)
        }

        if let pricing = model.pricingPerMillionLabel {
            Text(pricing)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }

        if let estimatedCostPerRequest {
            Text("~\(vm.formatUSD(estimatedCostPerRequest))/req")
                .font(.caption2)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.blue.opacity(0.14)))
                .foregroundStyle(.blue)
                .help("Estimated from your current session average token usage.")
        }

        ForEach(model.capabilities.sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { cap in
            Text(cap.label)
                .font(.caption2)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.teal.opacity(0.15)))
                .foregroundStyle(.teal)
        }
    }

    private func shimmerOpacity(for active: Bool) -> Double {
        active ? (shimmerActive ? 1.0 : 0.4) : 1.0
    }

    private var headerProxyControls: some View {
        HStack(spacing: 8) {
            Button {
                Task { await vm.startProxy() }
            } label: {
                Image(systemName: "play.fill")
                    .foregroundStyle(vm.isRunning ? .green : .secondary)
                    .opacity(shimmerOpacity(for: vm.isRunning))
                    .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: shimmerActive)
            }
            .buttonStyle(.borderless)
            .disabled(vm.isRunning)
            .accessibilityLabel("Start proxy")

            Button {
                Task { await vm.stopProxy() }
            } label: {
                Image(systemName: "stop.fill")
                    .foregroundStyle(!vm.isRunning ? .red : .secondary)
                    .opacity(shimmerOpacity(for: !vm.isRunning))
                    .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: shimmerActive)
            }
            .buttonStyle(.borderless)
            .disabled(!vm.isRunning)
            .accessibilityLabel("Stop proxy")

            Button {
                Task { await vm.restartProxy() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .disabled(!vm.isRunning)
            .accessibilityLabel("Restart proxy")
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("ProxyPilot")
                    .font(.headline)
                Text("Local OpenAI-compatible proxy for Xcode Intelligence. Supports streaming and Anthropic API translation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            headerProxyControls
        }
        .padding(12)
        .background {
            if reduceTransparency {
                Color(nsColor: .windowBackgroundColor)
            } else {
                Rectangle().fill(.ultraThinMaterial)
            }
        }
        .onAppear { shimmerActive = true }
    }

    private var routingVerificationCommands: String {
        """
        tail -f /tmp/proxypilot_builtin_proxy.log

        rg -n "anthropic model remap" /tmp/proxypilot_builtin_proxy.log | tail -n 8

        rg -n "preferred=\(vm.effectiveXcodeAgentModel)" /tmp/proxypilot_builtin_proxy.log | tail -n 3
        """
    }

    private func copyRoutingVerificationCommands() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(routingVerificationCommands, forType: .string)
        routingVerificationCopied = true
    }

    private func keyRow(
        title: String,
        isPresent: Bool,
        isEditing: Bool,
        draft: Binding<String>,
        onEditToggle: @escaping () -> Void,
        onSave: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                Spacer()
                Text(isPresent ? String(localized: "Saved") : String(localized: "Missing"))
                    .font(.caption)
                    .foregroundStyle(isPresent ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.red))
            }

            if isEditing {
                SecureField("Enter value", text: draft)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Cancel") {
                        draft.wrappedValue = ""
                        onEditToggle()
                    }
                    Button("Save") { onSave() }
                        .disabled(draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Spacer()
                }
            } else {
                HStack {
                    Button(isPresent ? "Change" : "Set") { onEditToggle() }
                    if isPresent {
                        Button("Delete") { onDelete() }
                            .foregroundStyle(Color.red)
                    }
                    Spacer()
                }
            }
        }
    }
}

private struct KeychainAccessPrimerView: View {
    @EnvironmentObject private var vm: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Heads up: macOS may ask for your password")
                .font(.title3.bold())

            Text("ProxyPilot stores your API keys in macOS Keychain. If this build or update needs renewed Keychain trust, macOS may show one or more password prompts.")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Text("What to expect:")
                    .font(.headline)
                Text("• Prompt text will mention Keychain access for ProxyPilot")
                Text("• This only grants access to keys saved under the \"proxypilot\" service")
                Text("• Choose \"Always Allow\" to reduce repeated prompts")
            }
            .font(.callout)

            Toggle("Don't show this reminder again on this Mac", isOn: Binding(
                get: { vm.suppressKeychainAccessPrimer },
                set: { vm.suppressKeychainAccessPrimer = $0 }
            ))

            HStack {
                Spacer()
                Button("Continue") {
                    vm.dismissKeychainAccessPrimer()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}

private struct AnalyticsOptInView: View {
    var onEnable: () -> Void
    var onDisable: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Enable anonymous app analytics?")
                .font(.title3.bold())

            Text("ProxyPilot can collect anonymous debugging data to improve product quality for everyone. Please consider enabling this feature to support this open source project.")
                .foregroundStyle(.secondary)

            Text("All data collection is **disabled** by default.")
                .font(.callout)

            HStack {
                Spacer()
                Button("Leave Disabled") {
                    onDisable()
                }
                Button("Enable") {
                    onEnable()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}

private struct OnboardingWizardView: View {
    @EnvironmentObject private var vm: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Welcome to ProxyPilot")
                .font(.title2.bold())

            Text("ProxyPilot routes upstream LLM providers through Xcode Intelligence and Agent Mode. Set your API key, start the proxy, and install the Xcode Agent config from the General tab.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Toggle("Share anonymous diagnostics telemetry (optional)", isOn: Binding(
                get: { vm.telemetryOptIn },
                set: { vm.telemetryOptIn = $0 }
            ))
            .toggleStyle(.switch)

            Spacer()

            HStack {
                Button("Open README") {
                    vm.openReadme()
                }

                Spacer()

                Button("Get Started") {
                    vm.finishOnboarding(force: true)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 480, height: 240)
    }
}
