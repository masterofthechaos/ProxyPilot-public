import AppKit
import SwiftUI

struct RepoGPSGettingStartedCommand: Identifiable, Equatable {
    let title: String
    let command: String
    let explanation: String

    var id: String { command }
}

enum RepoGPSGettingStarted {
    static let executable = "~/.repogps/bin/rgps"
    static let starterCommand = "cd /path/to/your/project\n\(executable)"

    static let commands = [
        RepoGPSGettingStartedCommand(
            title: "Start here",
            command: starterCommand,
            explanation: "Open Terminal, enter your project folder, then start the RepoGPS TUI."
        ),
        RepoGPSGettingStartedCommand(
            title: "Choose a repository directly",
            command: "\(executable) --dir /path/to/your/project",
            explanation: "Starts the same terminal workspace without changing folders first."
        ),
        RepoGPSGettingStartedCommand(
            title: "Look around without changing the repo",
            command: "\(executable) orient --mode quick",
            explanation: "Quick Look reports repository and Git state. It does not create Basecamp files."
        ),
        RepoGPSGettingStartedCommand(
            title: "Establish Basecamp",
            command: "\(executable) orient --mode standard",
            explanation: "After one confirmation, creates only missing guidance and Waypoint files and gives you a rollback receipt."
        ),
        RepoGPSGettingStartedCommand(
            title: "Add deterministic instrumentation",
            command: "\(executable) orient --mode deep",
            explanation: "Adds the Standard foundation plus deterministic ALMANAC and Waypoint machinery."
        ),
    ]
}

struct CodingHarnessesView: View {
    @EnvironmentObject private var vm: AppViewModel
    @State private var confirmAdoption = false
    @State private var copiedCommand: String?

    let onOpenHome: () -> Void

    private var service: RepoGPSService { vm.repoGPS }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    Text("RepoGPS").font(.title2.weight(.semibold))

                    Spacer()

                    // Deliberately outside the installed-state gate below: the tour is
                    // most useful before RepoGPS is installed.
                    Button {
                        vm.openHarnessOnboarding(surface: "harnesses_tab")
                    } label: {
                        Label("Take the Tour", systemImage: "sparkles")
                    }
                    .help("Replay the RepoGPS introduction")
                }

                Text("Optional coding in Terminal, with providers and models supplied by ProxyPilot. You do not need RepoGPS to use ProxyPilot Agent in Xcode.")
                    .foregroundStyle(.secondary)

                DashboardCard {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("RepoGPS").font(.headline)
                                Text(statusText).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            statusBadge
                        }

                        Text("A terminal coding harness with Basecamp orientation, Waypoints, /retrace and /resurface, plus deterministic ALMANAC machinery in Deep Expedition mode.")
                            .font(.callout).foregroundStyle(.secondary)

                        HStack {
                            if service.distribution.ownership == "external" {
                                Button("Adopt and Install") { confirmAdoption = true }
                            } else if !service.distribution.installed {
                                Button("Install RepoGPS") { Task { await service.install() } }
                                    .buttonStyle(.borderedProminent)
                            } else if service.remoteUpdateAvailable {
                                Button("Update to " + (service.updateStatus?.latestVersion ?? "Latest")) {
                                    Task { await service.install() }
                                }
                                .buttonStyle(.borderedProminent)
                            } else if service.bundledUpdateAvailable {
                                Button("Install Bundled Update") { Task { await service.install() } }
                            } else {
                                Button("Repair") { Task { await service.repair() } }
                            }
                            if service.distribution.ownership == "managed" {
                                if service.distribution.previousVersion != nil {
                                    Button("Roll Back") { Task { await service.rollback() } }
                                }
                                Button("Remove", role: .destructive) { Task { await service.remove() } }
                            }
                            Spacer()
                            if service.distribution.ownership == "managed" {
                                Button {
                                    Task { await service.checkForUpdates() }
                                } label: {
                                    Label(service.isCheckingForUpdates ? "Checking…" : "Check for Updates", systemImage: "arrow.clockwise")
                                }
                                .buttonStyle(.borderless)
                                .disabled(service.isCheckingForUpdates)
                            }
                            versionSummary
                        }
                        .disabled(service.isWorking || service.isInstallingProxyPilotCLI)

                        if let receipt = service.lastReceipt { Text(receipt).font(.caption).foregroundStyle(.green) }
                        if let error = service.lastError { Text(error).font(.caption).foregroundStyle(.orange) }
                    }
                }

                if service.distribution.installed {
                    gettingStartedCard
                    commandGuideCard
                }

                glossaryCard
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .task {
            await service.refresh()
            await service.checkForUpdates(force: false, reportFailure: false)
        }
        .alert("Adopt Existing RepoGPS?", isPresented: $confirmAdoption) {
            Button("Cancel", role: .cancel) {}
            Button("Adopt and Install") { Task { await service.install(adoptExternal: true) } }
        } message: {
            Text("ProxyPilot will preserve the existing target as a rollback receipt, then take responsibility for the stable RepoGPS command.")
        }
    }

    private var statusText: String {
        switch service.distribution.ownership {
        case "managed":
            return "Managed " + (service.distribution.currentVersion ?? "") + " · engine " + (service.distribution.engineReady ? "ready" : "not installed")
        case "external": return "An independently managed RepoGPS installation was found."
        default: return "Not installed"
        }
    }

    private var statusBadge: some View {
        Text(service.updateAvailable ? "Update Available" : (service.distribution.ownership == "managed" ? "Installed" : service.distribution.ownership.capitalized))
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(.quaternary, in: Capsule())
    }

    @ViewBuilder private var versionSummary: some View {
        if let latest = service.updateStatus?.latestVersion,
           latest != service.bundledVersion {
            Text("Latest \(latest) · Bundled \(service.bundledVersion ?? "unknown")")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        } else if let version = service.bundledVersion {
            Text("Bundled " + version)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    /// Two ways to start, presented as alternatives. They were previously stacked as
    /// peers, which read as two required steps — a button *and* a command to run.
    private var gettingStartedCard: some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Start RepoGPS", systemImage: "terminal.fill")
                        .font(.headline)

                    Text("RepoGPS is a terminal coding workspace, not another window inside ProxyPilot. Pick either way below — you do not need both. While it runs, Home becomes the in-flight cockpit.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Let ProxyPilot open it")
                        .font(.subheadline.weight(.semibold))

                    Button {
                        chooseRepositoryAndLaunch()
                    } label: {
                        Label("Choose Project and Open RepoGPS", systemImage: "terminal.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(service.isWorking)
                    .help("Choose a project folder, then open its RepoGPS session in Terminal")

                    Text("Opens Terminal at the project you choose and starts RepoGPS there.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                orDivider

                VStack(alignment: .leading, spacing: 10) {
                    Text("Start it yourself in Terminal")
                        .font(.subheadline.weight(.semibold))

                    commandBox(RepoGPSGettingStarted.commands[0])
                    commandBox(RepoGPSGettingStarted.commands[1])
                }

                Divider()

                Text("Either way, starting RepoGPS writes nothing to your repository. Orientation is separate and optional — see below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var orDivider: some View {
        HStack(spacing: 10) {
            VStack { Divider() }
            Text("or")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
            VStack { Divider() }
        }
        .accessibilityHidden(true)
    }

    /// Orientation modes only. The "choose a repository directly" variant moved up into
    /// the start card, where it belongs as an alternative rather than a follow-on step.
    private var commandGuideCard: some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Orientation (optional)").font(.headline)
                    Text("RepoGPS works without these. Run one when you want it to establish or deepen its bearings in a repository; Standard and Deep confirm before writing anything.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ForEach(Array(RepoGPSGettingStarted.commands.dropFirst(2).enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Divider() }
                    commandBox(item)
                }

                HStack {
                    Image(systemName: "questionmark.circle")
                    Text("For the complete command list, run `rgps help`.")
                    Spacer()
                    Button("Copy") { copy("rgps help") }
                        .buttonStyle(.borderless)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var glossaryCard: some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("RepoGPS Vocabulary").font(.headline)
                    Text("Inside the RepoGPS session, `/retrace` and `/resurface` are the two commands you will reach for most.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                GlossaryTermRow()
            }
        }
    }

    private func commandBox(_ item: RepoGPSGettingStartedCommand, prominent: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.title)
                    .font(prominent ? .callout.weight(.semibold) : .caption.weight(.semibold))
                Spacer()
                Button {
                    copy(item.command)
                } label: {
                    Label(copiedCommand == item.command ? "Copied" : "Copy", systemImage: copiedCommand == item.command ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderless)
            }

            Text(item.command)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.55), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            Text(item.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func copy(_ command: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        copiedCommand = command
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
            if await service.launch(in: repository) {
                onOpenHome()
            }
        }
    }
}
