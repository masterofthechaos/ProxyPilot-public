import AppKit
import ProxyPilotCore
import SwiftUI
import UniformTypeIdentifiers

struct HomeDashboardView: View {
    @EnvironmentObject private var vm: AppViewModel
    @Binding var showInstallConfirmation: Bool

    let onOpenKeys: () -> Void
    let onOpenProxy: () -> Void
    let onOpenAgentModel: () -> Void
    let onOpenPreflight: () -> Void

    @State private var sessionCSVExportStatus: String = ""
    @State private var expandedSessionRequestIDs: Set<UUID> = []
    @State private var copiedSessionRequestID: UUID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if visibleHomeSections.isEmpty {
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
        }
    }

    private var visibleHomeSections: Set<HomeDashboardSection> {
        vm.visibleHomeDashboardSections
    }

    private var heroCard: some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Current Session")
                            .font(.title2.weight(.semibold))
                        Text(vm.isRunning ? "Proxy is running. Verify live route state below." : "Start ProxyPilot when you begin coding.")
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    statusBadge(
                        title: vm.isRunning ? "Running" : "Stopped",
                        systemImage: vm.isRunning ? "checkmark.circle.fill" : "circle.fill",
                        color: vm.isRunning ? .green : .secondary
                    )
                }

                ViewThatFits {
                    HStack(spacing: 12) {
                        heroMetric("Requests", "\(vm.sessionReportCard.totalRequests)", systemImage: "arrow.left.arrow.right")
                        heroMetric("Tokens", vm.sessionReportCard.totalTokensFormatted, systemImage: "number")
                        heroMetric("Cost", vm.formatUSD(vm.sessionEstimatedCostUSD), systemImage: "dollarsign.circle")
                        heroMetric("Latency", sessionLatencyText, systemImage: "timer")
                    }

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], spacing: 12) {
                        heroMetric("Requests", "\(vm.sessionReportCard.totalRequests)", systemImage: "arrow.left.arrow.right")
                        heroMetric("Tokens", vm.sessionReportCard.totalTokensFormatted, systemImage: "number")
                        heroMetric("Cost", vm.formatUSD(vm.sessionEstimatedCostUSD), systemImage: "dollarsign.circle")
                        heroMetric("Latency", sessionLatencyText, systemImage: "timer")
                    }
                }

                HStack(spacing: 10) {
                    statusBadge(
                        title: vm.upstreamProvider.title,
                        systemImage: "network",
                        color: .accentColor
                    )
                    agentModelStatusBadge
                    preflightStatusBadge
                    Spacer()
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

    private var workflowControls: some View {
        ViewThatFits {
            HStack(spacing: 12) {
                proxyActionGroup
                Spacer()
                workflowUtilityGroup
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
        DashboardCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Xcode Claude Agent Routing")
                        .font(.headline)
                    Spacer()
                    Text(vm.agentConfigInstalled ? "Installed" : "Not Installed")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(vm.agentConfigInstalled ? .green : .secondary)
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
                    Text("Applied: \(vm.xcodeAgentAppliedModelText)")
                    Text("Live: \(vm.xcodeAgentLiveRouteText)")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

                Button { onOpenProxy() } label: {
                    Text("Full setup and verification in **Proxy**.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
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
                HStack {
                    Text("Session Report Card")
                        .font(.headline)
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
                smallMetric("Prompt", "\(vm.sessionReportCard.totalPromptTokens)")
                smallMetric("Completion", "\(vm.sessionReportCard.totalCompletionTokens)")
                smallMetric("Total", vm.sessionReportCard.totalTokensFormatted)
                smallMetric("Cost", vm.formatUSD(vm.sessionEstimatedCostUSD))
                if let latency = vm.sessionLatencySummary {
                    smallMetric("P95", formatLatency(latency.p95))
                }
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 12)], alignment: .leading, spacing: 12) {
                smallMetric("Prompt", "\(vm.sessionReportCard.totalPromptTokens)")
                smallMetric("Completion", "\(vm.sessionReportCard.totalCompletionTokens)")
                smallMetric("Total", vm.sessionReportCard.totalTokensFormatted)
                smallMetric("Cost", vm.formatUSD(vm.sessionEstimatedCostUSD))
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
            .frame(maxHeight: 280)
        }
    }

    private var sessionLatencyText: String {
        guard let latency = vm.sessionLatencySummary else { return "No data" }
        return "p95 \(formatLatency(latency.p95))"
    }

    private var preflightSummary: String {
        if vm.preflightResults.isEmpty { return "Preflight not checked" }
        if vm.preflightHasBlockingFailures { return "Preflight needs attention" }
        return vm.isRunning ? "Preflight passed" : "Ready to start"
    }

    private func heroMetric(_ label: String, _ value: String, systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
        .accessibilityHint("Opens the Proxy section and shows preflight checks.")
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
            .accessibilityHint("Opens the Proxy section to select an agent model.")
        } else {
            statusBadge(
                title: vm.homeAgentModelBadgeTitle,
                systemImage: "cpu",
                color: vm.hasPendingXcodeAgentModelChange ? .orange : .secondary
            )
            .help(vm.homeAgentModelBadgeHelpText)
        }
    }

    private func statusBadgeLabel(title: String, systemImage: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
            Text(title)
                .lineLimit(1)
                .truncationMode(.middle)
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
            sessionCSVExportStatus = "Exported \(vm.sessionReportCard.totalRequests) requests to \(url.path)"
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
}
