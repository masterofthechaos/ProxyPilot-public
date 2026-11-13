import AppKit
import ProxyPilotCore
import SwiftUI

/// Bounds for the Models page's "Fetch Live Models" list. `maxHeight` keeps a provider
/// with hundreds of non-collapsible models (OpenRouter in particular) scrolling inside
/// its own box instead of pushing the Xcode/Agent sections off screen.
enum ModelSelectionListLayout {
    static let minHeight: CGFloat = 120
    static let maxHeight: CGFloat = 400
}

struct ContentView: View {
    @EnvironmentObject var vm: AppViewModel
    @EnvironmentObject var updateService: SoftwareUpdateService
    @State var routingVerificationCopied: Bool = false
    @State var showInstallConfirmation: Bool = false
    @State var recoveryCommandsCopied: Bool = false
    @State var diyCommandsCopied: Bool = false
    @AppStorage("proxypilot.preflightExpanded") var preflightExpanded: Bool = true
    @State var showNuclearResetConfirm: Bool = false
    @State var confirmToolbarRestart = false
    @State var settingsCategory: SettingsCategory = .general
    @State var selectedSection: SettingsSection = .home
    @State var proxySectionFocus: ProxySectionFocus?
    @State var highlightedProxySection: ProxySectionFocus?
    @State var proxyFocusRequestID: Int = 0
    @State var windowWidth: CGFloat = 0
    @State var sidebarIsCollapsed = false
    @AppStorage("proxypilot.layoutModePreference") var layoutModePreference: LayoutModePreference = .automatic
    @State var modelSearchText = ""
    @State var modelProviderFilter = ""
    @State var modelTierFilter = PricingTier.unknown
    var availableModelOrgs: [String] {
        let orgs = vm.modelSelectionRows.compactMap { row -> String? in
            let slash = row.id.firstIndex(of: "/")
            guard let slash else { return nil }
            return String(row.id[..<slash])
        }
        return Array(Set(orgs)).sorted()
    }

    var filteredModelRows: [ProviderManager.ModelSelectionRow] {
        var rows = vm.modelSelectionRows
        if !modelProviderFilter.isEmpty {
            rows = rows.filter { $0.id.hasPrefix(modelProviderFilter + "/") || $0.isDefault }
        }
        if modelTierFilter != .unknown {
            rows = rows.filter { ($0.model?.pricingTier ?? .unknown) == modelTierFilter || $0.isDefault }
        }
        if !modelSearchText.isEmpty {
            let q = modelSearchText.lowercased()
            rows = rows.filter { $0.id.lowercased().contains(q) || $0.isDefault }
        }
        return rows
    }

    var allFilteredModelsSelected: Bool {
        let rows = filteredModelRows
        return !rows.isEmpty && rows.allSatisfy { vm.isModelSelected($0.id) }
    }

    var isFiltering: Bool {
        !modelProviderFilter.isEmpty || !modelSearchText.isEmpty || modelTierFilter != .unknown
    }

    var liquidGlassAppearanceAvailable: Bool {
        if #available(macOS 26.0, *) {
            return true
        }
        return false
    }

    var effectiveLiquidGlassEnabled: Bool {
        liquidGlassAppearanceAvailable && vm.liquidGlassEnabled
    }

    var body: some View {
        Group {
            if usesNarrowStandaloneLayout {
                detailShell
                    .navigationTitle(selectedSection.title)
                    .toolbar {
                        settingsToolbar
                    }
            } else {
                splitSettingsBody
            }
        }
        .onAppear {
            if selectedSection == .home {
                let target = AppNavigationTarget.migrated(vm.defaultSettingsSection)
                selectedSection = target.section
                if let category = target.category { settingsCategory = category }
            }
            if ([SettingsSection.routing, .harnesses].contains(selectedSection) && !vm.repoGPSRoutingFeatureEnabled)
                || (selectedSection == .epiphyte && !vm.epiphyteFeatureEnabled) {
                selectedSection = .home
            }
            consumeSettingsRequest()
            vm.refreshStatus()
            vm.runPreflightChecks()
            vm.startLogUpdates()
            vm.maybeShowKeychainAccessPrimerOnLaunch()
            vm.maybeShowAnalyticsPrompt()
            vm.maybeShowHarnessOnboarding()
        }
        .onChange(of: vm.settingsRequested) { _, _ in consumeSettingsRequest() }
        .onChange(of: selectedSection) { _, section in
            let target = AppNavigationTarget.migrated(section)
            if target.section != section {
                if let category = target.category { settingsCategory = category }
                selectedSection = target.section
            }
        }
        .onDisappear {
            vm.stopLogUpdates()
        }
        .sheet(isPresented: Binding(
            get: { vm.showOnboardingWizard },
            set: { vm.showOnboardingWizard = $0 }
        )) {
            OnboardingWizardView(onGetStarted: {
                if vm.showsAgentModeChoice { vm.selectedAgentMode = .proxyPilotAgent }
                selectedSection = .proxy
            })
                .environmentObject(vm)
        }
        .sheet(isPresented: Binding(
            get: { vm.showKeychainAccessPrimer },
            set: { newValue in
                // Escape or a click outside would otherwise set the flag directly and
                // skip the chain that hands off to the next launch sheet.
                if !newValue && vm.showKeychainAccessPrimer {
                    vm.dismissKeychainAccessPrimer()
                } else {
                    vm.showKeychainAccessPrimer = newValue
                }
            }
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
        .sheet(isPresented: Binding(
            get: { vm.showHarnessOnboarding },
            set: { newValue in
                // A dismissal that did not go through a button is a skip, not a completion.
                if !newValue && vm.showHarnessOnboarding {
                    vm.finishHarnessOnboarding(completed: false)
                } else {
                    vm.showHarnessOnboarding = newValue
                }
            }
        )) {
            HarnessOnboardingView(onOpenHarnesses: { selectedSection = .harnesses })
                .environmentObject(vm)
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
        .confirmationDialog("Apply selection and restart?", isPresented: $confirmToolbarRestart) {
            Button("Apply & Restart", role: .destructive) { Task { await vm.restartProxy() } }
        } message: { Text("Requests using this proxy will be interrupted, including other clients.") }
        .frame(minWidth: 680, minHeight: 620)
        .background {
            WindowWidthReader { width in
                windowWidth = width
            }
        }
        .environment(\.proxypilotLiquidGlassEnabled, effectiveLiquidGlassEnabled)
    }

    /// Deliberately a window-bounded `HStack` and not a `NavigationSplitView`.
    ///
    /// Two earlier `NavigationSplitView` attempts coupled the sidebar's viewport to the
    /// selected detail page. On a tall Session History window, that pushed every row
    /// above the visible area. `backgroundExtensionEffect()` also mirrored detail cards
    /// and text into the navigation layer. This shell keeps both columns bounded by the
    /// window, puts one system-supported regular glass effect around the navigation
    /// surface, and extends only ProxyPilot's ambient background beneath it.
    ///
    /// Do not replace this with a split view or detail-derived background extension
    /// without first reproducing at the owner's ~1080x1920 portrait near-fullscreen
    /// Session History configuration; a short window hides the regression completely.
    var splitSettingsBody: some View {
        HStack(spacing: 0) {
            if !sidebarIsCollapsed {
                GeometryReader { geometry in
                    GlassNavigationSurface {
                        VStack(spacing: 0) {
                            Color.clear
                                .frame(height: max(geometry.safeAreaInsets.top, 52), alignment: .bottom)

                            SettingsSidebarView(
                                selection: $selectedSection,
                                sections: SettingsSection.availableSidebarSections(
                                    repoGPSRoutingEnabled: vm.repoGPSRoutingFeatureEnabled,
                                    epiphyteInstalled: vm.epiphyteFeatureEnabled
                                ),
                                versionText: appVersionText,
                                buildText: appBuildText,
                                showsNewFeaturesPill: vm.harnessOnboardingBadgeVisible,
                                onOpenNewFeatures: { vm.openHarnessOnboarding(surface: "sidebar_pill") }
                            )
                        }
                    }
                    .ignoresSafeArea(.container, edges: .top)
                }
                .frame(width: 238)
                .transition(.move(edge: .leading).combined(with: .opacity))
            }

            detailShell
                .navigationTitle("")
                .toolbar {
                    settingsToolbar
                }
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.18), value: sidebarIsCollapsed)
        .proxyPilotAmbientBackground()
        .proxyPilotTransparentWindowToolbar()
    }

    var usesNarrowStandaloneLayout: Bool {
        switch layoutModePreference {
        case .automatic:
            return windowWidth > 0 && windowWidth < 760
        case .sidebar:
            return false
        case .compact:
            return true
        }
    }

    var usesCollapsedTopNavigation: Bool {
        usesNarrowStandaloneLayout
    }

    var detailShell: some View {
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

            if usesCollapsedTopNavigation {
                Divider()
                AppVersionFooter(
                    versionText: appVersionText,
                    buildText: appBuildText,
                    showsNewFeaturesPill: vm.harnessOnboardingBadgeVisible,
                    onOpenNewFeatures: { vm.openHarnessOnboarding(surface: "compact_pill") }
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .proxyPilotAmbientBackground()
    }

    var collapsedSectionTabs: some View {
        // Measure the whole strip at its readable intrinsic size. Compressible
        // text would otherwise "fit" by truncating every destination name.
        ViewThatFits(in: .horizontal) {
            collapsedSectionTabRow(style: .text)
            collapsedSectionTabRow(style: .wrappedText)
            collapsedSectionTabRow(style: .icons)
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 16)
    }

    enum CollapsedTabLabelStyle {
        case text, wrappedText, icons
    }

    func collapsedSectionTabRow(style: CollapsedTabLabelStyle) -> some View {
        HStack(spacing: 14) {
            collapsedTabButton(for: .home, style: style)

            GlassControlGroup(cornerRadius: 24, padding: 4) {
                HStack(spacing: 0) {
                    ForEach(Array(availableCollapsedTabSections.dropFirst().enumerated()), id: \.element) { index, section in
                        if index > 0 {
                            Rectangle()
                                .fill(Color(nsColor: .separatorColor).opacity(0.45))
                                .frame(width: 1, height: 24)
                                .padding(.horizontal, 4)
                        }

                        collapsedTabButton(for: section, style: style)
                    }
                }
            }

            EmptyView()
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    var availableCollapsedTabSections: [SettingsSection] {
        SettingsSection.availableCollapsedTabSections(
            repoGPSRoutingEnabled: vm.repoGPSRoutingFeatureEnabled,
            epiphyteInstalled: vm.epiphyteFeatureEnabled
        )
    }

    func collapsedTabButton(for section: SettingsSection, style: CollapsedTabLabelStyle) -> some View {
        Button {
            selectedSection = section
        } label: {
            HStack(spacing: 6) {
                if section == .home || style == .icons {
                    Image(systemName: section.systemImage)
                }
                if section == .home || style != .icons {
                    Text(style == .wrappedText ? wrappedCompactTitle(for: section) : section.compactTitle)
                        .multilineTextAlignment(.center)
                        .fixedSize()
                }
            }
            .font(.callout.weight(selectedSection == section ? .semibold : .medium))
            .foregroundStyle(selectedSection == section ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .padding(.horizontal, section == .home ? 16 : 14)
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
        .help(section.title)
        .accessibilityLabel(section.title)
        .accessibilityAddTraits(selectedSection == section ? .isSelected : [])
    }

    func wrappedCompactTitle(for section: SettingsSection) -> String {
        switch section {
        case .proxy:
            return "Xcode\nSetup"
        case .keys:
            return "Keys &\nProviders"
        default:
            return section.compactTitle
        }
    }

    var collapsedCustomizationButton: some View {
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
    var detailContent: some View {
        switch selectedSection {
        case .home:
            HomeDashboardView(
                showInstallConfirmation: $showInstallConfirmation,
                onOpenKeys: { selectedSection = .keys },
                onOpenProxy: { selectedSection = .proxy },
                onOpenCaching: { focusProxySection(.cacheSignals) },
                onOpenAgentModel: { focusProxySection(.models) },
                onOpenManualAgentRegistration: { focusProxySection(.agentRegistration) },
                onOpenPreflight: {
                    selectedSection = .proxy
                    preflightExpanded = true
                    vm.runPreflightChecks()
                },
                onOpenSessionHistory: { selectedSection = .history },
                onOpenEpiphyte: { selectedSection = .epiphyte },
                onOpenRepoGPS: { selectedSection = .harnesses }
            )
            .environmentObject(vm)
        case .history:
            SessionHistoryView(
                prefersCompactLayout: usesCollapsedTopNavigation,
                onOpenAdvancedLogging: { openSettings(.privacy) }
            )
                .environmentObject(vm)
        case .epiphyte:
            EpiphyteSettingsView(onOpenModels: { selectedSection = .models }).environmentObject(vm)
        case .harnesses:
            CodingHarnessesView(onOpenHome: { selectedSection = .home }, onOpenModels: { selectedSection = .models })
                .environmentObject(vm)
        case .models:
            modelsTab
        case .proxy:
            proxyTab
        case .routing:
            CodingHarnessesView(onOpenHome: { selectedSection = .home }, onOpenModels: { selectedSection = .models })
        case .keys:
            modelsTab
        case .advanced, .customization:
            unifiedSettings
        }
    }

    @ToolbarContentBuilder
    var settingsToolbar: some ToolbarContent {
        if usesCollapsedTopNavigation {
            if #available(macOS 26.0, *) {
                ToolbarItem(placement: .navigation) {
                    ProxyPilotBrandMark()
                }
                .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .navigation) {
                    ProxyPilotBrandMark()
                }
            }

        } else {
            if sidebarIsCollapsed {
                ToolbarItem(placement: .navigation) {
                    Button {
                        toggleSidebar()
                    } label: {
                        Label("Show Sidebar", systemImage: "sidebar.left")
                    }
                    .labelStyle(.iconOnly)
                    .help("Show Sidebar")
                }
            } else {
                if #available(macOS 26.0, *) {
                    ToolbarItem(placement: .navigation) {
                        SidebarToolbarBrandHeader(onToggleSidebar: toggleSidebar)
                    }
                    .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .navigation) {
                        SidebarToolbarBrandHeader(onToggleSidebar: toggleSidebar)
                    }
                }
            }
        }

        ToolbarItemGroup(placement: .primaryAction) {
            if vm.shouldShowToolbarStatus {
                StatusToolbarLabel(
                    status: vm.toolbarProxyStatus,
                    usesCompactText: !usesNarrowStandaloneLayout
                )
            }

            if selectedSection != .home {
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
                confirmToolbarRestart = true
            } label: {
                Label("Apply & Restart", systemImage: "arrow.clockwise")
            }
            .disabled(!vm.canRestartProxy)
            .help("Apply the selected configuration and restart the proxy")
            }
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
            Menu {
                Picker("Layout", selection: $layoutModePreference) {
                    ForEach(LayoutModePreference.allCases) { mode in
                        Label(mode.title, systemImage: mode.systemImage).tag(mode)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Layout", systemImage: layoutModePreference.systemImage)
            }
            .help("Choose ProxyPilot's window layout")
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
                Button("Xcode Setup Guide") { vm.showOnboardingWizard = true }
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

    var appVersionText: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    var appBuildText: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }

    func toggleSidebar() {
        sidebarIsCollapsed.toggle()
    }

    var promptCachingModeColor: Color {
        switch vm.promptCachingMode {
        case .computeCacheHints:
            return vm.upstreamProvider == .google ? .orange : .green
        case .observeOnly, .explicitReferenceCache:
            return .secondary
        case .off:
            return .orange
        }
    }

    func focusProxySection(_ focus: ProxySectionFocus) {
        if focus == .cacheSignals {
            openSettings(.connection)
            return
        }
        if focus == .models {
            selectedSection = .models
            return
        }
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

    func applyPendingProxyFocus(with proxy: ScrollViewProxy) {
        guard selectedSection == .proxy,
              let focus = proxySectionFocus else { return }

        proxySectionFocus = nil
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.28)) {
                proxy.scrollTo(focus, anchor: .top)
            }
        }
    }

    var modelsTab: some View { ProviderWorkspaceView(compact: usesCollapsedTopNavigation) }

    // MARK: - Proxy Tab



    // MARK: - Keys Tab

    @State var showAddCustomProviderSheet = false

    // MARK: - Shared Xcode Agent routing blocks
    //
    // Both agent modes are routed by the same machinery: `selectedXcodeAgentModel` →
    // `effectiveXcodeAgentModel` → the proxy's `preferredAnthropicUpstreamModel` remap.
    // These blocks describe *that* shared state, so they render identically in Claude
    // Agent and ProxyPilot Agent mode. Only the install/registration mechanics differ,
    // and those stay in their own mode-specific sections.

    var agentXcodeInstallationsBlock: some View {
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
                        Text(xcode.supportsAgenticCoding ? "Supports agents" : "No Agent Support")
                            .font(.caption)
                            .foregroundStyle(xcode.supportsAgenticCoding ? .green : .secondary)
                    }
                }
            }
        }
    }

    var agentUpstreamModelBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            FavoriteModelPicker()

            Text(verbatim: vm.xcodeAgentRoutingSummaryText)
                .font(.caption2)
                .foregroundStyle(.secondary)

            Text(vm.xcodeAgentRouteScopeNote)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    var agentRouteStateBlock: some View {
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
            LabeledContent("Model availability") {
                Text(vm.xcodeAgentLiveRouteText)
                    .textSelection(.enabled)
            }
        }
        .font(.caption)
    }

    var agentLiveProofBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Last observed Xcode request")
                .font(.subheadline)
            Text(vm.xcodeAgentLiveProofText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    var agentVisibleModelsBlock: some View {
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
    }

    var agentRoutingVerificationBlock: some View {
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

    var keysTab: some View {
        Form {
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
                        if provider.secretKey != nil {
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
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showAddCustomProviderSheet) {
            AddCustomProviderView { name, url, key in
                vm.addCustomProvider(name: name, apiBaseURL: url, apiKey: key)
            }
        }
    }

    var orderedVisibleKeysProviders: [UpstreamProvider] {
        vm.keysProviderOrder
            .map(\.provider)
            .filter { vm.isKeysProviderVisible($0) }
    }

    @ViewBuilder
    func customProviderKeyRow(_ provider: CustomProvider) -> some View {
        let hasKey = vm.customProviderHasKey(provider)
        let isActive = vm.isCustomProviderActive(provider)

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
                if isActive {
                    Text("Active")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                }
            }

            HStack(spacing: 12) {
                Button(isActive ? "Active Upstream" : "Use as Upstream") {
                    vm.activateCustomProvider(provider)
                }
                .disabled(isActive)
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
    func localProviderSetupRow(_ provider: UpstreamProvider) -> some View {
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
    func providerKeyRow(_ provider: UpstreamProvider) -> some View {
        let hasKey = vm.hasKey(for: provider)
        let isEditing = vm.providerKeyEditing[provider] ?? false
        let testState = vm.providerKeyTestStates[provider] ?? .idle

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                HStack(spacing: 6) {
                    Text(provider.title)
                        .font(.subheadline.bold())
                    providerBadges(for: provider)
                }
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
                    let isSelectedProvider = vm.isSelectedBuiltInProvider(provider)
                    Text(!provider.requiresAPIKey ? "API key optional" : (isSelectedProvider ? "Missing key" : "Not configured"))
                        .font(.caption)
                        .foregroundStyle(isSelectedProvider && provider.requiresAPIKey ? .orange : .secondary)
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
                    if let url = vm.apiKeyPageURL(for: provider) {
                        Button("Get Key") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    Spacer()
                }
                if let regionHint = vm.apiKeyRegionHint(for: provider) {
                    Text(regionHint)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if hasKey {
                    if let cliStatusText = vm.providerCLIAuthStatusText(for: provider) {
                        Text(cliStatusText)
                            .font(.caption2)
                            .foregroundStyle(vm.providerCLIAuthStatusIsWarning(for: provider) ? .orange : .secondary)
                            .textSelection(.enabled)
                    }
                    providerKeyTestStatusView(testState)
                    if vm.isSelectedBuiltInProvider(provider) {
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
    func providerBadges(for provider: UpstreamProvider) -> some View {
        if provider == .qwen {
            providerBadge("New", foreground: .blue, background: .blue.opacity(0.14))
            providerBadge("Beta", foreground: .orange, background: .orange.opacity(0.16))
        } else if provider == .nineRouter {
            providerBadge("New", foreground: .blue, background: .blue.opacity(0.14))
        }
    }

    func providerBadge(_ title: String, foreground: Color, background: Color) -> some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(background, in: Capsule())
            .foregroundStyle(foreground)
    }

    @ViewBuilder
    func providerKeyTestStatusView(_ state: AppViewModel.KeyTestState) -> some View {
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



    // MARK: - Helpers

    func preflightRow(_ result: PreflightCheckResult) -> some View {
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

    func symbolForPreflightStatus(_ status: PreflightCheckStatus) -> String {
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

    func colorForPreflightStatus(_ status: PreflightCheckStatus) -> Color {
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

    func preflightFixActionTitle(_ action: PreflightFixAction) -> String {
        "Fix"
    }

    func checklistRow(_ title: String, isOn: Bool) -> some View {
        HStack {
            Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isOn ? .green : .secondary)
            Text(title)
            Spacer()
        }
        .font(.subheadline)
    }

    func handlePreflightFixAction(_ action: PreflightFixAction) {
        switch action {
        case .openUpstreamKeyEditor:
            vm.providerWorkspaceShowsConfiguration = true
            selectedSection = .keys
            if vm.hasSelectedProvider && !vm.hasActiveCustomProvider && vm.upstreamProvider.requiresAPIKey {
                vm.providerKeyEditing[vm.upstreamProvider] = true
                vm.providerKeyDrafts[vm.upstreamProvider] = nil
            }
        case .openMasterKeyEditor:
            openSettings(.connection)
            vm.showingMasterKeyField = true
        default:
            vm.applyPreflightFixAction(action)
        }
    }

    @ViewBuilder
    func modelFilterBar() -> some View {
        let orgs = availableModelOrgs
        let hasOrgs = orgs.count > 1
        let hasTiers = vm.modelSelectionRows.contains { ($0.model?.pricingTier ?? .unknown) != .unknown }
        if hasOrgs || hasTiers {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                            .font(.caption2)
                        TextField("Filter models", text: $modelSearchText)
                            .textFieldStyle(.plain)
                            .font(.caption)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.1)))

                    if hasOrgs {
                        Picker("Provider", selection: $modelProviderFilter) {
                            Text("All Providers").tag("")
                            ForEach(orgs, id: \.self) { org in
                                Text(org).tag(org)
                            }
                        }
                        .pickerStyle(.menu)
                        .font(.caption)
                        .labelsHidden()
                    }

                    if hasTiers {
                        Picker("Tier", selection: $modelTierFilter) {
                            Text("All Tiers").tag(PricingTier.unknown)
                            Text("Free").tag(PricingTier.free)
                            Text("Budget ($)").tag(PricingTier.budget)
                            Text("Standard ($$)").tag(PricingTier.standard)
                            Text("Premium ($$$)").tag(PricingTier.premium)
                        }
                        .pickerStyle(.menu)
                        .font(.caption)
                        .labelsHidden()
                    }

                    if isFiltering {
                        Button("Clear") {
                            modelSearchText = ""
                            modelProviderFilter = ""
                            modelTierFilter = .unknown
                        }
                        .font(.caption)
                        Spacer()
                        Text("\(filteredModelRows.count) of \(vm.modelSelectionRows.count)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        Spacer()
                    }
                }
            }
        }
    }

    func modelSelectionRowLabel(_ row: ProviderManager.ModelSelectionRow) -> some View {
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
    func modelMetadataView(_ model: UpstreamModel, estimatedCostPerRequest: Double?) -> some View {
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

    var routingVerificationCommands: String {
        let preferredPattern = ShellArgumentEscaper.singleQuote("preferred=\(vm.effectiveXcodeAgentModel)")
        return """
        tail -f /tmp/proxypilot_builtin_proxy.log

        rg -n -F -- 'anthropic model remap' /tmp/proxypilot_builtin_proxy.log | tail -n 8

        rg -n -F -- \(preferredPattern) /tmp/proxypilot_builtin_proxy.log | tail -n 3
        """
    }

    func copyRoutingVerificationCommands() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(routingVerificationCommands, forType: .string)
        routingVerificationCopied = true
    }

    func keyRow(
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

extension View {
    func proxyFocusGlow(isActive: Bool, color: Color) -> some View {
        modifier(ProxyFocusGlowModifier(isActive: isActive, glowColor: color))
    }
}

struct ProxyFocusGlowModifier: ViewModifier {
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

struct SidebarToolbarBrandHeader: View {
    let onToggleSidebar: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            ProxyPilotBrandMark()
            Spacer(minLength: 0)

            Button(action: onToggleSidebar) {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .help("Hide Sidebar")
            .accessibilityLabel("Hide Sidebar")
        }
        // The sidebar's own GlassNavigationSurface already extends through the
        // titlebar. Keep this as content only: a second finite glass surface
        // creates a visible bottom halo where the two layers overlap.
        .frame(width: 135)
    }
}

struct StatusToolbarLabel: View {
    let status: AppViewModel.ToolbarProxyStatus
    let usesCompactText: Bool

    var tint: Color {
        switch status.kind {
        case .gui:
            return .green
        case .cli:
            return .blue
        case .epiphyte, .independentClients:
            return .green
        case .repoGPS:
            return .cyan
        case .issue:
            return .orange
        case .stopped:
            return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(tint)
                .frame(width: 7, height: 7)

            Text(usesCompactText ? status.compactText : status.fullText)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, usesCompactText ? 7 : 10)
        .padding(.vertical, 4)
        .frame(maxWidth: 190, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Proxy status \(status.fullText)")
        .help("Proxy status: \(status.fullText)")
    }
}

struct WindowWidthReader: NSViewRepresentable {
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

struct KeychainAccessPrimerView: View {
    @EnvironmentObject var vm: AppViewModel

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

struct AnalyticsOptInView: View {
    var onEnable: () -> Void
    var onDisable: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Please consider sharing basic, anonymous analytics.")
                .font(.title3.bold())

            Text("By default, ProxyPilot reports only app-open, version, and build health. If you enable optional analytics, it also shares which providers and client surfaces are used; bucketed request, token, latency, streaming, and cache summaries; feature modes; setup progress; and normalized failures. Prompts, completions, API keys, URLs, raw errors, repository names, device identifiers, and specific model names are never sent. You can change this any time in Settings → Privacy & Logging.")
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

struct OnboardingWizardView: View {
    @EnvironmentObject var vm: AppViewModel
    let onGetStarted: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Welcome to ProxyPilot")
                .font(.title2.bold())

            Text("Use your preferred cloud or local model in Xcode. Set up ProxyPilot Agent once, then use ProxyPilot to choose the model for your conversation.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                Label("1. Choose a provider. Add its API key, or use a local model.", systemImage: "key")
                Label("2. Choose a model and set up the Xcode agent.", systemImage: "hammer")
                Label("3. Open a conversation in Xcode. Review usage on Home.", systemImage: "chart.bar")
            }
            .font(.callout)
            Text("Terminal features are optional. RepoGPS is available in the sidebar whenever you want it.")
                .font(.caption).foregroundStyle(.secondary)

            Toggle("Share anonymous diagnostics telemetry (optional)", isOn: Binding(
                get: { vm.telemetryOptIn },
                set: { vm.setTelemetryOptIn($0, surface: "onboarding") }
            ))
            .toggleStyle(.switch)

            Spacer()

            HStack {
                Button("Open README") {
                    vm.openReadme()
                }

                Spacer()

                Button("Set Up Xcode") {
                    vm.finishOnboarding(force: true)
                    onGetStarted()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 540, height: 390)
    }
}

extension PromptCachingMode {
    var displayTitle: String {
        switch self {
        case .computeCacheHints:
            return "Auto"
        case .observeOnly:
            return "Observe Only"
        case .off:
            return "Off"
        case .explicitReferenceCache:
            return "Reference Cache"
        }
    }
}
