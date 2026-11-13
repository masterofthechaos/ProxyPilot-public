import AppKit
import ProxyPilotCore
import SwiftUI
import UniformTypeIdentifiers

struct SessionHistoryView: View {
    private enum ViewMode: String, CaseIterable, Identifiable {
        case sessions
        case usage

        var id: String { rawValue }

        var title: String {
            switch self {
            case .sessions: return "Session History"
            case .usage: return "Your Usage"
            }
        }
    }

    private enum RequestTokenKind {
        case prompt
        case completion
        case total
    }

    @EnvironmentObject private var vm: AppViewModel

    let prefersCompactLayout: Bool
    let onOpenAdvancedLogging: () -> Void

    @State private var selectedViewMode: ViewMode = .sessions
    @State private var selectedSessionID: String?
    @State private var expandedRequestOffsets: Set<Int> = []
    @State private var expandedLogIDs: Set<UUID> = []
    @State private var copiedRequestOffset: Int?
    @State private var copiedLogTarget: String?
    @State private var copiedSessionFormat: String?
    @State private var showAllRequests = false
    @State private var showAllInputOutputLogs = false
    @State private var selectedSessionLogViewModels: [SessionHistoryLogRecordViewModel] = []
    @State private var selectedSessionLogLoadTask: Task<Void, Never>?
    @State private var selectedSessionLogLoadError: String?
    @State private var isLoadingSelectedSessionLogs = false
    @State private var fileExportStatus: String?
    @State private var historyBackupStatus: String?
    @State private var historyBackupBusy = false
    @State private var historyImportURL: URL?
    @State private var historyImportPreview: SessionHistoryImportPreview?
    @State private var showingHistoryImportPreview = false

    private var selectedSession: SessionHistorySession? {
        if let selectedSessionID,
           let session = vm.sessionHistorySessions.first(where: { $0.id == selectedSessionID }) {
            return session
        }
        return vm.sessionHistorySessions.first
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .layoutPriority(1)
            Divider()

            if selectedViewMode == .sessions {
                if vm.sessionHistorySessions.isEmpty {
                    emptyState
                } else {
                    responsiveSessionBrowser
                }
            } else {
                usageBrowser
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task {
            await refreshHistory()
        }
        .onChange(of: selectedSessionID) { _, _ in
            resetSessionDetailState()
            // Only the session browser renders the decrypted prompt/output log; the
            // Your Usage view does not, so skip the per-session log reload there.
            guard selectedViewMode == .sessions else { return }
            scheduleSelectedLogRefresh()
        }
        .onDisappear {
            selectedSessionLogLoadTask?.cancel()
        }
        .alert("History Backup Preview", isPresented: $showingHistoryImportPreview) {
            if historyImportPreview?.canImport == true {
                Button("Merge History") { mergeHistoryBackup() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let preview = historyImportPreview {
                Text("\(preview.newEvents) new records\n\(preview.duplicateEvents) duplicates\n\(preview.conflictingEvents) conflicts\n\(preview.invalidRecords) invalid records\n\n" +
                    (preview.canImport ? "New records will be added to your current history. Existing records are preserved." : "This backup cannot be merged. No history has changed."))
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            ViewThatFits {
                HStack(alignment: .center, spacing: 12) {
                    headerTitle
                    Spacer()
                    refreshButton
                }

                VStack(alignment: .leading, spacing: 10) {
                    headerTitle
                    refreshButton
                }
            }

            Picker("Session History View", selection: $selectedViewMode) {
                ForEach(ViewMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 360)

            HStack(spacing: 12) {
                Menu {
                    Button("Export History Backup…", action: exportHistoryBackup)
                    Button("Import History Backup…", action: previewHistoryBackup)
                } label: {
                    Label("History Backup", systemImage: "externaldrive")
                }
                .fixedSize()
                .disabled(historyBackupBusy)
                if historyBackupBusy { ProgressView().controlSize(.small) }
                Text(historyBackupStatus ?? "All session metadata; excludes prompts, outputs, preferences and keys.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(24)
    }

    private var headerTitle: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(selectedViewMode.title)
                .font(.title2.weight(.semibold))
            Text(headerSubtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var headerSubtitle: String {
        switch selectedViewMode {
        case .sessions:
            return "Review previous ProxyPilot sessions, including CLI and MCP request metadata. Full prompt and output bodies only appear when Input & Output Logging is enabled, and copy/export actions include decrypted content."
        case .usage:
            return "View all-time usage rolled up from the persisted session-report store, including token totals, source and model breakdowns, latency, and long-running session highlights."
        }
    }

    private var refreshButton: some View {
        Button {
            Task { await refreshHistory() }
        } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
        }
    }

    private func exportHistoryBackup() {
        let panel = NSSavePanel()
        panel.title = "Export History Backup"
        panel.nameFieldStringValue = "ProxyPilot-History.pphistory"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        historyBackupBusy = true
        Task {
            defer { historyBackupBusy = false }
            do {
                let count = try await vm.exportSessionHistory(to: destination)
                historyBackupStatus = "Backed up \(count) metadata records to \(destination.lastPathComponent)."
            } catch { historyBackupStatus = error.localizedDescription }
        }
    }

    private func previewHistoryBackup() {
        let panel = NSOpenPanel()
        panel.title = "Import History Backup"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let backup = panel.url else { return }
        historyBackupBusy = true
        Task {
            defer { historyBackupBusy = false }
            do {
                historyImportPreview = try await vm.previewSessionHistoryImport(from: backup)
                historyImportURL = backup
                showingHistoryImportPreview = true
            } catch { historyBackupStatus = error.localizedDescription }
        }
    }

    private func mergeHistoryBackup() {
        guard let backup = historyImportURL else { return }
        historyBackupBusy = true
        Task {
            defer { historyBackupBusy = false }
            do {
                let result = try await vm.importSessionHistory(from: backup)
                historyBackupStatus = "Imported \(result.newEvents) records; skipped \(result.duplicateEvents) duplicates."
            } catch { historyBackupStatus = error.localizedDescription }
        }
    }

    private var responsiveSessionBrowser: some View {
        VStack(spacing: 0) {
            sessionSelectorBar
            Divider()
            sessionDetail
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var usageBrowser: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                if vm.allTimeUsage.isEmpty {
                    usageEmptyState
                } else {
                    usageSummary(vm.allTimeUsage)
                    usageHighlights(vm.allTimeUsage)
                    usageBreakdowns(vm.allTimeUsage)
                    usageTimeline(vm.allTimeUsage)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var sessionSelectorBar: some View {
        ViewThatFits {
            HStack(alignment: .center, spacing: 12) {
                compactSessionPicker
                Spacer(minLength: 12)
                selectedSessionSummary
            }

            VStack(alignment: .leading, spacing: 8) {
                compactSessionPicker
                selectedSessionSummary
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    private var compactSessionPicker: some View {
        Picker("Session", selection: Binding(
            get: { selectedSession?.id },
            set: { selectedSessionID = $0 }
        )) {
            ForEach(vm.sessionHistorySessions) { session in
                Text("\(session.sourceLabel) - \(session.requestCount) req - \(sessionTokenSummary(session))")
                    .tag(Optional(session.id))
            }
        }
        .pickerStyle(.menu)
    }

    @ViewBuilder
    private var selectedSessionSummary: some View {
        if let session = selectedSession {
            Text("\(session.requestCount) req - \(sessionTokenSummary(session))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(.secondary)

            Text("No saved sessions yet")
                .font(.title3.weight(.semibold))

            Text("Session report cards are saved from CLI and MCP proxy traffic even when full Input & Output Logging is off. Start a CLI session and send a request to populate this page with request counts, token totals, latency, model distribution, and recent request metadata.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Full prompt/output logging")
                    .font(.headline)
                Text("When you enable Input & Output Logging, this page will also show saved prompt and output records for sessions that include matching log data. Until then, ProxyPilot keeps this page limited to report-card metadata.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button("Open Input & Output Logging Settings") {
                onOpenAdvancedLogging()
            }
        }
        .padding(24)
        .frame(maxWidth: 560, maxHeight: .infinity, alignment: .center)
        .frame(maxWidth: .infinity)
    }

    private var usageEmptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(.secondary)

            Text("No usage data yet")
                .font(.title3.weight(.semibold))

            Text("Your Usage rolls up the same saved session-report store that powers Session History. Start the proxy and send a few requests, then come back here for all-time token totals, model and provider breakdowns, latency, and session highlights.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(maxWidth: 560, maxHeight: .infinity, alignment: .center)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var sessionDetail: some View {
        if let session = selectedSession {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    sessionDetailStack(session)
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(session.id)
        } else {
            Text("Select a session.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func sessionDetailStack(_ session: SessionHistorySession) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            sessionHeader(session)
            if let fileExportStatus {
                Text(fileExportStatus)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            metricGrid(session)
            modelDistribution(session)
            requestTimeline(session)
            inputOutputArea(session)
        }
    }

    private func usageSummary(_ usage: AllTimeUsage) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("All-Time Summary")
                .font(.headline)

            ViewThatFits {
                HStack(alignment: .top, spacing: 12) {
                    usageMetaBlock(title: "Range", value: usageTimeRange(usage))
                    usageCacheSummary(usage)
                    Spacer(minLength: 0)
                }

                VStack(alignment: .leading, spacing: 10) {
                    usageMetaBlock(title: "Range", value: usageTimeRange(usage))
                    usageCacheSummary(usage)
                }
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 12)], alignment: .leading, spacing: 12) {
                metric("Requests", "\(usage.requestCount)")
                metric("Sessions", "\(usage.sessionCount)")
                metric("Tokens", usage.totalTokensFormatted)
                metric("Prompt", formatCompactInteger(usage.totalPromptTokens))
                metric("Completion", formatCompactInteger(usage.totalCompletionTokens))
                metric("P50", usage.p50Latency.map(formatLatency) ?? "No data")
                metric("P95", usage.p95Latency.map(formatLatency) ?? "No data")
                metric("Avg", usage.avgLatency.map(formatLatency) ?? "No data")
                metric("Max", usage.maxLatency.map(formatLatency) ?? "No data")
                if usage.cacheAccountingAvailable {
                    metric("Cached", formatCompactInteger(usage.totalPromptCacheHitTokens))
                    metric("Uncached", formatCompactInteger(usage.totalPromptCacheMissTokens))
                    if usage.totalPromptCacheWriteTokens > 0 {
                        metric("Cache Write", formatCompactInteger(usage.totalPromptCacheWriteTokens))
                    }
                }
                metric("Req / Session", usage.averageRequestsPerSession.map { String(format: "%.2f", $0) } ?? "No data")
                metric("Session Span", usage.averageSessionDurationSeconds.map(formatLatency) ?? "No data")
            }
        }
        .padding(14)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func usageCacheSummary(_ usage: AllTimeUsage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            usageMetaBlock(title: "Cache", value: usage.cacheHitRate.map { "\(formatPercent($0)) hit rate" } ?? "Hit rate unavailable")
            Text("Cache usage reported for \(usage.cacheObservedRequests) of \(usage.requestCount) requests")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Hit rate uses requests with both cached and uncached token counts.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func usageHighlights(_ usage: AllTimeUsage) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Session Highlights")
                .font(.headline)

            ViewThatFits {
                HStack(alignment: .top, spacing: 12) {
                    usageSessionStatCard(title: "Longest Session", session: usage.longestSession)
                    usageSessionStatCard(title: "Busiest Session", session: usage.busiestSession)
                }

                VStack(alignment: .leading, spacing: 12) {
                    usageSessionStatCard(title: "Longest Session", session: usage.longestSession)
                    usageSessionStatCard(title: "Busiest Session", session: usage.busiestSession)
                }
            }
        }
        .padding(14)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func usageBreakdowns(_ usage: AllTimeUsage) -> some View {
        ViewThatFits {
            HStack(alignment: .top, spacing: 12) {
                usageShareCard(
                    title: "Provider Shares",
                    emptyText: "No provider data available.",
                    rows: usage.sourceShares.map { share in
                        (
                            label: share.source.isEmpty ? "(unknown source)" : share.source.uppercased(),
                            detail: "\(share.requestCount) req",
                            trailing: formatCompactInteger(share.totalTokens) + " tok"
                        )
                    }
                )
                usageShareCard(
                    title: "Model Distribution",
                    emptyText: "No model data available.",
                    rows: usage.modelDistribution.map { entry in
                        (
                            label: entry.model.isEmpty ? "(unknown model)" : entry.model,
                            detail: "\(entry.count) req",
                            trailing: ""
                        )
                    }
                )
            }

            VStack(alignment: .leading, spacing: 12) {
                usageShareCard(
                    title: "Provider Shares",
                    emptyText: "No provider data available.",
                    rows: usage.sourceShares.map { share in
                        (
                            label: share.source.isEmpty ? "(unknown source)" : share.source.uppercased(),
                            detail: "\(share.requestCount) req",
                            trailing: formatCompactInteger(share.totalTokens) + " tok"
                        )
                    }
                )
                usageShareCard(
                    title: "Model Distribution",
                    emptyText: "No model data available.",
                    rows: usage.modelDistribution.map { entry in
                        (
                            label: entry.model.isEmpty ? "(unknown model)" : entry.model,
                            detail: "\(entry.count) req",
                            trailing: ""
                        )
                    }
                )
            }
        }
    }

    private func usageTimeline(_ usage: AllTimeUsage) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Daily Activity")
                .font(.headline)

            if usage.dailyTokenBuckets.isEmpty {
                Text("No daily buckets are available yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(usage.dailyTokenBuckets, id: \.day) { bucket in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(bucket.day.formatted(date: .abbreviated, time: .omitted))
                                .font(.caption.weight(.semibold))
                            Text("\(bucket.requestCount) request\(bucket.requestCount == 1 ? "" : "s")")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(formatCompactInteger(bucket.totalTokens) + " tok")
                            .font(.system(.caption, design: .monospaced))
                        Text(formatCompactInteger(bucket.requestCount))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        }
        .padding(14)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func sessionHeader(_ session: SessionHistorySession) -> some View {
        ViewThatFits {
            HStack(alignment: .top, spacing: 16) {
                sessionHeaderText(session)
                Spacer()
                sessionCopyMenu(session)
            }

            VStack(alignment: .leading, spacing: 10) {
                sessionHeaderText(session)
                sessionCopyMenu(session)
            }
        }
    }

    private func sessionHeaderText(_ session: SessionHistorySession) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(sessionTitle(session))
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                sourceBadge(session.sourceLabel)
            }

            Text(session.id)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Text(sessionTimeRange(session))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func sessionCopyMenu(_ session: SessionHistorySession) -> some View {
        Menu(copiedSessionFormat == nil ? "Copy" : "Copied") {
            Section("Session metadata") {
                Button("Session as JSON") {
                    copySessionJSON(session)
                }
                Button("Session as Markdown") {
                    copySessionMarkdown(session)
                }
            }
            let logs = matchingLogViewModels(for: session).map(\.record)
            if !logs.isEmpty {
                Section(SessionHistorySensitiveCopy.menuSectionTitle) {
                    Button(SessionHistorySensitiveCopy.jsonlMenuTitle) {
                        copySessionLogsJSONL(logs)
                    }
                    Button(SessionHistorySensitiveCopy.markdownMenuTitle) {
                        copySessionLogsMarkdown(logs)
                    }
                }
            }
            Section("Export to file") {
                Button("Session as CSV...") {
                    exportSessionCSV(session)
                }
                Button("Session as JSON...") {
                    exportSessionJSONToFile(session)
                }
            }
        }
        .font(.caption)
    }

    private func metricGrid(_ session: SessionHistorySession) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 12)], alignment: .leading, spacing: 12) {
                metric("Requests", "\(session.requestCount)")
                metric("Prompt", session.tokenAccountingAvailable ? "\(session.totalPromptTokens)" : "Unavailable")
                metric("Completion", session.tokenAccountingAvailable ? "\(session.totalCompletionTokens)" : "Unavailable")
                metric("Total", session.tokenAccountingAvailable ? session.totalTokensFormatted : "Unavailable")
                if session.cacheAccountingAvailable {
                    metric("Cached", formatCompactInteger(session.totalPromptCacheHitTokens))
                    metric("Uncached", formatCompactInteger(session.totalPromptCacheMissTokens))
                    if session.totalPromptCacheWriteTokens > 0 {
                        metric("Cache Write", formatCompactInteger(session.totalPromptCacheWriteTokens))
                    }
                }
                metric("P95", session.p95Latency.map(formatLatency) ?? "No data")
            }
            if !session.tokenAccountingAvailable, session.requestCount > 0 {
                Text("ProxyPilot did not receive usable token counts from the upstream response for this session.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func usageMetaBlock(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func usageSessionStatCard(title: String, session: AllTimeUsage.SessionStat?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.caption.weight(.semibold))
                Spacer()
                if let session {
                    Text("\(session.requestCount) req")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if let session {
                Text(session.id)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack {
                    Text(session.source.isEmpty ? "(unknown source)" : (session.source == "xcode-agent" ? "ProxyPilot Agent" : (session.source == "repogps" ? "RepoGPS" : session.source.uppercased())))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                    Spacer()
                    Text("\(formatCompactInteger(session.totalTokens)) tok")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text(session.startedAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "No start")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(formatLatency(session.durationSeconds))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("No session data available.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func usageShareCard(
        title: String,
        emptyText: String,
        rows: [(label: String, detail: String, trailing: String)]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)

            if rows.isEmpty {
                Text(emptyText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.label)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(row.detail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !row.trailing.isEmpty {
                            Text(row.trailing)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(10)
                    .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func modelDistribution(_ session: SessionHistorySession) -> some View {
        let modelDistribution = session.modelDistribution

        return VStack(alignment: .leading, spacing: 8) {
            Text("Model Distribution")
                .font(.headline)

            if modelDistribution.isEmpty {
                Text("No model metadata was recorded for this session.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(modelDistribution, id: \.model) { entry in
                    HStack {
                        Text(entry.model.isEmpty ? "(unknown model)" : entry.model)
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
        .padding(14)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func requestTimeline(_ session: SessionHistorySession) -> some View {
        let visibleRequests = SessionHistoryDisplayPolicy.visibleRequests(
            for: session,
            showAll: showAllRequests
        )
        let hiddenRequestCount = SessionHistoryDisplayPolicy.hiddenRequestCount(
            for: session,
            showAll: showAllRequests
        )

        return VStack(alignment: .leading, spacing: 8) {
            Text("Requests")
                .font(.headline)

            ForEach(Array(visibleRequests.enumerated()), id: \.offset) { offset, request in
                DisclosureGroup(isExpanded: requestExpansionBinding(for: offset)) {
                    VStack(alignment: .leading, spacing: 4) {
                        detailRow("Path", request.path)
                        detailRow("Streaming", request.wasStreaming ? "Yes" : "No")
                        detailRow("Prompt", requestTokenValue(request, kind: .prompt))
                        detailRow("Completion", requestTokenValue(request, kind: .completion))
                        detailRow("Total", requestTokenValue(request, kind: .total))
                        if let mode = request.promptCachingMode {
                            detailRow("Caching preference", mode == "computeCacheHints" ? "Automatic" : mode)
                        }
                        detailRow("Cache strategy", request.promptCacheStrategy ?? "Not recorded")
                        detailRow("Cache hints applied", request.promptCacheApplied.map { $0 ? "Yes" : "No" } ?? "Not recorded")
                        if request.promptCacheHitTokens == nil && request.promptCacheMissTokens == nil && request.promptCacheWriteTokens == nil {
                            detailRow("Cache usage", "Not reported by provider")
                        }
                        if let hit = request.promptCacheHitTokens {
                            detailRow("Cached", "\(hit)")
                        }
                        if let miss = request.promptCacheMissTokens {
                            detailRow("Uncached", "\(miss)")
                        }
                        if let write = request.promptCacheWriteTokens {
                            detailRow("Cache write", "\(write)")
                        }
                        detailRow("Latency", formatLatency(request.durationSeconds))

                        HStack {
                            Spacer()
                            Button(copiedRequestOffset == offset ? "Copied JSON" : "Copy JSON") {
                                copyRequestJSON(request, offset: offset)
                            }
                            .font(.caption2)
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    HStack {
                        Text(request.timestamp, format: .dateTime.hour().minute().second())
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(request.model.isEmpty ? "(unknown model)" : request.model)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text(requestInlineTokenSummary(request))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if let hit = request.promptCacheHitTokens, hit > 0 {
                            Text("\(formatCompactInteger(hit)) cached")
                                .font(.caption2)
                                .foregroundStyle(.green)
                        }
                        Text(formatLatency(request.durationSeconds))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            if hiddenRequestCount > 0 {
                Button("Show \(hiddenRequestCount) more request\(hiddenRequestCount == 1 ? "" : "s")") {
                    showAllRequests = true
                }
                .font(.caption)
            } else if showAllRequests && session.requestCount > SessionHistoryDisplayPolicy.defaultVisibleRequestLimit {
                Button("Show fewer requests") {
                    showAllRequests = false
                    pruneExpandedRequests(to: SessionHistoryDisplayPolicy.defaultVisibleRequestLimit)
                }
                .font(.caption)
            }
        }
    }

    private func inputOutputArea(_ session: SessionHistorySession) -> some View {
        let matchingLogs = matchingLogViewModels(for: session)
        let visibleLogs = SessionHistoryDisplayPolicy.visibleLogs(
            matchingLogs,
            showAll: showAllInputOutputLogs
        )
        let hiddenLogCount = SessionHistoryDisplayPolicy.hiddenLogCount(
            matchingLogs,
            showAll: showAllInputOutputLogs
        )
        let availability = session.inputOutputLogAvailability(
            masterLoggingEnabled: vm.inputOutputLoggingEnabled,
            cliLoggingEnabled: vm.inputOutputLoggingCLIEnabled,
            matchingRecordCount: matchingLogs.count,
            retention: vm.inputOutputLoggingRetention
        )
        return VStack(alignment: .leading, spacing: 10) {
            Text("Input & Output Logs")
                .font(.headline)

            if isLoadingSelectedSessionLogs {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading prompt/output records for this session...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let selectedSessionLogLoadError {
                Text("Prompt/output records could not be loaded: \(selectedSessionLogLoadError)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                switch availability {
                case .hasRecords(let count):
                    Text("\(count) prompt/output record\(count == 1 ? "" : "s") saved for this session. Expand a record to inspect the prompt and output body, copy either side, or export the full exchange as Markdown or JSON.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    sensitiveLogContentNotice

                    ForEach(visibleLogs) { log in
                        inputOutputLogRow(log)
                    }

                    if hiddenLogCount > 0 {
                        Button("Show \(hiddenLogCount) more prompt/output record\(hiddenLogCount == 1 ? "" : "s")") {
                            showAllInputOutputLogs = true
                        }
                        .font(.caption)
                    } else if showAllInputOutputLogs && matchingLogs.count > SessionHistoryDisplayPolicy.defaultVisibleLogLimit {
                        Button("Show fewer prompt/output records") {
                            showAllInputOutputLogs = false
                            pruneExpandedLogs(to: SessionHistoryDisplayPolicy.visibleLogs(matchingLogs, showAll: false))
                        }
                        .font(.caption)
                    }

                case .masterLoggingDisabled:
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Full input/output logging is off. ProxyPilot still saves report-card metadata for this session history, but it does not save prompt or output bodies unless you explicitly enable logging.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Button("Open Input & Output Logging Settings") {
                            onOpenAdvancedLogging()
                        }
                        .font(.caption)
                    }

                case .retentionExpired(let retention):
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Prompt/output bodies are no longer available for this session. The session is outside the selected retention window, so any captured bodies would have been deleted while the report-card metadata stayed available.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Text("Current retention: \(retentionDisplayName(retention))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                case .cliCaptureDisabled:
                    Text("Input & Output Logging is enabled for the app, but CLI/MCP capture is off. ProxyPilot can show this session's report-card metadata, but it did not save prompt or output bodies for CLI traffic. Enable logging for ProxyPilot CLI in Settings → Privacy & Logging before starting a CLI or MCP session if you want future CLI/MCP prompt and output records to appear here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Button("Open Input & Output Logging Settings", action: onOpenAdvancedLogging)
                        .font(.caption)

                case .enabledWaitingForRecords:
                    Text("Full logging is enabled for this session source, but this session does not have saved prompt/output records. New records with matching session metadata will appear here as they are captured.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var sensitiveLogContentNotice: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lock.open.trianglebadge.exclamationmark")
                .foregroundStyle(.orange)
            Text(SessionHistorySensitiveCopy.inlineNotice)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func inputOutputLogRow(_ log: SessionHistoryLogRecordViewModel) -> some View {
        let record = log.record
        return DisclosureGroup(isExpanded: logExpansionBinding(for: record.id)) {
            if expandedLogIDs.contains(record.id) {
                VStack(alignment: .leading, spacing: 12) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], alignment: .leading, spacing: 8) {
                        compactLogMetric("Provider", record.provider)
                        compactLogMetric("Model", record.model)
                        compactLogMetric("Path", record.path)
                        compactLogMetric("Status", record.statusCode.map(String.init) ?? "Unknown")
                        compactLogMetric("Streaming", record.wasStreaming ? "Yes" : "No")
                        compactLogMetric("Record ID", record.id.uuidString)
                    }

                    if let input = record.input {
                        logBodySection(
                            title: "Prompt",
                            content: input,
                            tokenLabel: "In",
                            tokenCount: log.tokenCounts?.promptTokens,
                            copyID: "\(record.id.uuidString)-prompt",
                            copyTitle: "Copy Prompt"
                        )
                    }

                    if let output = record.output {
                        let parsedOutput = SessionHistoryOutputParser.parse(output)
                        parsedOutputSection(parsedOutput)
                        logBodySection(
                            title: "Output",
                            content: output,
                            tokenLabel: "Out",
                            tokenCount: log.tokenCounts?.completionTokens,
                            copyID: "\(record.id.uuidString)-output",
                            copyTitle: "Copy Output"
                        )
                    }

                    HStack(spacing: 8) {
                        Spacer()
                        Button(copiedLogTarget == "\(record.id.uuidString)-json" ? "Copied JSON" : "Copy JSON") {
                            copyLogJSON(record)
                        }
                        Button(copiedLogTarget == "\(record.id.uuidString)-markdown" ? "Copied Markdown" : "Copy Markdown") {
                            copyLogMarkdown(record)
                        }
                    }
                    .font(.caption2)
                }
                .padding(.top, 8)
            }
        } label: {
            HStack(spacing: 8) {
                Text("#\(log.index)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(record.timestamp, format: .dateTime.hour().minute().second())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(record.model.isEmpty ? "(unknown model)" : record.model)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if let tokenCounts = log.tokenCounts {
                    tokenPill("In", tokenCounts.promptTokens)
                    tokenPill("Out", tokenCounts.completionTokens)
                    if let hit = tokenCounts.promptCacheHitTokens, hit > 0 {
                        tokenPill("Cached", hit)
                    }
                }
                if record.input != nil {
                    Label("Prompt", systemImage: "text.alignleft")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.secondary)
                }
                if record.output != nil {
                    Label("Output", systemImage: "arrow.down.doc")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    private func parsedOutputSection(_ parsed: SessionHistoryParsedOutput) -> some View {
        let readableText = parsed.assistantText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !readableText.isEmpty || !parsed.toolCalls.isEmpty || parsed.hasMalformedData {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("Readable Output")
                        .font(.caption.weight(.semibold))
                    parsedOutputPill(parsed)
                    Spacer()
                }

                if !readableText.isEmpty {
                    Text(readableText)
                        .font(.system(.caption, design: .default))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }

                ForEach(parsed.toolCalls) { toolCall in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Tool call: \(toolCall.name)")
                            .font(.caption2.weight(.semibold))
                        if !toolCall.inputPreview.isEmpty {
                            Text(toolCall.inputPreview)
                                .font(.system(.caption2, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(10)
                    .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }

                if parsed.hasMalformedData {
                    Text("Some streaming chunks could not be decoded. The raw captured output is still shown below.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func logBodySection(
        title: String,
        content: InputOutputLogContent,
        tokenLabel: String,
        tokenCount: Int?,
        copyID: String,
        copyTitle: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.caption.weight(.semibold))
                Text(content.sessionHistoryEncodingLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let tokenCount {
                    tokenPill(tokenLabel, tokenCount)
                }
                Spacer()
                Button(copiedLogTarget == copyID ? "Copied" : copyTitle) {
                    copyString(content.sessionHistoryText, copiedTarget: copyID)
                }
                .font(.caption2)
            }

            ScrollView {
                Text(content.sessionHistoryText.isEmpty ? "(empty)" : content.sessionHistoryText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(maxHeight: 220)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    private func parsedOutputPill(_ parsed: SessionHistoryParsedOutput) -> some View {
        Text(parsed.summary)
            .font(.caption2.weight(.medium))
            .foregroundStyle(parsedOutputPillColor(parsed.kind))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(parsedOutputPillColor(parsed.kind).opacity(0.10), in: Capsule())
    }

    private func parsedOutputPillColor(_ kind: SessionHistoryParsedOutputKind) -> Color {
        switch kind {
        case .assistantResponse:
            return .blue
        case .toolCallOnly:
            return .orange
        case .rawStructure:
            return .secondary
        }
    }

    private func tokenPill(_ label: String, _ value: Int) -> some View {
        Text("\(label) \(formatCompactInteger(value))")
            .font(.caption2.weight(.medium))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.secondary.opacity(0.10), in: Capsule())
    }

    private func sessionTokenSummary(_ session: SessionHistorySession) -> String {
        session.tokenAccountingAvailable ? "\(session.totalTokensFormatted) tokens" : "token usage unavailable"
    }

    private func requestHasTokenTelemetry(_ request: RequestRecord) -> Bool {
        request.promptTokens > 0
            || request.completionTokens > 0
            || request.promptCacheHitTokens != nil
            || request.promptCacheMissTokens != nil
            || request.promptCacheWriteTokens != nil
    }

    private func requestTokenValue(_ request: RequestRecord, kind: RequestTokenKind) -> String {
        guard requestHasTokenTelemetry(request) else { return "Unavailable" }
        switch kind {
        case .prompt:
            return "\(request.promptTokens)"
        case .completion:
            return "\(request.completionTokens)"
        case .total:
            return "\(request.promptTokens + request.completionTokens)"
        }
    }

    private func requestInlineTokenSummary(_ request: RequestRecord) -> String {
        guard requestHasTokenTelemetry(request) else { return "token usage unavailable" }
        return "\(request.promptTokens + request.completionTokens) tok"
    }

    private func compactLogMetric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.caption2, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.callout, design: .monospaced).weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func sourceBadge(_ source: String) -> some View {
        Text(source.uppercased())
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.accentColor.opacity(0.12), in: Capsule())
            .foregroundStyle(Color.accentColor)
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
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

    private func requestExpansionBinding(for offset: Int) -> Binding<Bool> {
        Binding(
            get: { expandedRequestOffsets.contains(offset) },
            set: { isExpanded in
                if isExpanded {
                    expandedRequestOffsets.insert(offset)
                } else {
                    expandedRequestOffsets.remove(offset)
                }
            }
        )
    }

    private func logExpansionBinding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { expandedLogIDs.contains(id) },
            set: { isExpanded in
                if isExpanded {
                    expandedLogIDs.insert(id)
                } else {
                    expandedLogIDs.remove(id)
                }
            }
        )
    }

    private func resetSessionDetailState() {
        expandedRequestOffsets.removeAll()
        expandedLogIDs.removeAll()
        copiedRequestOffset = nil
        copiedLogTarget = nil
        copiedSessionFormat = nil
        showAllRequests = false
        showAllInputOutputLogs = false
    }

    private func pruneExpandedRequests(to visibleLimit: Int) {
        expandedRequestOffsets = expandedRequestOffsets.filter { $0 < visibleLimit }
    }

    private func pruneExpandedLogs(to visibleLogs: [SessionHistoryLogRecordViewModel]) {
        let visibleIDs = Set(visibleLogs.map(\.id))
        expandedLogIDs = expandedLogIDs.filter { visibleIDs.contains($0) }
    }

    private func matchingLogViewModels(for session: SessionHistorySession) -> [SessionHistoryLogRecordViewModel] {
        if session.id == selectedSession?.id {
            return selectedSessionLogViewModels
        }
        return []
    }

    private func copyRequestJSON(_ request: ProxyPilotCore.RequestRecord, offset: Int) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(request),
              let json = String(data: data, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(json, forType: .string)
        copiedRequestOffset = offset
    }

    private func copyLogJSON(_ record: InputOutputLogRecord) {
        guard let json = try? SessionHistoryLogExport.json(for: record) else { return }
        copyString(json, copiedTarget: "\(record.id.uuidString)-json")
    }

    private func copyLogMarkdown(_ record: InputOutputLogRecord) {
        copyString(
            SessionHistoryLogExport.markdown(for: record),
            copiedTarget: "\(record.id.uuidString)-markdown"
        )
    }

    private func copySessionLogsJSONL(_ logs: [InputOutputLogRecord]) {
        guard let jsonl = try? SessionHistoryLogExport.jsonl(for: logs) else { return }
        copyString(jsonl, copiedTarget: "session-logs-jsonl")
        copiedSessionFormat = "logs-jsonl"
    }

    private func copySessionLogsMarkdown(_ logs: [InputOutputLogRecord]) {
        copyString(
            SessionHistoryLogExport.markdown(for: logs),
            copiedTarget: "session-logs-markdown"
        )
        copiedSessionFormat = "logs-markdown"
    }

    private func copyString(_ value: String, copiedTarget: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        copiedLogTarget = copiedTarget
    }

    private func copySessionJSON(_ session: SessionHistorySession) {
        guard let json = try? SessionHistoryFileExport.json(for: session) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(json, forType: .string)
        copiedSessionFormat = "json"
    }

    private func exportSessionJSONToFile(_ session: SessionHistorySession) {
        guard let json = try? SessionHistoryFileExport.json(for: session) else {
            fileExportStatus = "JSON export failed: could not encode session."
            return
        }
        writeSessionExport(
            session: session,
            content: json,
            fileExtension: "json",
            contentType: .json
        )
    }

    private func exportSessionCSV(_ session: SessionHistorySession) {
        writeSessionExport(
            session: session,
            content: SessionHistoryFileExport.csv(for: session),
            fileExtension: "csv",
            contentType: UTType(filenameExtension: "csv") ?? .commaSeparatedText
        )
    }

    private func writeSessionExport(
        session: SessionHistorySession,
        content: String,
        fileExtension: String,
        contentType: UTType
    ) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let suggestedName = "proxypilot-session-\(formatter.string(from: Date())).\(fileExtension)"

        let panel = NSSavePanel()
        panel.title = "Export Session as \(fileExtension.uppercased())"
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [contentType]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let temporaryURL = url.deletingLastPathComponent()
                .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
            let data = Data(content.utf8)
            guard FileManager.default.createFile(
                atPath: temporaryURL.path,
                contents: data,
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw CocoaError(.fileWriteUnknown)
            }
            defer { try? FileManager.default.removeItem(at: temporaryURL) }
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temporaryURL)
            } else {
                try FileManager.default.moveItem(at: temporaryURL, to: url)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            fileExportStatus = "Exported session to \(url.path)"
        } catch {
            fileExportStatus = "Export failed: \(error.localizedDescription)"
        }
    }

    private func copySessionMarkdown(_ session: SessionHistorySession) {
        var lines: [String] = [
            "# \(sessionTitle(session))",
            "",
            "- Session ID: `\(session.id)`",
            "- Source: \(session.source)",
            "- Time: \(sessionTimeRange(session))",
            "- Requests: \(session.requestCount)",
            "- Prompt tokens: \(session.totalPromptTokens)",
            "- Completion tokens: \(session.totalCompletionTokens)",
            "- Total tokens: \(session.totalTokens)",
            ""
        ]

        if !session.modelDistribution.isEmpty {
            lines.append("## Model Distribution")
            lines.append("")
            for entry in session.modelDistribution {
                lines.append("- `\(entry.model)`: \(entry.count) request\(entry.count == 1 ? "" : "s")")
            }
            lines.append("")
        }

        lines.append("## Requests")
        lines.append("")
        for request in session.requests {
            lines.append("- \(request.timestamp.formatted(date: .abbreviated, time: .standard)): `\(request.model)` \(request.promptTokens + request.completionTokens) tokens, \(formatLatency(request.durationSeconds)), `\(request.path)`")
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        copiedSessionFormat = "markdown"
    }

    private func sessionTitle(_ session: SessionHistorySession) -> String {
        session.isRepoGPS ? "RepoGPS Run" : "\(session.sourceLabel) Session"
    }

    private func sessionTimeRange(_ session: SessionHistorySession) -> String {
        guard let startedAt = session.startedAt else { return "No timestamp" }
        let start = startedAt.formatted(date: .abbreviated, time: .shortened)
        guard let endedAt = session.endedAt, endedAt != startedAt else { return start }
        return "\(start) - \(endedAt.formatted(date: .omitted, time: .shortened))"
    }

    private func formatLatency(_ seconds: TimeInterval) -> String {
        if seconds < 1 {
            return "\(Int((seconds * 1000).rounded()))ms"
        }
        return String(format: "%.2fs", seconds)
    }

    private func usageTimeRange(_ usage: AllTimeUsage) -> String {
        guard let startedAt = usage.startedAt else { return "No usage data" }
        let start = startedAt.formatted(date: .abbreviated, time: .shortened)
        guard let endedAt = usage.endedAt, endedAt != startedAt else { return start }
        return "\(start) - \(endedAt.formatted(date: .abbreviated, time: .shortened))"
    }

    private func formatPercent(_ value: Double) -> String {
        String(format: "%.1f%%", value * 100)
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

    private func retentionDisplayName(_ retention: InputOutputLoggingRetention) -> String {
        switch retention {
        case .untilQuit:
            return "Until quit"
        case .thirtyMinutes:
            return "30 minutes"
        case .oneHour:
            return "1 hour"
        case .twoHours:
            return "2 hours"
        case .sixHours:
            return "6 hours"
        case .twelveHours:
            return "12 hours"
        case .twentyFourHoursDefault, .twentyFourHoursMaximum:
            return "24 hours"
        case .sevenDays:
            return "7 days"
        case .thirtyDays:
            return "30 days"
        }
    }

    private func scheduleSelectedLogRefresh() {
        selectedSessionLogLoadTask?.cancel()
        guard let session = selectedSession else {
            selectedSessionLogViewModels = []
            selectedSessionLogLoadError = nil
            isLoadingSelectedSessionLogs = false
            return
        }
        selectedSessionLogLoadTask = Task {
            await refreshSelectedLogViewModels(for: session)
        }
    }

    private func refreshSelectedLogViewModels(for session: SessionHistorySession) async {
        let sessionID = session.id
        isLoadingSelectedSessionLogs = true
        selectedSessionLogLoadError = nil

        do {
            let records = try await vm.inputOutputLoggingRecords(sessionID: sessionID)
            guard !Task.isCancelled, selectedSession?.id == sessionID else { return }
            selectedSessionLogViewModels = SessionHistoryLogRecordViewModel.matching(records, session: session)
            selectedSessionLogLoadError = nil
        } catch {
            guard !Task.isCancelled, selectedSession?.id == sessionID else { return }
            selectedSessionLogViewModels = []
            selectedSessionLogLoadError = error.localizedDescription
        }

        if selectedSession?.id == sessionID {
            isLoadingSelectedSessionLogs = false
        }
    }

    private func refreshHistory() async {
        // Usage mode renders only the all-time rollup (vm.allTimeUsage); the per-session
        // prompt/output log is not visible there. Reload that only in sessions mode, and
        // bail out before touching selection so usage-mode refresh neither mutates
        // selectedSessionID nor triggers its onChange -> decrypted-log reload path.
        guard selectedViewMode == .sessions else {
            await vm.refreshSessionHistory()
            return
        }
        let previousSelectedSessionID = selectedSessionID
        await vm.refreshSessionHistory()
        if selectedSessionID == nil || !vm.sessionHistorySessions.contains(where: { $0.id == selectedSessionID }) {
            selectedSessionID = vm.sessionHistorySessions.first?.id
        }
        if selectedSessionID == previousSelectedSessionID, let session = selectedSession {
            selectedSessionLogLoadTask?.cancel()
            await refreshSelectedLogViewModels(for: session)
        }
    }
}
