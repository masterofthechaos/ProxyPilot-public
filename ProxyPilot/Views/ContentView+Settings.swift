import SwiftUI
import ProxyPilotCore

extension ContentView {
    func openSettings(_ category: SettingsCategory) {
        settingsCategory = category
        selectedSection = .advanced
    }

    var settingsCategoryPicker: some View {
        Picker("Category", selection: $settingsCategory) {
            ForEach(SettingsCategory.allCases) { Text($0.rawValue).tag($0) }
        }.fixedSize()
    }

    var unifiedSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits {
                HStack { Text("Settings").font(.title2.bold()); Spacer(); settingsCategoryPicker }
                VStack(alignment: .leading) { Text("Settings").font(.title2.bold()); settingsCategoryPicker }
            }.padding(.horizontal, 24).padding(.top, 24)
            Group {
                switch settingsCategory {
                case .appearance: CustomizationView()
                case .general:
                    Form {
            Section("Background & Startup") {
                Toggle("Launch at Login", isOn: Binding(
                    get: { vm.launchAtLogin },
                    set: { _ in vm.toggleLaunchAtLogin() }
                ))
                .toggleStyle(.switch)
                .help("Automatically start ProxyPilot when you log in.")
                .accessibilityLabel("Launch at login")

                Toggle("Run in Background", isOn: Binding(
                    get: { vm.runInBackground },
                    set: { vm.runInBackground = $0 }
                ))
                .toggleStyle(.switch)
                .help("Hide the Dock icon and keep ProxyPilot running from the menu bar. Keeps the menu bar icon enabled so the app stays reachable.")
                .accessibilityLabel("Run in background")
            }
                        Section("Default destination") {
                            Picker("Open on launch", selection: Binding(get: { AppNavigationTarget.migrated(vm.defaultSettingsSection).section }, set: { vm.defaultSettingsSection = $0 })) {
                                ForEach(SettingsSection.sidebarSections) { Text($0.title).tag($0) }
                            }
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
                    }.formStyle(.grouped)
                case .connection:
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
            }
            Section(vm.requiresMasterKey ? "Local Proxy Password" : "Local Proxy Credential") {
                if vm.requiresMasterKey {
                    keyRow(
                        title: vm.masterKeyKeychainTitle,
                        isPresent: vm.hasMasterKey,
                        isEditing: vm.showingMasterKeyField,
                        draft: Binding(get: { vm.masterKeyDraft }, set: { vm.masterKeyDraft = $0 }),
                        onEditToggle: { vm.showingMasterKeyField.toggle() },
                        onSave: { vm.saveMasterKey() },
                        onDelete: { vm.deleteMasterKey() }
                    )
                } else {
                    LabeledContent(vm.masterKeyKeychainTitle) {
                        Text(vm.hasMasterKey ? "Stored in Keychain" : "Created when needed")
                            .foregroundStyle(.secondary)
                    }
                    Text("ProxyPilot creates and supplies this credential automatically. You do not need to type or rotate it during normal use.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Provider Cache Signals") {
                Picker("Mode", selection: Binding(
                    get: { vm.promptCachingMode },
                    set: { vm.promptCachingMode = $0 }
                )) {
                    Text(PromptCachingMode.computeCacheHints.displayTitle).tag(PromptCachingMode.computeCacheHints)
                    Text(PromptCachingMode.observeOnly.displayTitle).tag(PromptCachingMode.observeOnly)
                    Text(PromptCachingMode.off.displayTitle).tag(PromptCachingMode.off)
                }
                .pickerStyle(.segmented)
                .proxyFocusGlow(isActive: highlightedProxySection == .cacheSignals, color: vm.proxyPilotAccentColor)

                LabeledContent("Provider") {
                    Text(vm.upstreamProviderDisplayTitle)
                }

                LabeledContent("Signal") {
                    Text(vm.promptCachingMode.displayTitle)
                        .foregroundStyle(promptCachingModeColor)
                }

                Text(vm.promptCachingProviderStatusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
                        Section("Connection behavior") {
                            Toggle("Require authentication for local models", isOn: $vm.requireLocalAuth)
                            Text("Credential-backed routes are always protected.").font(.caption).foregroundStyle(.secondary)
                            Toggle("Auto-restart after an unexpected stop", isOn: $vm.autoRestartEnabled)
                            Toggle("Legacy translator fallback", isOn: $vm.anthropicTranslatorFallbackEnabled)
                        }
                        if ContextCompactionFeatureGate.isAvailable { ContextCompactionSettingsView() }
                    }.formStyle(.grouped)
                case .privacy:
                    Form {
                        Section("Diagnostics") {
                            Toggle("Share anonymous diagnostics", isOn: Binding(get: { vm.telemetryOptIn }, set: { vm.setTelemetryOptIn($0, surface: "settings_privacy") }))
                            Text(vm.alwaysOnTelemetryDisclosureText).font(.caption).foregroundStyle(.secondary)
                        }
                        InputOutputLoggingSettingsView { selectedSection = .models }
                    }.formStyle(.grouped)
                case .support:
                    Form {
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
                    Button("Xcode Setup Guide") { vm.showOnboardingWizard = true }
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


            Section("Companion Updates") {
                Text("GUI updates also refresh installed CLI copies and managed RepoGPS. Uninstalled tools stay uninstalled. Protected or package-managed installations may need their installer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !vm.companionUpdateStatusText.isEmpty {
                    Text(vm.companionUpdateStatusText).font(.caption).textSelection(.enabled)
                    Button("Retry Companion Updates") { Task { await vm.reconcileInstalledCompanions() } }
                }
                if !vm.protectedCLIUpdates.isEmpty {
                    Button("Authorize CLI Updates…") { Task { await vm.authorizeCompanionUpdates() } }
                    Text("macOS will request administrator authorization to update the existing protected CLI installation.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !vm.lastCLIExecutablePath.isEmpty {
                    Text("CLI used for key verification: " + vm.lastCLIExecutablePath)
                        .font(.caption).textSelection(.enabled)
                }
            }
                    }.formStyle(.grouped)
                }
            }.id(settingsCategory)
        }
        .alert("Reset ProxyPilot to Fresh Install?", isPresented: $showNuclearResetConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Reset Everything", role: .destructive) { Task { await vm.resetToFreshInstall() } }
        } message: {
            Text("This removes Xcode configuration, stored keys, logs and preferences.")
        }
    }
}
