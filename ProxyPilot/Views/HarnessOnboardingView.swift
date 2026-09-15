import AppKit
import SwiftUI

/// The guided introduction to the bundled RepoGPS harness, shown once on the first
/// open after updating to a release that ships it, and reachable afterwards from the
/// sidebar pill or the RepoGPS tab.
///
/// Step copy deliberately reuses `RepoGPSGettingStarted` and the Coding Harnesses
/// wording rather than restating it, so the tour cannot drift from the tab it teaches.
struct HarnessOnboardingStep: Identifiable, Equatable {
    let id: Int
    let title: String
    let systemImage: String
    let summary: String
    let detail: String

    static let all: [HarnessOnboardingStep] = [
        HarnessOnboardingStep(
            id: 0,
            title: "Meet RepoGPS",
            systemImage: "location.north.circle",
            summary: "An optional coding agent for your Terminal workflow.",
            detail: "RepoGPS gives an agent Basecamp orientation, Waypoints, /retrace and /resurface, plus deterministic ALMANAC machinery in Deep Expedition mode. ProxyPilot supplies the model route and an optional cockpit; RepoGPS keeps its own work surface."
        ),
        HarnessOnboardingStep(
            id: 1,
            title: "Install it once",
            systemImage: "arrow.down.circle",
            summary: "ProxyPilot verifies the download and manages RepoGPS updates.",
            detail: "A managed install is atomic and rollback-capable, so a bad update is always reversible. If you already run your own RepoGPS, ProxyPilot leaves it alone until you explicitly adopt it."
        ),
        HarnessOnboardingStep(
            id: 2,
            title: "Open a project",
            systemImage: "terminal",
            summary: "RepoGPS runs in Terminal, not inside this window.",
            detail: "Choose a Git repository and ProxyPilot opens its RepoGPS session in Terminal with the real TTY. Starting RepoGPS does not write anything to your repo — Basecamp orientation is a separate, confirmed command."
        ),
        HarnessOnboardingStep(
            id: 3,
            title: "Watch it fly",
            systemImage: "gauge.with.dots.needle.33percent",
            summary: "Home becomes a live cockpit while a session is running.",
            detail: "During a live session Home shows repository, activity, mode, route, and signal state, and the toolbar carries a RepoGPS badge. You can reopen this tour any time from the RepoGPS tab."
        )
    ]
}

struct HarnessOnboardingView: View {
    @EnvironmentObject private var vm: AppViewModel

    /// Opens the RepoGPS tab behind the sheet once the tour closes.
    let onOpenHarnesses: () -> Void

    @State private var stepIndex = 0

    private var service: RepoGPSService { vm.repoGPS }
    private var steps: [HarnessOnboardingStep] { HarnessOnboardingStep.all }
    private var step: HarnessOnboardingStep { steps[min(stepIndex, steps.count - 1)] }
    private var isLastStep: Bool { stepIndex >= steps.count - 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                Text(step.summary)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)

                Text(step.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                stepAction
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(20)

            Divider()

            footer
        }
        .frame(width: 520, height: 400)
        .task { await service.refresh() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: step.systemImage)
                .font(.title2)
                .foregroundStyle(ProxyPilotBrandPalette.violet)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(step.title)
                    .font(.title3.bold())

                Text("Step \(stepIndex + 1) of \(steps.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            stepDots
        }
        .padding(20)
    }

    private var stepDots: some View {
        HStack(spacing: 6) {
            ForEach(steps) { entry in
                Circle()
                    .fill(entry.id == stepIndex
                          ? AnyShapeStyle(ProxyPilotBrandPalette.violet)
                          : AnyShapeStyle(.quaternary))
                    .frame(width: 6, height: 6)
            }
        }
        .accessibilityHidden(true)
    }

    /// Steps 2 and 3 carry the real action rather than describing it, so the tour
    /// installs and launches instead of sending the reader off to find the button.
    @ViewBuilder
    private var stepAction: some View {
        switch stepIndex {
        case 0:
            // The step-one copy uses RepoGPS's vocabulary; define it in place rather
            // than sending the reader off to look it up.
            GlossaryTermRow(
                terms: RepoGPSGlossary.terms.filter {
                    ["Basecamp", "Waypoint", "Retrace", "Resurface"].contains($0.term)
                },
                caption: "New words? Hover for a one-line meaning, click for the full definition."
            )

        case 1:
            VStack(alignment: .leading, spacing: 8) {
                Text(installStatusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    if service.distribution.ownership == "external" {
                        Text("An independently managed RepoGPS installation was found. Adopt it from the RepoGPS tab when you are ready.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if service.distribution.installed {
                        Label("Installed and ready", systemImage: "checkmark.circle.fill")
                            .font(.callout)
                            .foregroundStyle(.green)
                    } else {
                        Button("Install RepoGPS") {
                            Task { await service.install() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(service.isWorking || service.isInstallingProxyPilotCLI)
                    }
                }

                if let error = service.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

        case 2:
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    chooseRepositoryAndLaunch()
                } label: {
                    Label("Choose Project and Open RepoGPS", systemImage: "terminal.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(service.isWorking || !service.distribution.installed)
                .help("Choose a project folder, then open its RepoGPS session in Terminal")

                if !service.distribution.installed {
                    Text("Install RepoGPS on the previous step to enable this.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(RepoGPSGettingStarted.starterCommand)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        Color(nsColor: .textBackgroundColor).opacity(0.55),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
            }

        default:
            EmptyView()
        }
    }

    private var installStatusText: String {
        switch service.distribution.ownership {
        case "managed":
            let version = service.distribution.currentVersion ?? ""
            return "Managed " + version + " · engine " + (service.distribution.engineReady ? "ready" : "not installed")
        case "external":
            return "External installation detected"
        default:
            return service.bundledVersion.map { "Bundled " + $0 + " · not installed yet" } ?? "Not installed"
        }
    }

    private var footer: some View {
        HStack {
            Button("Skip") {
                vm.finishHarnessOnboarding(completed: false)
            }

            Spacer()

            if stepIndex > 0 {
                Button("Back") {
                    stepIndex -= 1
                }
            }

            Button(isLastStep ? "Open RepoGPS" : "Continue") {
                if isLastStep {
                    vm.finishHarnessOnboarding(completed: true)
                    onOpenHarnesses()
                } else {
                    stepIndex += 1
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(20)
    }

    private func chooseRepositoryAndLaunch() {
        let panel = NSOpenPanel()
        panel.title = "Open RepoGPS"
        panel.message = "Choose the project repository RepoGPS should open."
        panel.prompt = "Open RepoGPS"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let repository = panel.url else { return }
        Task {
            // Advance rather than finish: the next step explains that Home just became
            // the live cockpit, which is exactly what the reader needs at this moment.
            if await service.launch(in: repository), !isLastStep {
                stepIndex += 1
            }
        }
    }
}

/// The sidebar-footer invitation. Stays visible until the tour is actually completed,
/// so skipping the sheet leaves a way back without another modal interruption.
///
/// The shimmer sweeps the app icon's circuit-trail hues. It is suppressed entirely
/// under Reduce Motion, where the pill keeps its brand fill and stays legible.
struct NewFeaturesPill: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let action: () -> Void

    @State private var shimmerPhase: CGFloat = -1.0

    private static let brandGradient = LinearGradient(
        colors: [
            ProxyPilotBrandPalette.pink,
            ProxyPilotBrandPalette.violet,
            ProxyPilotBrandPalette.blueViolet
        ],
        startPoint: .leading,
        endPoint: .trailing
    )

    var body: some View {
        Button(action: action) {
            pillLabel
        }
        .buttonStyle(.plain)
        .help("See what is new in this version of ProxyPilot")
        .accessibilityLabel("New features to explore")
        .accessibilityHint("Opens the RepoGPS harness tour")
        .onAppear(perform: startShimmer)
    }

    // Split out of `body`: as one chained expression the type-checker times out.
    private var pillLabel: some View {
        let content = HStack(spacing: 5) {
            Image(systemName: "sparkles")
                .font(.caption2)

            Text("New features to explore!")
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)

        return content
            .background(pillBackground)
            .overlay(pillShimmer)
            .overlay(pillBorder)
            .clipShape(Capsule())
            .contentShape(Capsule())
    }

    private var pillBackground: some View {
        Capsule().fill(Self.brandGradient.opacity(0.22))
    }

    private var pillBorder: some View {
        Capsule().strokeBorder(Self.brandGradient.opacity(0.55), lineWidth: 1)
    }

    @ViewBuilder
    private var pillShimmer: some View {
        if reduceMotion {
            EmptyView()
        } else {
            shimmerOverlay
        }
    }

    private func startShimmer() {
        guard !reduceMotion else { return }
        withAnimation(.linear(duration: 2.6).repeatForever(autoreverses: false)) {
            shimmerPhase = 2.0
        }
    }

    /// A narrow highlight band swept across the capsule by animating a unit-space offset,
    /// so the effect scales with whatever width the label renders at.
    private var shimmerOverlay: some View {
        GeometryReader { geometry in
            let width = geometry.size.width

            LinearGradient(
                colors: [
                    .clear,
                    ProxyPilotBrandPalette.pink.opacity(0.45),
                    .white.opacity(0.55),
                    ProxyPilotBrandPalette.blueViolet.opacity(0.45),
                    .clear
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: max(width * 0.6, 24))
            .offset(x: shimmerPhase * width)
            .blendMode(.plusLighter)
        }
        .allowsHitTesting(false)
    }
}
