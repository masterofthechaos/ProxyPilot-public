import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    var viewModel: AppViewModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let viewModel, viewModel.shouldPromptBeforeQuit() else {
            return .terminateNow
        }

        let alert = NSAlert()
        alert.messageText = String(localized: "Xcode Agent Config Is Still Installed")
        alert.informativeText = String(localized: "Xcode's Claude Agent is routed through ProxyPilot. If you quit without removing, Xcode Agent won't work until you revert manually or reopen ProxyPilot.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Remove & Quit"))
        alert.addButton(withTitle: String(localized: "Keep & Quit"))

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            Task { @MainActor in
                viewModel.removeXcodeAgentConfig()
            }
        }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard let viewModel else { return }
        Task { @MainActor in
            await viewModel.stopProxy()
        }
        viewModel.applicationWillTerminate()
    }
}

@main
struct ProxyPilotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var viewModel = AppViewModel()
    @StateObject private var softwareUpdateService = SoftwareUpdateService()

    var body: some Scene {
        WindowGroup(id: "settings") {
            ContentView()
                .environmentObject(viewModel)
                .environmentObject(softwareUpdateService)
                .onAppear {
                    appDelegate.viewModel = viewModel
                    viewModel.refreshAgentConfigInstallationState()
                    softwareUpdateService.checkForUpdatesInBackground()
                }
        }
        .windowStyle(.automatic)

        MenuBarExtra {
            MenuBarView()
                .environmentObject(viewModel)
                .environmentObject(softwareUpdateService)
        } label: {
            Image(systemName: viewModel.isRunning ? "network" : "network.slash")
                .accessibilityLabel(viewModel.isRunning ? "ProxyPilot status running" : "ProxyPilot status stopped")
        }
        .menuBarExtraStyle(.menu)
        .commands {
            CommandGroup(replacing: .help) {
                Button("ProxyPilot README") {
                    viewModel.openReadme()
                }
                Button("ProxyPilot Website") {
                    viewModel.openWebsite()
                }
            }
        }
    }
}
