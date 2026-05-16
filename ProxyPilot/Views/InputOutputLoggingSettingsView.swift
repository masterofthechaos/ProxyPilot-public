import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct InputOutputLoggingSettingsView: View {
    @EnvironmentObject private var vm: AppViewModel
    @State private var showPrivacyWarning = false
    @State private var showDeleteLogsConfirmation = false
    @State private var settingsExpanded = true
    @State private var isExportingLogs = false
    @State private var loggingExportStatus = ""

    let onOpenProxySettings: () -> Void

    var body: some View {
        Section {
            introCopy

            VStack(alignment: .leading, spacing: 12) {
                Toggle("Record Inputs and Outputs", isOn: Binding(
                    get: { vm.inputOutputLoggingEnabled },
                    set: { enabled in
                        if enabled {
                            showPrivacyWarning = true
                        } else {
                            vm.disableInputOutputLogging()
                        }
                    }
                ))
                .toggleStyle(.switch)

                helperText("By default, ProxyPilot does not save or record the content of your inputs or outputs, even in diagnostic files. Recording may improve debugging, but can increase overhead during long sessions and pose privacy risks.")

                helperText("**Recorded prompts and outputs are encrypted while stored by ProxyPilot and are deleted after a maximum of 24 hours.** You can export them manually if you wish to keep them longer than that. ProxyPilot never includes any prompt data in diagnostic telemetry.", markdown: true)

                if vm.inputOutputLoggingEnabled {
                    DisclosureGroup(isExpanded: $settingsExpanded) {
                        loggingOptions
                    } label: {
                        Text("Logging settings")
                            .font(.subheadline.weight(.semibold))
                    }
                }
            }
            .padding(.vertical, 4)
        } header: {
            HStack(spacing: 8) {
                Text("Input & Output Logging")
                Text("Beta")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.16), in: Capsule())
                    .foregroundStyle(.orange)
            }
        }
        .sheet(isPresented: $showPrivacyWarning) {
            privacyWarningSheet
        }
        .confirmationDialog(
            "Delete saved input and output logs?",
            isPresented: $showDeleteLogsConfirmation
        ) {
            Button("Delete saved logs", role: .destructive) {
                deleteSavedLogs()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This removes ProxyPilot's encrypted saved input/output records. It does not change logging settings.")
        }
    }

    private var introCopy: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("This feature is off by default. ProxyPilot only transmits your requests to and from the provider you choose in Proxy.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("Review provider routing in")
                    .foregroundStyle(.secondary)
                Button("Proxy settings") {
                    onOpenProxySettings()
                }
                .buttonStyle(.link)
                .accessibilityLabel("Open Proxy settings")
                Text("before enabling logging.")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)

            Text("Enabling input and output logging lets you securely save your prompts and model outputs. They remain on-device unless you export and share them.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }

    private var loggingOptions: some View {
        VStack(alignment: .leading, spacing: 18) {
            loggingGroup(
                title: "Choose What to Log",
                helper: "You can choose inputs, outputs, or both. Un-selecting both disables this feature. Settings apply to this app and ProxyPilot CLI."
            ) {
                loggingToggle(
                    title: "Record Inputs",
                    isOn: Binding(
                        get: { vm.inputOutputLoggingRecordInputs },
                        set: { vm.setInputOutputRecordInputs($0) }
                    ),
                    helper: "Saves prompts sent while ProxyPilot is configured and running."
                )

                loggingToggle(
                    title: "Record Outputs",
                    isOn: Binding(
                        get: { vm.inputOutputLoggingRecordOutputs },
                        set: { vm.setInputOutputRecordOutputs($0) }
                    ),
                    helper: "Saves full outputs returned to \(vm.proxyURLString). The telemetry dashboard may parse outputs for token usage, pricing, and request counts, but it never saves output content."
                )
            }

            loggingGroup(title: "Scope & Duration") {
                loggingToggle(
                    title: "Enable logging for ProxyPilot CLI?",
                    isOn: Binding(
                        get: { vm.inputOutputLoggingCLIEnabled },
                        set: { vm.inputOutputLoggingCLIEnabled = $0 }
                    ),
                    helper: "Save full input and output logging for traffic through ProxyPilot CLI. Logged inputs and outputs are only accessible via the GUI while this feature is in beta, regardless of how they're captured."
                )

                saveDurationSelector
            }

            loggingGroup(title: "Storage") {
                saveLocationOptions
                savedLogActions
                importantHelperText
            }
        }
        .padding(.top, 10)
    }

    private func loggingGroup<Content: View>(
        title: String,
        helper: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                if let helper {
                    helperText(helper)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                content()
            }
        }
    }

    private func loggingToggle(title: String, isOn: Binding<Bool>, helper: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(title, isOn: isOn)
                .toggleStyle(.switch)
            helperText(helper)
        }
    }

    private var saveDurationSelector: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Save duration", selection: Binding(
                get: { vm.inputOutputLoggingRetention },
                set: { vm.inputOutputLoggingRetention = $0 }
            )) {
                ForEach(InputOutputLoggingRetention.allCases) { duration in
                    Text(duration.title).tag(duration)
                }
            }
            .pickerStyle(.menu)

            helperText(vm.inputOutputLoggingRetention.helperText)
        }
    }

    private var saveLocationOptions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Store inputs and outputs outside of ProxyPilot", isOn: Binding(
                get: { vm.inputOutputLoggingExternalStorageEnabled },
                set: { _ in vm.inputOutputLoggingExternalStorageEnabled = false }
            ))
            .toggleStyle(.switch)
            .disabled(true)

            Button("Choose save location") { }
                .disabled(true)

            helperText("Custom save locations are not available in this beta. Use manual export if you need to keep saved logs permanently.")
        }
    }

    private var savedLogActions: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button("Export saved logs...") {
                    exportSavedLogs()
                }
                .disabled(isExportingLogs)

                Button("Delete saved logs") {
                    showDeleteLogsConfirmation = true
                }
                .disabled(isExportingLogs)
            }

            helperText("Manual exports include decrypted prompt and output content. Keep exported files somewhere you trust.")

            if !loggingExportStatus.isEmpty {
                Text(loggingExportStatus)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private var importantHelperText: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("**Important:** When you enable logging of inputs and/or outputs, ProxyPilot encrypts them while they're at rest and keeps the encryption key in your macOS Keychain.")
            Text("**Manual exports are decrypted files. ProxyPilot does not automatically delete exported copies.**")
            Text("**It is recommended to keep your saved inputs/outputs securely in ProxyPilot's storage and to export them manually if you wish to save them permanently.**")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func helperText(_ text: String, markdown: Bool = false) -> some View {
        renderedHelperText(text, markdown: markdown)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func renderedHelperText(_ text: String, markdown: Bool) -> Text {
        guard markdown, let attributed = try? AttributedString(markdown: text) else {
            return Text(text)
        }

        return Text(attributed)
    }

    private var privacyWarningSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.thinMaterial)
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(.white.opacity(0.36), lineWidth: 1)
                        }
                        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
                        .shadow(color: .white.opacity(0.22), radius: 1, x: -1, y: -1)

                    Image(systemName: "hand.raised.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(privacyGlyphGradient)
                        .accessibilityHidden(true)
                }
                .frame(width: 58, height: 58)

                Text("Privacy Warning")
                    .font(.title.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 2)

            VStack(alignment: .leading, spacing: 10) {
                Text("Enabling Input & Output Recording will save the full content of your prompts and/or LLM outputs. These may contain your proprietary code or sensitive information.\n\nBy default, ProxyPilot will securely store inputs and outputs, deleting after 24 hours.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Go back") {
                    showPrivacyWarning = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button {
                    vm.confirmInputOutputLoggingEnabled()
                    settingsExpanded = true
                    showPrivacyWarning = false
                } label: {
                    Text("Enable logging")
                        .frame(minWidth: 118)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 460)
    }

    private var privacyGlyphGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(.displayP3, red: 98.0 / 255.0, green: 166.0 / 255.0, blue: 248.0 / 255.0),
                Color(.displayP3, red: 59.0 / 255.0, green: 134.0 / 255.0, blue: 237.0 / 255.0)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private func exportSavedLogs() {
        isExportingLogs = true
        loggingExportStatus = "Preparing saved logs..."

        Task { @MainActor in
            defer { isExportingLogs = false }

            do {
                let jsonl = try await vm.inputOutputLoggingExportJSONL()
                guard !jsonl.isEmpty else {
                    loggingExportStatus = "No saved input/output logs to export."
                    return
                }

                let formatter = DateFormatter()
                formatter.dateFormat = "yyyyMMdd-HHmmss"
                let suggestedName = "proxypilot-input-output-logs-\(formatter.string(from: Date())).jsonl"

                let panel = NSSavePanel()
                panel.title = "Export Input & Output Logs"
                panel.nameFieldStringValue = suggestedName
                panel.allowedContentTypes = [UTType(filenameExtension: "jsonl") ?? .json]
                panel.canCreateDirectories = true
                panel.isExtensionHidden = false

                guard panel.runModal() == .OK, let url = panel.url else {
                    loggingExportStatus = ""
                    return
                }

                try jsonl.write(to: url, atomically: true, encoding: .utf8)
                let count = try await vm.inputOutputLoggingSavedRecordCount()
                loggingExportStatus = "Exported \(count) saved log record\(count == 1 ? "" : "s") to \(url.path)"
            } catch {
                loggingExportStatus = "Log export failed: \(error.localizedDescription)"
            }
        }
    }

    private func deleteSavedLogs() {
        isExportingLogs = true
        loggingExportStatus = "Deleting saved logs..."

        Task { @MainActor in
            defer { isExportingLogs = false }

            do {
                try await vm.deleteInputOutputLoggingRecords()
                loggingExportStatus = "Deleted saved input/output logs."
            } catch {
                loggingExportStatus = "Could not delete saved logs: \(error.localizedDescription)"
            }
        }
    }
}
