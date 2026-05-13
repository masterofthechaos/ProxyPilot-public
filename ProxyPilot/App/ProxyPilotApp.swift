import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let tooltipDelayMilliseconds = 1_000
    var viewModel: AppViewModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // AppKit reads this app-domain default for native tooltips created by SwiftUI `.help`.
        UserDefaults.standard.set(Self.tooltipDelayMilliseconds, forKey: "NSInitialToolTipDelay")
    }

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
                .preferredColorScheme(viewModel.appearancePreference.colorScheme)
                .onAppear {
                    appDelegate.viewModel = viewModel
                    viewModel.refreshAgentConfigInstallationState()
                    softwareUpdateService.checkForUpdatesInBackground()
                }
        }
        .windowStyle(.automatic)
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

        MenuBarExtra(isInserted: Binding(
            get: { viewModel.showMenuBarExtra },
            set: { isInserted in
                guard viewModel.showMenuBarExtra != isInserted else { return }
                viewModel.showMenuBarExtra = isInserted
            }
        )) {
            MenuBarView()
                .environmentObject(viewModel)
                .environmentObject(softwareUpdateService)
                .preferredColorScheme(viewModel.appearancePreference.colorScheme)
        } label: {
            Image(systemName: viewModel.isRunning ? "network" : "network.slash")
                .accessibilityLabel(viewModel.isRunning ? "ProxyPilot status running" : "ProxyPilot status stopped")
        }
        .menuBarExtraStyle(.menu)
    }
}
