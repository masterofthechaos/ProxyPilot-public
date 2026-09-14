import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let tooltipDelayMilliseconds = 1_000
    private let dockTileController = ProxyPilotDockTileController()
    private var dockTileInteractiveCancellable: AnyCancellable?
    var viewModel: AppViewModel? {
        didSet {
            guard let viewModel else {
                dockTileInteractiveCancellable = nil
                return
            }
            dockTileController.bind(to: viewModel.localProxyState)
            // The Dock Tile is opt-in (default off); install/restore tracks the
            // Appearance settings toggle live, including its value at launch. Also
            // re-syncs on `runInBackground` changes: switching activation policy
            // (accessory ↔ regular) gives the app a new Dock tile representation,
            // so a contentView set while accessory (no visible Dock icon) needs to
            // be re-applied once a real Dock icon exists.
            dockTileInteractiveCancellable = Publishers.CombineLatest(
                viewModel.$dockTileInteractiveEnabled,
                viewModel.$runInBackground
            )
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled, _ in
                if enabled {
                    self?.dockTileController.installIfEligible()
                } else {
                    self?.dockTileController.restoreDefaultIcon()
                }
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // AppKit reads this app-domain default for native tooltips created by SwiftUI `.help`.
        UserDefaults.standard.set(Self.tooltipDelayMilliseconds, forKey: "NSInitialToolTipDelay")

        // Install from the persisted preference immediately, since `viewModel` isn't
        // assigned until the settings WindowGroup's onAppear runs (which may be later,
        // or never if the window doesn't auto-open). The $dockTileInteractiveEnabled
        // subscription above takes over for live toggling once viewModel is set.
        if UserDefaults.standard.bool(forKey: AppViewModel.dockTileInteractiveEnabledDefaultsKey) {
            dockTileController.installIfEligible()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let viewModel else { return .terminateNow }

        if viewModel.shouldPromptBeforeQuit() {
            let alert = NSAlert()
            alert.messageText = String(localized: "Xcode Agent Config Is Still Installed")
            alert.informativeText = String(localized: "Xcode's Claude Agent is routed through ProxyPilot. If you quit without removing, Xcode Agent won't work until you revert manually or reopen ProxyPilot.")
            alert.alertStyle = .warning
            alert.addButton(withTitle: String(localized: "Remove & Quit"))
            alert.addButton(withTitle: String(localized: "Keep & Quit"))
            if alert.runModal() == .alertFirstButtonReturn {
                viewModel.removeXcodeAgentConfig()
            }
        }

        Task { @MainActor in
            await viewModel.stopProxy()
            await viewModel.applicationWillTerminate()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        dockTileController.restoreDefaultIcon()
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
                Divider()
                Button("Slicewrite Studio") {
                    NSWorkspace.shared.open(SlicewriteStudioBrand.websiteURL)
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
