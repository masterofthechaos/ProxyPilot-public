import SwiftUI
import ProxyPilotCore

extension ContentView {
    var proxyTab: some View {
        ScrollViewReader { proxy in
            Form {
            Section("Set up Xcode") {
                Text("Choose a provider and model, then install ProxyPilot Agent for Xcode 27. Older Xcode versions can use Claude Agent compatibility setup below.")
                HStack {
                    Button("Providers & Models") { selectedSection = .models }
                    Button("Set Up Agent") {
                        if vm.showsAgentModeChoice { vm.selectedAgentMode = .proxyPilotAgent }
                        focusProxySection(.agentRegistration)
                    }
                }
                Text("After setup, select ProxyPilot in Xcode's agent picker. Wait for a response to finish before applying a model change; continue in the same conversation once the new model is running.")
                    .font(.caption).foregroundStyle(.secondary)
            }


            // Hidden until the shipped ACCA ruleset provides MVP functionality —
            // an empty ruleset makes the toggle a no-op, and no-op controls
            // must not reach users. See ContextCompactionFeatureGate.
            if ContextCompactionFeatureGate.isAvailable {
                Button("Context compaction settings") { openSettings(.connection) }
            }

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

            Section {
              DisclosureGroup("Chat provider setup and connection details") {
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
                        Text("Use this port-only option for credential-free local providers. Cloud providers need ProxyPilot Agent or the credentialed fields below so Xcode can send ProxyPilot's generated local credential.")
                            .font(.caption2)
                    }

                    DisclosureGroup("Internet Hosted / Credentialed Fields") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: "URL: " + vm.proxyURLString)
                            Text(verbatim: "API Key Header: Authorization")
                            Text(verbatim: "API Key: Bearer <Generated Local Proxy Credential>")
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

            }

            if vm.showsAgentModeChoice {
                Section("Xcode Agent Mode") {
                    Picker("Agent Mode", selection: $vm.selectedAgentMode) {
                        ForEach(AppViewModel.AgentMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(vm.proxyPilotAgentCapabilityText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if vm.showsAgentModeChoice && vm.selectedAgentMode == .proxyPilotAgent {
                Section("ProxyPilot Agent") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Image(systemName: vm.proxyPilotAgentSetupVerified
                                ? "checkmark.seal.fill" : "shippingbox")
                                .foregroundStyle(vm.proxyPilotAgentSetupVerified ? .green : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(vm.proxyPilotAgentSetupLabel)
                                    .font(.subheadline)
                                Text(vm.proxyPilotAgentStatusText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }

                        Text("Install once, then select ProxyPilot in Xcode’s agent picker. ProxyPilot handles the connection to your chosen provider and model.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if vm.proxyPilotAgentUsesManualRegistration && vm.proxyPilotAgentRegistrationStatus?.isRegistered != true {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Manual Registration Required")
                                    .font(.subheadline.weight(.semibold))
                                Text("In Xcode Settings > Intelligence, add an agent with these exact values:")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(vm.proxyPilotAgentManualRegistrationCommands)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .padding(8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color(nsColor: .controlBackgroundColor))
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            .padding(.vertical, 2)
                            .proxyFocusGlow(
                                isActive: highlightedProxySection == .agentRegistration,
                                color: vm.proxyPilotAccentColor
                            )
                        }

                        HStack(spacing: 12) {
                            Button(vm.isInstallingProxyPilotAgent ? "Installing..." : "Install or Repair") {
                                Task { await vm.installProxyPilotAgent() }
                            }
                            .disabled(vm.isInstallingProxyPilotAgent)

                            Button("Remove") {
                                Task { await vm.removeProxyPilotAgent() }
                            }
                            .foregroundStyle(.red)

                            Button("Refresh") {
                                Task { await vm.refreshProxyPilotAgentState() }
                            }
                            .disabled(vm.isInstallingProxyPilotAgent)
                            Spacer()
                        }

                        Text("Xcode usually refreshes Agent Modes automatically. Reopen Intelligence settings if a setup change is not visible yet.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        Divider()

                        agentXcodeInstallationsBlock

                        Divider()

                        agentUpstreamModelBlock

                        DisclosureGroup("Route details and verification") {
                            agentRouteStateBlock
                            agentLiveProofBlock
                            agentVisibleModelsBlock
                            agentRoutingVerificationBlock
                        }
                    }
                }
                .id(ProxySectionFocus.agentRegistration)
            }

            if !vm.showsAgentModeChoice || vm.selectedAgentMode == .claudeAgent {
                Section("Xcode Claude Agent Routing (Xcode 26.3+)") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Routes Xcode Claude Agent traffic through ProxyPilot. This is separate from Xcode's Chat Provider setup above.")
                        .font(.subheadline)
                    Text("Translates Anthropic /v1/messages to OpenAI-compatible upstream providers.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    agentXcodeInstallationsBlock

                    Divider()

                    agentUpstreamModelBlock

                    agentRouteStateBlock

                    agentLiveProofBlock

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

                    agentVisibleModelsBlock

                    Divider()

                    agentRoutingVerificationBlock
                }
                }
                .id(ProxySectionFocus.agentRegistration)
            }

            Section("Checklist") {
                if vm.selectedUpstreamRequiresAPIKey {
                    checklistRow(String(localized: "Upstream API key saved") + " (\(vm.upstreamProviderDisplayTitle))", isOn: vm.hasUpstreamKey)
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
}
