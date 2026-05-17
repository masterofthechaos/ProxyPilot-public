import AppKit
import ProxyPilotCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var vm: AppViewModel
    @EnvironmentObject private var updateService: SoftwareUpdateService
    @State private var routingVerificationCopied: Bool = false
    @State private var showInstallConfirmation: Bool = false
    @State private var recoveryCommandsCopied: Bool = false
    @State private var diyCommandsCopied: Bool = false
    @State private var copilotInstallCommandCopied: Bool = false
    @State private var copilotLoginCommandCopied: Bool = false
    @AppStorage("proxypilot.preflightExpanded") private var preflightExpanded: Bool = true
    @State private var showNuclearResetConfirm: Bool = false
    @State private var selectedSection: SettingsSection = .home
    @State private var proxySectionFocus: ProxySectionFocus?
    @State private var highlightedProxySection: ProxySectionFocus?
    @State private var proxyFocusRequestID: Int = 0
    @State private var windowWidth: CGFloat = 0
    private let copilotSidecarInstallCommand = "npm install -g xcode-copilot-server"

    private var liquidGlassAppearanceAvailable: Bool {
        if #available(macOS 26.0, *) {
            return true
        }
        return false
    }

    private var effectiveLiquidGlassEnabled: Bool {
        liquidGlassAppearanceAvailable && vm.liquidGlassEnabled
    }

    var body: some View {
        Group {
            if usesNarrowStandaloneLayout {
                detailShell
                    .navigationTitle("\(settingsWindowTitle) - \(selectedSection.title)")
                    .toolbar {
                        settingsToolbar
                    }
            } else {
                splitSettingsBody
            }
        }
        .onAppear {
            if selectedSection == .home {
                selectedSection = vm.defaultSettingsSection
            }
            vm.refreshStatus()
            vm.runPreflightChecks()
            vm.startLogUpdates()
            vm.maybeShowKeychainAccessPrimerOnLaunch()
            vm.maybeShowAnalyticsPrompt()
            Task { await vm.refreshCopilotSidecarStatus() }
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
        .frame(minWidth: 680, minHeight: 620)
        .background {
            WindowWidthReader { width in
                windowWidth = width
            }
        }
        .environment(\.proxypilotLiquidGlassEnabled, effectiveLiquidGlassEnabled)
    }

    private var splitSettingsBody: some View {
        HStack(spacing: 0) {
            SettingsSidebarView(
                selection: $selectedSection,
                versionText: appVersionText,
                buildText: appBuildText
            )
            .frame(width: 238)

            Divider()

            detailShell
                .navigationTitle(settingsWindowTitle)
                .toolbar {
                    settingsToolbar
                }
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
    }

    private var settingsWindowTitle: String {
        AppBuildBadge.currentAppDisplayName
    }

    private var usesNarrowStandaloneLayout: Bool {
        windowWidth > 0 && windowWidth < 760
    }

    private var usesCollapsedTopNavigation: Bool {
        usesNarrowStandaloneLayout
    }

    private var detailShell: some View {
        VStack(spacing: 0) {
            if usesCollapsedTopNavigation {
                collapsedSectionTabs
                    .zIndex(1)
                Divider()
                    .zIndex(1)
            }

            detailContent
                .id(selectedSection)
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
                .zIndex(0)
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var collapsedSectionTabs: some View {
        HStack(spacing: 14) {
            collapsedTabButton(for: .home, showsIcon: true)

            GlassControlGroup(cornerRadius: 24, padding: 4) {
                HStack(spacing: 0) {
                    ForEach(Array(SettingsSection.collapsedTabSections.dropFirst().enumerated()), id: \.element) { index, section in
                        if index > 0 {
                            Rectangle()
                                .fill(Color(nsColor: .separatorColor).opacity(0.45))
                                .frame(width: 1, height: 24)
                                .padding(.horizontal, 4)
                        }

                        collapsedTabButton(for: section, showsIcon: false)
                    }
                }
            }

            collapsedCustomizationButton
        }
        .frame(minWidth: 0, maxWidth: .infinity)
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 16)
    }

    private func collapsedTabButton(for section: SettingsSection, showsIcon: Bool) -> some View {
        Button {
            selectedSection = section
        } label: {
            HStack(spacing: 6) {
                if showsIcon {
                    Image(systemName: section.systemImage)
                }
                Text(section.compactTitle)
            }
            .font(.callout.weight(selectedSection == section ? .semibold : .medium))
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .foregroundStyle(selectedSection == section ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .padding(.horizontal, showsIcon ? 16 : 14)
            .padding(.vertical, 10)
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .background {
                if selectedSection == section {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color(nsColor: .controlAccentColor).opacity(0.13))
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(section.title)
    }

    private var collapsedCustomizationButton: some View {
        Button {
            selectedSection = .customization
        } label: {
            Image(systemName: SettingsSection.customization.systemImage)
                .font(.callout.weight(selectedSection == .customization ? .semibold : .medium))
                .foregroundStyle(selectedSection == .customization ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(width: 34, height: 34)
                .contentShape(Circle())
                .background {
                    if selectedSection == .customization {
                        Circle()
                            .fill(Color(nsColor: .controlAccentColor).opacity(0.13))
                    }
                }
        }
        .buttonStyle(.plain)
        .help("Open Customization")
        .accessibilityLabel("Open Customization")
    }

    @ViewBuilder
    private var detailContent: some View {
        switch selectedSection {
        case .home:
            HomeDashboardView(
                showInstallConfirmation: $showInstallConfirmation,
                onOpenKeys: { selectedSection = .keys },
                onOpenProxy: { selectedSection = .proxy },
                onOpenAgentModel: { focusProxySection(.models) },
                onOpenPreflight: {
                    selectedSection = .proxy
                    preflightExpanded = true
                    vm.runPreflightChecks()
                },
                onOpenSessionHistory: { selectedSection = .history }
            )
            .environmentObject(vm)
        case .history:
            SessionHistoryView(
                prefersCompactLayout: usesCollapsedTopNavigation,
                onOpenAdvancedLogging: { selectedSection = .advanced }
            )
                .environmentObject(vm)
        case .proxy:
            proxyTab
        case .keys:
            keysTab
        case .advanced:
            advancedTab
        case .customization:
            CustomizationView()
        }
    }

    @ToolbarContentBuilder
    private var settingsToolbar: some ToolbarContent {
        if vm.shouldShowToolbarStatus {
            ToolbarItem(placement: .navigation) {
                StatusToolbarLabel(isRunning: vm.isRunning, statusText: vm.statusText)
            }
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                Task { await vm.startProxy() }
            } label: {
                Label("Start", systemImage: "play.fill")
            }
            .disabled(!vm.canStartProxy)
            .tint(.green)
            .help("Start ProxyPilot local proxy")

            Button {
                Task { await vm.stopProxy() }
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .disabled(!vm.canStopProxy)
            .tint(.red)
            .help("Stop the running ProxyPilot proxy")

            Button {
                Task { await vm.restartProxy() }
            } label: {
                Label("Restart", systemImage: "arrow.clockwise")
            }
            .disabled(!vm.canRestartProxy)
            .help("Restart ProxyPilot local proxy")
        }

        if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                vm.refreshStatus()
            } label: {
                Label("Refresh", systemImage: "arrow.triangle.2.circlepath")
            }
            .help(AppViewModel.refreshProxyStatusHelpText)
        }

        if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                updateService.checkForUpdates()
            } label: {
                Label("Check for Updates", systemImage: "arrow.down.circle")
            }
            .disabled(!updateService.canCheckForUpdates)
            .help("Check for ProxyPilot updates")

            Menu {
                Button("README") { vm.openReadme() }
                Button("Website") { vm.openWebsite() }
                Button("Report Bug on GitHub") { vm.openGitHubBugReport() }
                Button("Send Feedback by Email") { vm.openFeedbackDraft() }
                Divider()
                Button("Export Diagnostics") { vm.exportDiagnostics() }
                Button("Copy Support Summary") { vm.copySupportSummaryToPasteboard() }
            } label: {
                Label("Help", systemImage: "questionmark.circle")
            }
        }
    }

    private var appVersionText: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    private var appBuildText: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }

    private func focusProxySection(_ focus: ProxySectionFocus) {
        selectedSection = .proxy
        proxySectionFocus = focus
        highlightedProxySection = focus
        proxyFocusRequestID += 1

        let requestID = proxyFocusRequestID
        let delay = UInt64(focus.highlightDurationSeconds * 1_000_000_000)
        Task {
            try? await Task.sleep(nanoseconds: delay)
            await MainActor.run {
                guard proxyFocusRequestID == requestID,
                      highlightedProxySection == focus else { return }
                withAnimation(.easeOut(duration: 0.35)) {
                    highlightedProxySection = nil
                }
            }
        }
    }

    private func applyPendingProxyFocus(with proxy: ScrollViewProxy) {
        guard selectedSection == .proxy,
              let focus = proxySectionFocus else { return }

        proxySectionFocus = nil
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.28)) {
                proxy.scrollTo(focus, anchor: .top)
            }
        }
    }

    // MARK: - Proxy Tab

    private var proxyTab: some View {
        ScrollViewReader { proxy in
            Form {
            Section("Proxy") {
                HStack(spacing: 8) {
                    TextField("Proxy URL", text: Binding(
                        get: { vm.proxyURLString },
                        set: { vm.proxyURLString = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .help("Use \(AppViewModel.defaultProxyURLString) for built-in mode.")

                    Button {
                        vm.resetProxyURLToDefault()
                    } label: {
                        Image(systemName: "arrow.counterclockwise.circle")
                    }
                    .buttonStyle(.plain)
                    .controlSize(.small)
                    .disabled(vm.proxyURLString == AppViewModel.defaultProxyURLString)
                    .help("Reset proxy URL to default")
                    .accessibilityLabel("Reset proxy URL")
                    .accessibilityHint("Sets proxy URL to \(AppViewModel.defaultProxyURLString)")
                }

                HStack(spacing: 12) {
                    Button("Start") { Task { await vm.startProxy() } }
                        .disabled(!vm.canStartProxy)
                        .accessibilityLabel("Start local proxy server")
                        .accessibilityHint("Starts ProxyPilot local proxy for Xcode.")

                    Button("Stop") { Task { await vm.stopProxy() } }
                        .disabled(!vm.canStopProxy)
                        .accessibilityLabel("Stop local proxy server")
                        .accessibilityHint("Stops the local proxy server.")

                    Button("Restart") { Task { await vm.restartProxy() } }
                        .disabled(!vm.canRestartProxy)
                        .accessibilityLabel("Restart local proxy server")
                        .accessibilityHint("Restarts the local proxy server.")

                    Spacer()

                    Button("Refresh") { vm.refreshStatus() }
                        .accessibilityLabel("Refresh proxy status")
                        .help(AppViewModel.refreshProxyStatusHelpText)
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
                    DisclosureGroup("Terms") {
                        Text(vm.contextualTerminologyHelpText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .font(.caption)
                } else {
                    Text("LiteLLM mode requires scripts in `~/tools/litellm/`.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Button { selectedSection = .advanced } label: {
                Text("Local auth, startup behavior, and more in **Advanced**.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            Section("Preflight") {
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        preflightExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: preflightExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(preflightExpanded ? "Hide preflight checks" : "Show preflight checks")
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

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
            }
            .onAppear {
                vm.runPreflightChecks()
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
                        Text("\(vm.upstreamProvider.title) support is in **Preview** and may be unstable. [Report issues on GitHub.](https://github.com/masterofthechaos/ProxyPilot-public/issues)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Text(vm.cloudProviderActionDisclosureText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                Button { selectedSection = .keys } label: {
                    Text("Manage API keys and provider helpers in the **Keys & Providers** tab.")
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
                        .proxyFocusGlow(isActive: highlightedProxySection == .models, color: vm.proxyPilotAccentColor)
                    Button("Sync To Proxy + Restart") { Task { await vm.syncProxyModelsFromSelection() } }
                        .disabled(!vm.canSyncProxyModels)
                    Button("Save as Defaults") { vm.saveSelectedModelsAsDefaults() }
                        .disabled(!vm.canSaveSelectedModelsAsDefaults)
                    Spacer()
                    if vm.modelSelectionRows.isEmpty {
                        Text("No models configured — fetch to get started")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else {
                        Text(verbatim: "\(vm.selectedModelRowCount)/\(vm.modelSelectionRows.count) " + String(localized: "selected"))
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
                        Toggle("Use Exacto routing for tool-capable models", isOn: Binding(
                            get: { vm.exactoFilterEnabled },
                            set: { vm.exactoFilterEnabled = $0 }
                        ))
                        .toggleStyle(.switch)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Shows OpenRouter models that advertise tool calling and appends :exacto to selected slugs. OpenRouter Auto Exacto also applies automatically to tool-calling requests.")

                        Toggle("Show ProxyPilot Verified only", isOn: Binding(
                            get: { vm.verifiedFilterEnabled },
                            set: { vm.verifiedFilterEnabled = $0 }
                        ))
                        .toggleStyle(.switch)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                if !vm.modelSelectionRows.isEmpty {
                    HStack(spacing: 12) {
                        Button("Select All") { vm.selectAllUpstreamModels() }
                            .font(.caption)
                            .disabled(vm.allVisibleModelsSelected)
                        Button("Clear Selection") { vm.clearUpstreamModelSelection() }
                            .font(.caption)
                            .disabled(!vm.canClearModelSelection)
                        Spacer()
                    }
                }

                if vm.modelSelectionRows.isEmpty {
                    Text("Fetch models from your provider, select the ones you want, then save as defaults.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    if vm.hasSavedDefaultModels {
                        Text("Saved defaults stay selected and protected. Use Remove Default to unpin one.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    List(vm.modelSelectionRows) { row in
                        HStack(spacing: 10) {
                            Toggle(isOn: Binding(
                                get: { vm.isModelSelected(row.id) },
                                set: { vm.setModelSelected(row.id, isSelected: $0) }
                            )) {
                                modelSelectionRowLabel(row)
                            }
                            .disabled(row.isDefault)

                            if row.isDefault {
                                Button("Remove Default") {
                                    vm.removeDefaultModel(row.id)
                                }
                                .font(.caption)
                            }
                        }
                    }
                    .frame(minHeight: 120)
                }
            }
            .id(ProxySectionFocus.models)

            Section("Xcode") {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Xcode Chat Provider (Locally Hosted)")
                            .font(.subheadline)
                        Text("In Xcode -> Settings -> Intelligence -> Add a Chat Provider -> Locally Hosted:")
                            .font(.caption)
                        Text(verbatim: "Port: " + vm.xcodeLocallyHostedPortText)
                        Text(verbatim: "Description: ProxyPilot")
                        Text(verbatim: "Model validation: " + vm.proxyModelsEndpointText)
                            .font(.caption2)
                    }

                    DisclosureGroup("Internet Hosted / Legacy Fields") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: "URL: " + vm.proxyURLString)
                            Text(verbatim: "API Key Header: Authorization")
                            Text(verbatim: "API Key: Bearer <Local Proxy Password>")
                        }
                        .font(.caption)
                    }
                    .font(.caption)
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Local Proxy Exposure")
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                    LabeledContent("Bind address") {
                        Text(vm.localProxyBindAddressText)
                            .textSelection(.enabled)
                    }
                    LabeledContent("Port") {
                        Text(vm.localProxyPortText)
                            .textSelection(.enabled)
                    }
                    LabeledContent("Auth") {
                        Text(vm.localProxyAuthStateText)
                    }
                    Text(vm.localProxyWhoCanConnectText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .font(.caption)
            }

            Section("Xcode Claude Agent Routing (Xcode 26.3+)") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Routes Xcode Claude Agent traffic through ProxyPilot. This is separate from Xcode's Chat Provider setup above.")
                        .font(.subheadline)
                    Text("Translates Anthropic /v1/messages to OpenAI-compatible upstream providers.")
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

                    Text(verbatim: vm.xcodeAgentRoutingSummaryText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Route State")
                            .font(.subheadline)
                        LabeledContent("Selected") {
                            Text(vm.xcodeAgentSelectedModelText)
                                .textSelection(.enabled)
                        }
                        LabeledContent("Pending") {
                            Text(vm.xcodeAgentPendingModelText)
                                .textSelection(.enabled)
                        }
                        LabeledContent("Applied") {
                            Text(vm.xcodeAgentAppliedModelText)
                                .textSelection(.enabled)
                        }
                        LabeledContent("Live") {
                            Text(vm.xcodeAgentLiveRouteText)
                                .textSelection(.enabled)
                        }
                    }
                    .font(.caption)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Last Xcode Agent Live Proof")
                            .font(.subheadline)
                        Text(vm.xcodeAgentLiveProofText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }

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

                    DisclosureGroup("Routing Change Preview") {
                        Text(vm.xcodeAgentConfigPreviewText)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .font(.caption)

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
                        Button(vm.agentConfigInstalled ? "Reinstall" : "Install") {
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

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Xcode-Visible Models Right Now")
                                .font(.subheadline)
                            Spacer()
                            Button(vm.isRefreshingXcodeVisibleModels ? "Refreshing..." : "Refresh") {
                                Task { await vm.refreshXcodeVisibleModels() }
                            }
                            .disabled(vm.isRefreshingXcodeVisibleModels)
                        }

                        LabeledContent("Source") {
                            Text(vm.xcodeVisibleModelsSourceText)
                        }
                        LabeledContent("Count") {
                            Text("\(vm.xcodeVisibleModelsSnapshot.modelIDs.count)")
                        }
                        LabeledContent("Checked") {
                            Text(vm.xcodeVisibleModelsTimestampText)
                        }
                        Text(vm.xcodeVisibleModelsStatusText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(vm.xcodeVisibleModelsListText)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .font(.caption)

                    Divider()

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Verify Xcode Agent Routing (Terminal)")
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
            }

            Section("Checklist") {
                if vm.upstreamProvider.requiresAPIKey {
                    checklistRow(String(localized: "Upstream API key saved") + " (\(vm.upstreamProvider.title))", isOn: vm.hasUpstreamKey)
                }
                checklistRow(vm.masterKeyChecklistTitle, isOn: vm.hasRequiredMasterKey)
                checklistRow(String(localized: "Proxy URL looks valid"), isOn: vm.checklistIsProxyURLValid)
                HStack {
                    checklistRow(String(localized: "Proxy is running"), isOn: vm.isRunning)
                    if vm.canStartProxy {
                        Button("Start Proxy") { Task { await vm.startProxy() } }
                            .font(.caption)
                    }
                }

                HStack(spacing: 12) {
                    Button("Fetch Proxy Models") { Task { await vm.testModels() } }
                    Button("Test Upstream Response") { Task { await vm.testUpstreamResponse() } }
                    Spacer()
                }

                Text(vm.cloudProviderActionDisclosureText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

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
                Text(vm.diagnosticsPreviewText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
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
                    Button("GitHub") { vm.openPublicRepository() }
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
                            .help(AppViewModel.refreshProxyStatusHelpText)
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
            .onAppear {
                applyPendingProxyFocus(with: proxy)
            }
            .onChange(of: proxyFocusRequestID) { _, _ in
                applyPendingProxyFocus(with: proxy)
            }
        }
    }

    // MARK: - Keys Tab

    @State private var showAddCustomProviderSheet = false

    private var keysTab: some View {
        Form {
            if vm.isKeysProviderVisible(.githubCopilot) {
                copilotSidecarSection
            }

            Section {
                Text("API keys are stored in macOS Keychain under the \"proxypilot\" service. Local providers do not require API keys in ProxyPilot.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if orderedVisibleKeysProviders.isEmpty {
                    Text("No built-in providers are visible. Re-enable providers from Customization.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                } else {
                    ForEach(orderedVisibleKeysProviders, id: \.self) { provider in
                        if provider.requiresAPIKey {
                            providerKeyRow(provider)
                        } else {
                            localProviderSetupRow(provider)
                        }
                    }
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

    private var orderedVisibleKeysProviders: [UpstreamProvider] {
        vm.keysProviderOrder
            .map(\.provider)
            .filter { vm.isKeysProviderVisible($0) }
    }

    private var copilotSidecarSection: some View {
        Section("GitHub Copilot (Beta)") {
            DisclosureGroup(isExpanded: Binding(
                get: { vm.copilotSidecarExpanded },
                set: { vm.copilotSidecarExpanded = $0 }
            )) {
                VStack(alignment: .leading, spacing: 8) {
                    copilotSidecarDetails
                }
                .padding(.top, 6)
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("Copilot helper")
                                .font(.subheadline.bold())
                            Text("Beta")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.16), in: Capsule())
                                .foregroundStyle(.orange)
                        }
                        Text("Runs xcode-copilot-server locally on port 8080 after GitHub Copilot authentication is set up.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Label(copilotSidecarBadgeTitle, systemImage: copilotSidecarBadgeSystemImage)
                        .font(.caption)
                        .foregroundStyle(copilotSidecarBadgeColor)
                }
            }
        }
    }

    @ViewBuilder
    private var copilotSidecarDetails: some View {
        if !vm.copilotSidecarExecutablePath.isEmpty {
            Text(verbatim: "Executable: \(vm.copilotSidecarExecutablePath)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }

        if !vm.copilotSidecarStatusText.isEmpty {
            Text(vm.copilotSidecarStatusText)
                .font(.caption)
                .foregroundStyle(colorForCopilotSidecarStatus())
                .textSelection(.enabled)
        }

        VStack(alignment: .leading, spacing: 4) {
            Text(vm.isCopilotSidecarGitHubAuthenticated ? "GitHub sign-in detected" : "Sign in before helper setup")
                .font(.caption.bold())
            Text(vm.copilotSidecarLoginDescription)
                .font(.caption)
                .foregroundStyle(vm.isCopilotSidecarGitHubAuthenticated ? .green : .secondary)
                .textSelection(.enabled)
        }

        HStack(spacing: 12) {
            if !vm.isCopilotSidecarGitHubAuthenticated {
                Button(copilotSidecarLoginActionTitle) {
                    performCopilotSidecarLoginAction()
                }
            }

            Button(copilotSidecarPrimaryActionTitle) {
                performCopilotSidecarPrimaryAction()
            }
            .disabled(copilotSidecarPrimaryActionDisabled)

            if !vm.copilotSidecarExecutablePath.isEmpty {
                Button(copilotSidecarSecondaryActionTitle) {
                    Task { await vm.stopCopilotSidecar() }
                }
                .disabled(copilotSidecarSecondaryActionDisabled)
            }

            Button("Refresh") {
                Task { await vm.refreshCopilotSidecarStatus() }
            }

            Button(vm.isTestingCopilotToolCall ? "Testing Tool Call..." : "Test Tool Call") {
                Task { await vm.testCopilotToolCall() }
            }
            .disabled(vm.isTestingCopilotToolCall || vm.copilotSidecarExecutablePath.isEmpty)

            Button(vm.isCopilotSidecarLogVisible ? "Refresh Log" : "Show Log") {
                vm.openCopilotSidecarLog()
            }

            Spacer()
        }

        if copilotInstallCommandCopied && vm.copilotSidecarExecutablePath.isEmpty {
            Text("Copied install command: \(copilotSidecarInstallCommand)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }

        if copilotLoginCommandCopied {
            Text("Copied login commands: copilot login or gh auth login")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }

        if !vm.copilotToolCallTestOutput.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Label(copilotToolCallResultTitle, systemImage: copilotToolCallResultSystemImage)
                    .foregroundStyle(copilotToolCallResultColor)
                if !vm.copilotToolCallTestModelUsed.isEmpty {
                    Text("Tool-call test model: \(vm.copilotToolCallTestModelUsed)")
                        .foregroundStyle(.secondary)
                }
                Text(vm.copilotToolCallTestOutput)
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .textSelection(.enabled)
        }

        if vm.isCopilotSidecarLogVisible {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("Copilot sidecar log", systemImage: "doc.text.magnifyingglass")
                        .font(.caption.bold())
                    Spacer()
                    Button("Refresh") {
                        vm.openCopilotSidecarLog()
                    }
                }

                if !vm.copilotSidecarLogStatusText.isEmpty {
                    Text(vm.copilotSidecarLogStatusText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                ScrollView {
                    Text(vm.copilotSidecarLogText)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 180)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
            }
        }

        VStack(alignment: .leading, spacing: 2) {
            Text("Requires your own GitHub Copilot access, authentication, and `xcode-copilot-server`.")
            Text("Test Tool Call sends a tiny streaming request and may consume GitHub AI Credits. GitHub controls billing, budgets, model access, authentication, and limits.")
            Text(.init("As of 5-17-2026, GitHub is actively changing their Copilot subscription service. New users may not sign up, and existing users may encounter unexpected limits. For the latest, refer to [official documentation](https://docs.github.com/en/copilot/get-started/plans)."))
        }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)

        HStack(spacing: 4) {
            Text("Thanks to")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Button("theblixguy/xcode-copilot-server") {
                vm.openCopilotSidecarProject()
            }
            .buttonStyle(.link)
            .font(.caption2)
            Text("which powers the Copilot sidecar.")
                .font(.caption2)
                .foregroundStyle(.secondary)
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
                    Text("Not configured")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
    private func localProviderSetupRow(_ provider: UpstreamProvider) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(provider.title)
                    .font(.subheadline.bold())
                Spacer()
                Text("No API key required")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            LabeledContent("Default URL") {
                Text(provider.defaultAPIBaseURL)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }

            LabeledContent("Server status") {
                Text(vm.localProviderStatusText(for: provider))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Text(vm.localProviderSetupHint(for: provider))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .font(.caption)
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
                        Text("Key for \(provider.title) is stored in Keychain")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    let isSelectedProvider = vm.upstreamProvider == provider
                    Text(isSelectedProvider ? "Missing key" : "Not configured")
                        .font(.caption)
                        .foregroundStyle(isSelectedProvider ? .orange : .secondary)
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
                    if let cliStatusText = vm.providerCLIAuthStatusText(for: provider) {
                        Text(cliStatusText)
                            .font(.caption2)
                            .foregroundStyle(vm.providerCLIAuthStatusIsWarning(for: provider) ? .orange : .secondary)
                            .textSelection(.enabled)
                    }
                    providerKeyTestStatusView(testState)
                    if vm.upstreamProvider == provider {
                        Text(vm.cloudProviderActionDisclosureText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
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
                .help("Optional analytics are off by default. Minimal app-open and version health reporting stays on.")

                Text(vm.alwaysOnTelemetryDisclosureText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Section("Updates") {
                Toggle("Include alpha channel updates", isOn: Binding(
                    get: { updateService.alphaUpdatesEnabled },
                    set: { updateService.alphaUpdatesEnabled = $0 }
                ))
                .toggleStyle(.switch)
                .help("Allows Sparkle to offer alpha-channel builds when the appcast publishes them.")

                Text(updateService.alphaUpdatesEnabled
                     ? "Sparkle will include alpha-channel releases in update checks. Turn this off to return to the stable update channel before checking again."
                     : "Stable update checks stay on the main appcast channel. Alpha builds can be offered later through Sparkle channel metadata without changing the app.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            InputOutputLoggingSettingsView {
                selectedSection = .proxy
            }
            .environmentObject(vm)

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
                    Button(preflightFixActionTitle(result.fixAction)) {
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
        case .confirmed:
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
        case .confirmed:
            return .secondary
        case .info:
            return .secondary
        case .warning:
            return .orange
        case .fail:
            return .red
        }
    }

    private func preflightFixActionTitle(_ action: PreflightFixAction) -> String {
        switch action {
        case .openCopilotLogin:
            return "Sign In"
        default:
            return "Fix"
        }
    }

    private func colorForCopilotSidecarStatus() -> Color {
        if vm.isCopilotSidecarRunning || vm.isCopilotSidecarAgentInstalled { return .secondary }

        let status = vm.copilotSidecarStatusText.lowercased()
        if status.contains("not installed")
            || status.contains("did not stay running")
            || status.contains("failed")
            || status.contains("already responding") {
            return .orange
        }
        return .secondary
    }

    private var copilotSidecarBadgeTitle: String {
        if vm.copilotSidecarExecutablePath.isEmpty { return "Not Installed" }
        if vm.isCopilotSidecarExternal { return "External" }
        if vm.isCopilotSidecarAgentInstalled && vm.isCopilotSidecarEndpointResponding { return "Running" }
        if vm.isCopilotSidecarAgentInstalled { return "Background" }
        if vm.isCopilotSidecarDirectProcessRunning { return "Running" }
        return "Stopped"
    }

    private var copilotSidecarBadgeSystemImage: String {
        if vm.copilotSidecarExecutablePath.isEmpty { return "exclamationmark.circle" }
        if vm.isCopilotSidecarAgentInstalled || vm.isCopilotSidecarEndpointResponding || vm.isCopilotSidecarDirectProcessRunning {
            return "checkmark.circle.fill"
        }
        return "circle"
    }

    private var copilotSidecarBadgeColor: Color {
        if vm.copilotSidecarExecutablePath.isEmpty { return .orange }
        if vm.isCopilotSidecarAgentInstalled || vm.isCopilotSidecarEndpointResponding || vm.isCopilotSidecarDirectProcessRunning {
            return .green
        }
        return .secondary
    }

    private var copilotToolCallResultTitle: String {
        if vm.isTestingCopilotToolCall {
            return "Tool-call test running"
        }

        switch vm.copilotToolCallTestSucceeded {
        case .some(true):
            return "Tool-call test succeeded"
        case .some(false):
            return "Tool-call test needs attention"
        case .none:
            return "Tool-call test status"
        }
    }

    private var copilotToolCallResultSystemImage: String {
        if vm.isTestingCopilotToolCall {
            return "clock"
        }

        switch vm.copilotToolCallTestSucceeded {
        case .some(true):
            return "checkmark.circle.fill"
        case .some(false):
            return "exclamationmark.triangle.fill"
        case .none:
            return "info.circle.fill"
        }
    }

    private var copilotToolCallResultColor: Color {
        if vm.isTestingCopilotToolCall {
            return .secondary
        }

        switch vm.copilotToolCallTestSucceeded {
        case .some(true):
            return .green
        case .some(false):
            return .orange
        case .none:
            return .secondary
        }
    }

    private var copilotSidecarPrimaryActionTitle: String {
        if vm.isStartingCopilotSidecar { return "Installing..." }
        if vm.copilotSidecarExecutablePath.isEmpty {
            return copilotInstallCommandCopied ? "Copied Install Command" : "Copy Install Command"
        }
        return (vm.copilotSidecarSupportsLaunchAgent || vm.isCopilotSidecarAgentInstalled)
            ? "Install Background Helper"
            : "Start Helper"
    }

    private var copilotSidecarPrimaryActionDisabled: Bool {
        if vm.copilotSidecarExecutablePath.isEmpty {
            return false
        }
        return vm.isStartingCopilotSidecar
            || vm.isCopilotSidecarAgentInstalled
            || vm.isCopilotSidecarEndpointResponding
    }

    private var copilotSidecarLoginActionTitle: String {
        vm.copilotSidecarLoginCommand.isEmpty
            ? "Copy Login Commands"
            : "Open \(vm.copilotSidecarLoginCommand)"
    }

    private var copilotSidecarSecondaryActionTitle: String {
        (vm.copilotSidecarSupportsLaunchAgent || vm.isCopilotSidecarAgentInstalled)
            ? "Remove Background Helper"
            : "Stop Helper"
    }

    private var copilotSidecarSecondaryActionDisabled: Bool {
        if vm.isStartingCopilotSidecar { return true }
        if vm.copilotSidecarSupportsLaunchAgent || vm.isCopilotSidecarAgentInstalled {
            return !vm.isCopilotSidecarAgentInstalled || vm.copilotSidecarExecutablePath.isEmpty
        }
        return !vm.isCopilotSidecarDirectProcessRunning
    }

    private func performCopilotSidecarPrimaryAction() {
        if vm.copilotSidecarExecutablePath.isEmpty {
            copyCopilotSidecarInstallCommand()
            return
        }

        Task { await vm.startCopilotSidecar() }
    }

    private func performCopilotSidecarLoginAction() {
        copilotLoginCommandCopied = false
        if vm.copilotSidecarLoginCommand.isEmpty {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("copilot login\n# or\ngh auth login", forType: .string)
            copilotLoginCommandCopied = true
            return
        }

        Task { await vm.openCopilotLoginTerminal() }
    }

    private func copyCopilotSidecarInstallCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copilotSidecarInstallCommand, forType: .string)
        copilotInstallCommandCopied = true
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
            selectedSection = .keys
            if vm.upstreamProvider.requiresAPIKey {
                vm.providerKeyEditing[vm.upstreamProvider] = true
                vm.providerKeyDrafts[vm.upstreamProvider] = nil
            }
        case .openMasterKeyEditor:
            selectedSection = .keys
            vm.showingMasterKeyField = true
        case .openCopilotLogin:
            performCopilotSidecarLoginAction()
        default:
            vm.applyPreflightFixAction(action)
        }
    }

    @ViewBuilder
    private func modelSelectionRowLabel(_ row: ProviderManager.ModelSelectionRow) -> some View {
        HStack(spacing: 6) {
            Text(row.id)
                .font(.system(.body, design: .monospaced))

            if row.isDefault {
                Text("Default")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.accentColor.opacity(0.16)))
                    .foregroundStyle(Color.accentColor)
            }

            if !row.isLive {
                Text("Saved only")
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.14)))
                    .foregroundStyle(.secondary)
            }

            if vm.showModelMetadata, let model = row.model {
                modelMetadataView(
                    model,
                    estimatedCostPerRequest: vm.estimatedRequestCostUSD(for: model)
                )
            }
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

private extension View {
    func proxyFocusGlow(isActive: Bool, color: Color) -> some View {
        modifier(ProxyFocusGlowModifier(isActive: isActive, glowColor: color))
    }
}

private struct ProxyFocusGlowModifier: ViewModifier {
    let isActive: Bool
    let glowColor: Color

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(glowColor.opacity(isActive ? 0.9 : 0), lineWidth: isActive ? 2 : 0)
                    .padding(-3)
            }
            .shadow(color: glowColor.opacity(isActive ? 0.75 : 0), radius: isActive ? 10 : 0)
            .animation(.easeInOut(duration: 0.22), value: isActive)
    }
}

private struct StatusToolbarLabel: View {
    let isRunning: Bool
    let statusText: String

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isRunning ? Color.green : Color.secondary)
                .frame(width: 7, height: 7)

            Text(statusText)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(minWidth: 92, maxWidth: 190, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Proxy status \(statusText)")
        .help("Proxy status: \(statusText)")
    }
}

private struct WindowWidthReader: NSViewRepresentable {
    let onChange: (CGFloat) -> Void

    func makeNSView(context: Context) -> WidthReportingView {
        let view = WidthReportingView()
        view.onWidthChange = onChange
        return view
    }

    func updateNSView(_ nsView: WidthReportingView, context: Context) {
        nsView.onWidthChange = onChange
        nsView.reportWindowWidth()
    }

    @MainActor
    final class WidthReportingView: NSView {
        var onWidthChange: ((CGFloat) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            reportWindowWidth()
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            reportWindowWidth()
        }

        func reportWindowWidth() {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.onWidthChange?(self.window?.frame.width ?? self.bounds.width)
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
            Text("Please consider sharing basic, anonymous analytics.")
                .font(.title3.bold())

            Text("ProxyPilot uses anonymous analytics to spot crashes and confirm that updates work. By default, it only reports app opens and app version; opting in also includes successful proxy engagement and crash reporting. Prompts, endpoint IDs, and system info are never collected, and you can change this any time in Customization.")
                .foregroundStyle(.secondary)

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

            Text("ProxyPilot routes upstream LLM providers through Xcode Intelligence and Agent Mode. Set your API key, start the proxy, and install the Xcode Agent config from the Proxy tab.")
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
