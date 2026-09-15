import AppKit
import ProxyPilotCore
import SwiftUI
import UniformTypeIdentifiers

struct HomeDashboardView: View {
    @EnvironmentObject private var vm: AppViewModel
    @Binding var showInstallConfirmation: Bool

    let onOpenKeys: () -> Void
    let onOpenProxy: () -> Void
    let onOpenCaching: () -> Void
    let onOpenAgentModel: () -> Void
    let onOpenManualAgentRegistration: () -> Void
    let onOpenPreflight: () -> Void
    let onOpenSessionHistory: () -> Void

    @State private var sessionCSVExportStatus: String = ""
    @State private var expandedSessionRequestIDs: Set<UUID> = []
    @State private var copiedSessionRequestID: UUID?
    @State private var showResetSessionConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if vm.repoGPS.session.active && vm.repoGPS.session.lease != nil {
                    repoGPSCockpit
                }
                if visibleHomeSections.isEmpty && !vm.repoGPS.session.active {
                    hiddenHomeSectionsPlaceholder
                } else {
                    if vm.isHomeDashboardSectionVisible(.sessionSummary) {
                        heroCard
                    }
                    if vm.isHomeDashboardSectionVisible(.workflowControls) {
                        workflowControls
                    }
                    if vm.isHomeDashboardSectionVisible(.xcodeAgentRouting) {
                        xcodeAgentControls
                    }
                    if vm.isHomeDashboardSectionVisible(.sessionReportCard) {
                        sessionDetails
                    }
                }
            }
            .padding(24)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
        }
        .alert("Reset current session metrics?", isPresented: $showResetSessionConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Reset Metrics", role: .destructive) {
                resetCurrentSessionMetrics()
            }
        } message: {
            Text("This clears the current dashboard metrics and temporarily excludes already imported CLI session records until ProxyPilot relaunches. Source logs and Session History are not deleted.")
        }
    }

    private var visibleHomeSections: Set<HomeDashboardSection> {
        vm.visibleHomeDashboardSections
    }

    private var repoGPSCockpit: some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 14) {
                ViewThatFits {
                    HStack(alignment: .top, spacing: 12) {
                        repoGPSCockpitTitle
                        Spacer()
                        repoGPSActivityBadge
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        repoGPSCockpitTitle
                        repoGPSActivityBadge
                    }
                }

                ViewThatFits {
                    HStack(spacing: 12) {
                        repoGPSMetric("Mode", vm.repoGPS.session.lease?.mode.capitalized ?? "Normal")
                        repoGPSMetric("Activity", vm.repoGPS.session.lease?.activity.replacingOccurrences(of: "_", with: " ").capitalized ?? "Active")
                        repoGPSMetric("Pending Signals", "\(vm.repoGPS.session.pendingSignals)")
                        repoGPSMetric("Route", vm.routeControl.status.model ?? "Checking")
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], spacing: 12) {
                        repoGPSMetric("Mode", vm.repoGPS.session.lease?.mode.capitalized ?? "Normal")
                        repoGPSMetric("Activity", vm.repoGPS.session.lease?.activity.replacingOccurrences(of: "_", with: " ").capitalized ?? "Active")
                        repoGPSMetric("Pending Signals", "\(vm.repoGPS.session.pendingSignals)")
                        repoGPSMetric("Route", vm.routeControl.status.model ?? "Checking")
                    }
                }

                if vm.repoGPS.session.active {
                    ViewThatFits {
                        HStack(spacing: 8) {
                            repoGPSControlButtons
                            Spacer()
                            repoGPSControlExplanation
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            ViewThatFits {
                                HStack(spacing: 8) { repoGPSControlButtons }
                                VStack(alignment: .leading, spacing: 8) { repoGPSControlButtons }
                            }
                            repoGPSControlExplanation
                        }
                    }
                } else {
                    Text("The terminal session has ended. Its ProxyPilot CLI route is still available for the next RepoGPS flight.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.cyan.opacity(0.35), lineWidth: 1)
        }
    }

    private var repoGPSCockpitTitle: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(
                vm.repoGPS.session.active ? "RepoGPS In Flight" : "RepoGPS Last Flight",
                systemImage: vm.repoGPS.session.active ? "location.north.circle.fill" : "location.north.circle"
            )
                .font(.title3.weight(.semibold))
                .foregroundStyle(.cyan)
            Text(vm.repoGPS.session.lease?.repository ?? "Active terminal session")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private var repoGPSActivityBadge: some View {
        statusBadge(
            title: vm.repoGPS.session.active
                ? (vm.repoGPS.session.lease?.activity ?? "active").replacingOccurrences(of: "_", with: " ").capitalized
                : "Landed",
            systemImage: vm.repoGPS.session.active ? "waveform.path.ecg" : "checkmark.circle",
            color: .cyan
        )
    }

    @ViewBuilder
    private var repoGPSControlButtons: some View {
        Button("Retrace") { Task { await vm.repoGPS.signal("retrace") } }
        Button("Write Waypoint") { Task { await vm.repoGPS.signal("waypoint") } }
        Button("Prepare Landing") { Task { await vm.repoGPS.signal("prepare-landing") } }
    }

    private var repoGPSControlExplanation: some View {
        Text("Controls are delivered to the RepoGPS TUI when it is ready.")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func repoGPSMetric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
            Text(value).font(.callout.weight(.medium)).lineLimit(1)
        }
        .padding(10)
        .frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
        .background(Color.cyan.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var heroCard: some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 16) {
                ViewThatFits {
                    HStack(alignment: .top, spacing: 12) {
                        heroTitle
                        Spacer()
                        currentSessionStatusBadge
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        heroTitle
                        currentSessionStatusBadge
                    }
                }

                ViewThatFits {
                    HStack(spacing: 12) {
                        heroMetric("Completed Requests", "\(vm.sessionReportCard.totalRequests)", systemImage: "arrow.left.arrow.right") {
                            requestStatusDetail
                        }
                        heroMetric(
                            "Tokens",
                            sessionTokenMetricValue,
                            systemImage: "number"
                        ) {
                            tokenDirectionDetail
                        }
                        heroMetric(vm.sessionCacheMetricLabel, vm.sessionCacheMetricValue, systemImage: "bolt.horizontal")
                        heroMetric(vm.sessionCostMetricLabel, vm.formatUSD(vm.sessionEstimatedCostUSD), systemImage: "dollarsign.circle")
                        heroMetric("Latency", sessionLatencyText, systemImage: "timer")
                    }

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], spacing: 12) {
                        heroMetric("Completed Requests", "\(vm.sessionReportCard.totalRequests)", systemImage: "arrow.left.arrow.right") {
                            requestStatusDetail
                        }
                        heroMetric(
                            "Tokens",
                            sessionTokenMetricValue,
                            systemImage: "number"
                        ) {
                            tokenDirectionDetail
                        }
                        heroMetric(vm.sessionCacheMetricLabel, vm.sessionCacheMetricValue, systemImage: "bolt.horizontal")
                        heroMetric(vm.sessionCostMetricLabel, vm.formatUSD(vm.sessionEstimatedCostUSD), systemImage: "dollarsign.circle")
                        heroMetric("Latency", sessionLatencyText, systemImage: "timer")
                    }
                }

                ViewThatFits {
                    HStack(spacing: 10) {
                        upstreamProviderBadge
                        cacheStatusBadge
                        agentModelStatusBadge
                        preflightStatusBadge
                        Spacer()
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        upstreamProviderBadge
                        cacheStatusBadge
                        agentModelStatusBadge
                        preflightStatusBadge
                    }
                }

                if let issue = vm.activeIssue {
                    Text("\(issue.code.rawValue): \(issue.title)")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if let lastError = vm.lastError, !lastError.isEmpty {
                    Text(lastError)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private var heroTitle: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Proxy Activity")
                .font(.title2.weight(.semibold))
            Text(vm.isRunning ? "Usage across clients using this proxy. Session History shows individual sessions." : "Start ProxyPilot when you begin coding.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var currentSessionStatusBadge: some View {
        statusBadge(
            title: vm.isRunning ? "Running" : "Stopped",
            systemImage: vm.isRunning ? "checkmark.circle.fill" : "circle.fill",
            color: vm.isRunning ? .green : .secondary
        )
    }

    /// Names the route that produced the metrics beside it.
    ///
    /// While something is serving this is the serving route — which is the CLI's
    /// `route.json` whenever a CLI daemon owns the proxy, not the GUI's Xcode
    /// selection. With nothing serving there is no live route to name, so it
    /// falls back to the configured provider, which is unambiguous precisely
    /// because a stopped proxy is serving no one.
    private var upstreamProviderBadge: some View {
        Group {
            if let serving = vm.servingRouteBadgeTitle {
                statusBadge(
                    title: serving,
                    systemImage: "bolt.horizontal.circle",
                    color: .accentColor
                )
            } else {
                statusBadge(
                    title: vm.upstreamProviderDisplayTitle,
                    systemImage: "network",
                    color: .accentColor
                )
            }
        }
        .help(vm.servingRouteBadgeHelpText)
    }

    private var workflowControls: some View {
        ViewThatFits {
            HStack(spacing: 12) {
                proxyActionGroup
                workflowUtilityGroup
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 10) {
                proxyActionGroup
                workflowUtilityGroup
            }
        }
    }

    private var proxyActionGroup: some View {
        compactControlGroup {
            HStack(spacing: 2) {
                controlStripButton("Start", systemImage: "play.fill", isDisabled: !vm.canStartProxy) {
                    Task { await vm.startProxy() }
                }
                controlStripDivider
                controlStripButton("Stop", systemImage: "stop.fill", isDisabled: !vm.canStopProxy, role: .destructive) {
                    Task { await vm.stopProxy() }
                }
                controlStripDivider
                controlStripButton("Restart", systemImage: "arrow.clockwise", isDisabled: !vm.canRestartProxy) {
                    Task { await vm.restartProxy() }
                }
            }
        }
    }

    private var workflowUtilityGroup: some View {
        compactControlGroup {
            HStack(spacing: 2) {
                controlStripButton("Refresh", systemImage: "arrow.triangle.2.circlepath") {
                    vm.refreshStatus()
                }
                .help(AppViewModel.refreshProxyStatusHelpText)
                controlStripDivider
                controlStripButton("Keys", systemImage: "key") {
                    onOpenKeys()
                }
            }
        }
    }

    private var xcodeAgentControls: some View {
        Group {
            if vm.showsAgentModeChoice && vm.selectedAgentMode == .proxyPilotAgent {
                proxyPilotAgentControls
            } else {
                xcodeClaudeAgentControls
            }
        }
    }

    private var proxyPilotAgentControls: some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("ProxyPilot Agent")
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer()
                    Text(vm.agentRuntimeStatus.isReady ? "Ready" : "Not Installed")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(vm.agentRuntimeStatus.isReady ? .green : .secondary)
                }

                Text("Select ProxyPilot in Xcode’s agent picker, then choose your provider and model here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(vm.proxyPilotAgentStatusText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                ViewThatFits {
                    HStack(spacing: 12) {
                        agentModelPicker
                        Spacer()
                        proxyPilotAgentButtonGroup
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        agentModelPicker
                        proxyPilotAgentButtonGroup
                    }
                }

                // Same proxy-side route state the Claude Agent card shows — both modes
                // are remapped by the same running proxy, so this is not mode-specific.
                VStack(alignment: .leading, spacing: 4) {
                    Text("Xcode route: \(vm.xcodeAgentAppliedModelText)")
                    Text("Live: \(vm.xcodeAgentLiveRouteText)")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

                if vm.proxyPilotAgentUsesManualRegistration && vm.proxyPilotAgentRegistrationStatus?.isRegistered != true {
                    Button(action: onOpenManualAgentRegistration) {
                        Label("Show manual registration steps", systemImage: "list.bullet.rectangle")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityHint("Opens the exact Xcode agent registration values in Proxy settings.")
                } else {
                    proxySetupButton
                }
            }
        }
    }

    private var proxyPilotAgentButtonGroup: some View {
        compactControlGroup {
            HStack(spacing: 2) {
                controlStripButton(
                    vm.isInstallingProxyPilotAgent ? "Installing..." : "Install or Repair",
                    systemImage: "arrow.down.doc",
                    isDisabled: vm.isInstallingProxyPilotAgent
                ) {
                    Task { await vm.installProxyPilotAgent() }
                }
                controlStripDivider
                controlStripButton("Remove", systemImage: "trash", isDisabled: vm.isInstallingProxyPilotAgent, role: .destructive) {
                    Task { await vm.removeProxyPilotAgent() }
                }
                controlStripDivider
                controlStripButton("Refresh", systemImage: "arrow.triangle.2.circlepath", isDisabled: vm.isInstallingProxyPilotAgent) {
                    Task { await vm.refreshProxyPilotAgentState() }
                }
            }
        }
    }

    private var xcodeClaudeAgentControls: some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 12) {
                ViewThatFits {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Xcode Claude Agent Routing")
                            .font(.headline)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer()
                        agentConfigInstallStatusText
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Xcode Claude Agent Routing")
                            .font(.headline)
                            .fixedSize(horizontal: false, vertical: true)
                        agentConfigInstallStatusText
                    }
                }

                Text("Routes Xcode Claude Agent requests through ProxyPilot. Selected changes apply after proxy start or restart.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ViewThatFits {
                    HStack(spacing: 12) {
                        agentModelPicker
                        Spacer()
                        agentConfigButtonGroup
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        agentModelPicker
                        agentConfigButtonGroup
                    }
                }

                if !vm.agentConfigStatus.isEmpty {
                    Text(vm.agentConfigStatus)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Xcode route: \(vm.xcodeAgentAppliedModelText)")
                    Text("Live: \(vm.xcodeAgentLiveRouteText)")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

                proxySetupButton
            }
        }
    }

    private var proxySetupButton: some View {
        Button(action: onOpenProxy) {
            Label("Open Xcode Setup", systemImage: "arrow.right.circle")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityHint("Opens Xcode agent setup, model selection, and connection checks.")
    }

    private var agentConfigInstallStatusText: some View {
        Text(vm.agentConfigInstalled ? "Installed" : "Not Installed")
            .font(.caption.weight(.semibold))
            .foregroundStyle(vm.agentConfigInstalled ? .green : .secondary)
    }

    private var agentModelPicker: some View {
        Group {
            if vm.xcodeAgentModelCandidates.isEmpty {
                Text("Fetch or save models before selecting an agent model.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Picker("Agent Model", selection: Binding(
                    get: { vm.selectedXcodeAgentModel },
                    set: { vm.selectedXcodeAgentModel = $0 }
                )) {
                    ForEach(vm.xcodeAgentModelCandidates, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 360)
            }
        }
    }

    private var agentConfigButtons: some View {
        HStack(spacing: 2) {
            controlStripButton(vm.agentConfigInstalled ? "Reinstall" : "Install", systemImage: "arrow.down.doc", isDisabled: !vm.hasCompatibleXcode) {
                showInstallConfirmation = true
            }

            if vm.agentConfigInstalled {
                controlStripDivider
                controlStripButton("Remove", systemImage: "trash", role: .destructive) {
                    vm.removeXcodeAgentConfig()
                }
            }
        }
    }

    private var agentConfigButtonGroup: some View {
        compactControlGroup {
            agentConfigButtons
        }
    }

    private func compactControlGroup<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        GlassControlGroup(cornerRadius: 14, padding: 3) {
            content()
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func controlStripButton(
        _ title: String,
        systemImage: String,
        isDisabled: Bool = false,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.titleAndIcon)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(controlStripForeground(isDisabled: isDisabled, role: role))
        .disabled(isDisabled)
    }

    private var controlStripDivider: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor).opacity(0.5))
            .frame(width: 1, height: 20)
            .padding(.horizontal, 2)
    }

    private func controlStripForeground(isDisabled: Bool, role: ButtonRole?) -> AnyShapeStyle {
        if isDisabled {
            return AnyShapeStyle(.tertiary)
        }

        if role == .destructive {
            return AnyShapeStyle(Color.red)
        }

        return AnyShapeStyle(.primary)
    }

    private var sessionDetails: some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 12) {
                ViewThatFits {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("Session Report Card")
                            .font(.headline)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer()
                        sessionReportActions
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Session Report Card")
                            .font(.headline)
                        sessionReportActions
                    }
                }

                if vm.sessionReportCard.totalRequests == 0 {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Start the proxy and send your first request to populate this report.")
                        Text("You will see model, token, latency, cost, and recent request breakdowns here.")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    sessionMetricGrid

                    if !vm.sessionCostCoverageText.isEmpty {
                        Text(vm.sessionCostCoverageText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Text(vm.sessionCacheTelemetryText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    if !vm.sessionModelLatencyBreakdown.isEmpty {
                        Divider()
                        perModelLatency
                    }

                    if !vm.sessionReportCard.modelDistribution.isEmpty {
                        Divider()
                        modelDistribution
                    }

                    Divider()
                    recentRequests
                }

                if !sessionCSVExportStatus.isEmpty {
                    Text(sessionCSVExportStatus)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var sessionReportActions: some View {
        HStack(spacing: 8) {
            Button("Export CSV") {
                exportSessionRequestsCSV()
            }
            Button("View History") {
                onOpenSessionHistory()
            }
            Button("Reset", role: .destructive) {
                showResetSessionConfirmation = true
            }
        }
        .font(.caption)
    }

    private func resetCurrentSessionMetrics() {
        vm.resetSessionStats()
        sessionCSVExportStatus = ""
        expandedSessionRequestIDs.removeAll()
        copiedSessionRequestID = nil
    }

    private var hiddenHomeSectionsPlaceholder: some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("Home dashboard hidden")
                    .font(.headline)
                Text("All Home sections are currently hidden. Re-enable sections in Customization to restore this dashboard.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var sessionMetricGrid: some View {
        ViewThatFits {
            HStack(spacing: 18) {
                smallMetric("Prompt", sessionReportTokenValue(vm.sessionReportCard.totalPromptTokens))
                smallMetric("Completion", sessionReportTokenValue(vm.sessionReportCard.totalCompletionTokens))
                smallMetric("Total", sessionTokenMetricValue)
                smallMetric(vm.sessionCacheMetricLabel, vm.sessionCacheMetricValue)
                smallMetric(vm.sessionCostMetricLabel, vm.formatUSD(vm.sessionEstimatedCostUSD))
                if let latency = vm.sessionLatencySummary {
                    smallMetric("P95", formatLatency(latency.p95))
                }
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 12)], alignment: .leading, spacing: 12) {
                smallMetric("Prompt", sessionReportTokenValue(vm.sessionReportCard.totalPromptTokens))
                smallMetric("Completion", sessionReportTokenValue(vm.sessionReportCard.totalCompletionTokens))
                smallMetric("Total", sessionTokenMetricValue)
                smallMetric(vm.sessionCacheMetricLabel, vm.sessionCacheMetricValue)
                smallMetric(vm.sessionCostMetricLabel, vm.formatUSD(vm.sessionEstimatedCostUSD))
                if let latency = vm.sessionLatencySummary {
                    smallMetric("P95", formatLatency(latency.p95))
                }
            }
        }
    }

    private var perModelLatency: some View {
        VStack(alignment: .leading, spacing: 8) {
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
    }

    private var modelDistribution: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Model Distribution")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(vm.sessionReportCard.modelDistribution, id: \.model) { entry in
                HStack {
                    Text(entry.model)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text("\(entry.count) req")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var recentRequests: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent Requests")
                .font(.caption)
                .foregroundStyle(.secondary)

            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(Array(vm.sessionReportCard.requests.suffix(40).reversed())) { request in
                        DisclosureGroup(
                            isExpanded: sessionRequestDisclosureBinding(for: request.id)
                        ) {
                            VStack(alignment: .leading, spacing: 4) {
                                requestDetailRow(label: "Path", value: request.path)
                                requestDetailRow(label: "Streaming", value: request.wasStreaming ? "Yes" : "No")
                                requestDetailRow(label: "Prompt", value: sessionRequestTokenValue(request.promptTokens, request: request))
                                requestDetailRow(label: "Completion", value: sessionRequestTokenValue(request.completionTokens, request: request))
                                requestDetailRow(label: "Total", value: sessionRequestTotalValue(request))
                                if let hit = request.promptCacheHitTokens {
                                    requestDetailRow(label: "Cached", value: "\(hit)")
                                }
                                if let miss = request.promptCacheMissTokens {
                                    requestDetailRow(label: "Uncached", value: "\(miss)")
                                }
                                if let write = request.promptCacheWriteTokens {
                                    requestDetailRow(label: "Cache write", value: "\(write)")
                                }
                                requestDetailRow(label: "Latency", value: formatLatency(request.durationSeconds))
                                requestDetailRow(label: vm.sessionRequestCostLabel, value: vm.formatUSD(vm.estimatedCostUSD(for: request)))

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
                                    Text(sessionRequestInlineTokenSummary(request))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    if let hit = request.promptCacheHitTokens, hit > 0 {
                                        Text("\(formatCompactInteger(hit)) cached")
                                            .font(.caption2)
                                            .foregroundStyle(.green)
                                    }
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
    }

    private var sessionLatencyText: String {
        guard let latency = vm.sessionLatencySummary else { return "No data" }
        return "p95 \(formatLatency(latency.p95))"
    }

    private var tokenDirectionDetail: some View {
        HStack(spacing: 7) {
            if vm.sessionReportCard.tokenAccountingAvailable {
                tokenDirectionValue(
                    systemImage: "arrow.up",
                    value: formatCompactInteger(vm.sessionReportCard.totalPromptTokens),
                    help: "Prompt tokens"
                )
                tokenDirectionValue(
                    systemImage: "arrow.down",
                    value: formatCompactInteger(vm.sessionReportCard.totalCompletionTokens),
                    help: "Completion tokens"
                )
            } else if vm.sessionReportCard.totalRequests > 0 {
                Text("Provider did not return token usage")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .foregroundStyle(.secondary)
    }

    private var sessionTokenMetricValue: String {
        if vm.sessionReportCard.tokenAccountingAvailable {
            return vm.sessionReportCard.totalTokensFormatted
        }
        return vm.sessionReportCard.totalRequests > 0 ? "Unavailable" : "0"
    }

    private func sessionReportTokenValue(_ value: Int) -> String {
        vm.sessionReportCard.tokenAccountingAvailable ? "\(value)" : (vm.sessionReportCard.totalRequests > 0 ? "Unavailable" : "0")
    }

    private func sessionRequestHasTokenTelemetry(_ request: SessionReportCard.RequestRecord) -> Bool {
        request.hasTokenTelemetry
    }

    private func sessionRequestTokenValue(_ value: Int, request: SessionReportCard.RequestRecord) -> String {
        sessionRequestHasTokenTelemetry(request) ? "\(value)" : "Unavailable"
    }

    private func sessionRequestTotalValue(_ request: SessionReportCard.RequestRecord) -> String {
        sessionRequestHasTokenTelemetry(request) ? "\(request.totalTokens)" : "Unavailable"
    }

    private func sessionRequestInlineTokenSummary(_ request: SessionReportCard.RequestRecord) -> String {
        sessionRequestHasTokenTelemetry(request) ? "\(request.totalTokens) tok" : "token usage unavailable"
    }

    private var requestStatusDetail: some View {
        HStack(spacing: 7) {
            tokenDirectionValue(
                systemImage: "hourglass",
                value: formatCompactInteger(vm.localProxyState.pendingRequestCount),
                help: "Requests still running or waiting for a final response"
            )
            tokenDirectionValue(
                systemImage: "exclamationmark.triangle",
                value: formatCompactInteger(vm.localProxyState.failedRequestCount),
                help: "Requests that ended without a completed session record"
            )
        }
        .foregroundStyle(.secondary)
    }

    private var preflightSummary: String {
        if vm.preflightResults.isEmpty { return "Preflight not checked" }
        if vm.preflightHasBlockingFailures { return "Preflight needs attention" }
        return vm.isRunning ? "Preflight passed" : "Ready to start"
    }

    private func heroMetric<Detail: View>(
        _ label: String,
        _ value: String,
        systemImage: String,
        @ViewBuilder detail: () -> Detail
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            detail()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(minWidth: 140, maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func heroMetric(_ label: String, _ value: String, systemImage: String) -> some View {
        heroMetric(label, value, systemImage: systemImage) {
            EmptyView()
        }
    }

    private func tokenDirectionValue(systemImage: String, value: String, help: String) -> some View {
        HStack(spacing: 2) {
            Image(systemName: systemImage)
                .font(.system(size: 8, weight: .bold))
            Text(value)
                .font(.system(.caption2, design: .monospaced).weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .help(help)
    }

    private func smallMetric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.caption, design: .monospaced))
        }
    }

    private func statusBadge(title: String, systemImage: String, color: Color) -> some View {
        statusBadgeLabel(title: title, systemImage: systemImage, color: color)
    }

    private var preflightStatusBadge: some View {
        Button {
            onOpenPreflight()
        } label: {
            statusBadgeLabel(
                title: preflightSummary,
                systemImage: vm.preflightHasBlockingFailures ? "exclamationmark.triangle.fill" : "checkmark.seal",
                color: vm.preflightHasBlockingFailures ? .orange : .green
            )
        }
        .buttonStyle(.plain)
        .help("Open preflight checks")
        .accessibilityHint("Opens Xcode Setup and shows preflight checks.")
    }

    private var cacheStatusBadge: some View {
        Button {
            onOpenCaching()
        } label: {
            statusBadgeLabel(
                title: vm.promptCachingHomeStatusTitle,
                systemImage: "bolt.horizontal.circle",
                color: cacheStatusColor
            )
        }
        .buttonStyle(.plain)
        .help(vm.promptCachingProviderStatusText)
        .accessibilityHint("Opens Xcode Setup to configure provider cache signals.")
    }

    private var cacheStatusColor: Color {
        switch vm.promptCachingMode {
        case .computeCacheHints:
            return vm.upstreamProvider == .google ? .orange : .green
        case .observeOnly, .explicitReferenceCache:
            return .secondary
        case .off:
            return .orange
        }
    }

    @ViewBuilder
    private var agentModelStatusBadge: some View {
        if vm.effectiveXcodeAgentModel.isEmpty {
            Button {
                onOpenAgentModel()
            } label: {
                statusBadgeLabel(
                    title: "Set agent model",
                    systemImage: "cpu",
                    color: .orange
                )
            }
            .buttonStyle(.plain)
            .help("Open agent model selection")
            .accessibilityHint("Opens Xcode Setup to select an agent model.")
        } else {
            // Always route-labelled. Unlabelled, this sits in a row of observed
            // traffic and reads as "this served your requests" — false whenever
            // a CLI daemon owns the proxy, which is the defect this fixes.
            statusBadge(
                title: vm.homeAgentModelBadgeLabel,
                systemImage: "cpu",
                color: vm.hasPendingXcodeAgentModelChange ? .orange : .secondary
            )
            .opacity(vm.isXcodeRouteIdle ? 0.65 : 1)
            .help(vm.homeAgentModelBadgeHelpText)
        }
    }

    private func statusBadgeLabel(title: String, systemImage: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
            Text(title)
                .lineLimit(1)
                .truncationMode(.middle)
                .minimumScaleFactor(0.85)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.12), in: Capsule())
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
            // Report the rows actually written (the retained history window),
            // not the unbounded session total — CSV export only covers what's in
            // the bounded `requests` buffer.
            sessionCSVExportStatus = "Exported \(vm.sessionReportCard.requests.count) requests to \(url.path)"
        } catch {
            sessionCSVExportStatus = "CSV export failed: \(error.localizedDescription)"
        }
    }

    private func formatLatency(_ seconds: TimeInterval) -> String {
        if seconds < 1 {
            return "\(Int((seconds * 1000).rounded()))ms"
        }
        return String(format: "%.2fs", seconds)
    }

    private func formatCompactInteger(_ value: Int) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.1fK", Double(value) / 1_000)
        }
        return "\(value)"
    }
}
