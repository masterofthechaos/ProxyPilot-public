import SwiftUI
import ProxyPilotCore

/// Proxy-tab section for the Active Context Compaction (ACCA) opt-in.
struct ContextCompactionSettingsView: View {
    @EnvironmentObject private var vm: AppViewModel

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Enable Active Context Compaction", isOn: Binding(
                    get: { vm.contextCompactionEnabled },
                    set: { vm.contextCompactionEnabled = $0 }
                ))
                .toggleStyle(.switch)

                helperText("When ACCA is enabled, ProxyPilot attempts to shrink context bloat from the Xcode agent by passing a condensed version of Xcode's context instructions to the upstream model. This may improve time-to-first-token and latency for local inference.")

                helperText("**Applies only to local providers (Ollama, LM Studio).** Your own messages and tool definitions are never modified, and unrecognized instructions are always forwarded unchanged. Takes effect the next time the proxy starts.", markdown: true)

                if vm.contextCompactionEnabled && !currentProviderSupportsCompaction {
                    Text(verbatim: String(localized: "Not active for") + " " + vm.upstreamProviderDisplayTitle + ".")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                ContextCompactionStatsLine(state: vm.localProxyState)
            }
            .padding(.vertical, 4)
        } header: {
            HStack(spacing: 8) {
                Text("Active Context Compaction")
                Text("Beta")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.16), in: Capsule())
                    .foregroundStyle(.orange)
            }
        }
    }

    private var currentProviderSupportsCompaction: Bool {
        vm.hasSelectedProvider && !vm.hasActiveCustomProvider && vm.upstreamProvider.supportsContextCompaction
    }

    private func helperText(_ text: String, markdown: Bool = false) -> some View {
        Group {
            if markdown, let attributed = try? AttributedString(markdown: text) {
                Text(attributed)
            } else {
                Text(text)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ContextCompactionStatsLine: View {
    @ObservedObject var state: LocalProxyState

    var body: some View {
        if let stat = state.lastContextCompaction {
            Text(verbatim: String(localized: "Last request:") + " " + statText(stat))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func statText(_ stat: ContextCompactionStat) -> String {
        let original = LocalProxyServerHelpers.formatByteCount(stat.originalBytes)
        let compacted = LocalProxyServerHelpers.formatByteCount(stat.compactedBytes)
        // Rough chars/4 heuristic — good enough for a relative savings hint.
        let originalTokens = stat.originalBytes / 4
        let compactedTokens = stat.compactedBytes / 4
        return "\(original) → \(compacted) (≈\(formatTokens(originalTokens)) → \(formatTokens(compactedTokens)) tokens, estimated)"
    }

    private func formatTokens(_ tokens: Int) -> String {
        guard tokens >= 1000 else { return "\(tokens)" }
        return String(format: "%.1fk", Double(tokens) / 1000.0)
    }
}
