import Foundation

/// Which route the menu bar's proxy status line and quick actions act on.
///
/// The GUI's reachability probe only knows that *a* ProxyPilot answers on its
/// configured port (`.runningExternal`); it cannot tell an Xcode-launched CLI
/// proxy from the RepoGPS route daemon. Both default to 127.0.0.1:4000, so
/// the generic "Proxy Running" with "Stop Proxy" and "Apply & Restart" sat on
/// top of the RepoGPS route: Stop silently ended it, and Apply & Restart
/// replaced it with the built-in Xcode proxy at the same address.
///
/// The RepoGPS case is recognised only from `route status`: applied (the
/// daemon serves the selected model and alias under a managed PID), owned by
/// the CLI, on the same port the GUI probes. Anything less certain keeps the
/// generic external labels. With RepoGPS routing turned off (RepoGPS not
/// installed) it is also generic, so ProxyPilot-only installs see no RepoGPS
/// wording.
enum MenuBarProxyOwnership: Equatable {
    case stopped
    /// The GUI's built-in proxy, serving the Xcode route.
    case inApp
    /// The CLI daemon serving the RepoGPS route on the GUI's port.
    case repoGPSRoute(port: Int)
    /// Some other ProxyPilot answers on the GUI's port.
    case external
    /// The port answers, but not as ProxyPilot.
    case portOccupied

    enum Action: Equatable {
        case startXcodeProxy
        case stopXcodeProxy
        case restartXcodeProxy
        case stopRepoGPSRoute
        case stopExternalProxy
        case restartExternalProxy
    }

    static func classify(
        runtime: AppViewModel.ProxyRuntimeStatus,
        route: RouteControlService.Status,
        guiPort: Int?,
        repoGPSRoutingEnabled: Bool
    ) -> MenuBarProxyOwnership {
        switch runtime {
        case .stopped:
            return .stopped
        case .portOccupied:
            return .portOccupied
        case .runningInApp:
            return .inApp
        case .runningExternal:
            if repoGPSRoutingEnabled,
               route.applied,
               route.owner == "cli",
               let guiPort,
               route.port == guiPort {
                return .repoGPSRoute(port: route.port)
            }
            return .external
        }
    }

    var isRunning: Bool {
        switch self {
        case .inApp, .repoGPSRoute, .external: return true
        case .stopped, .portOccupied: return false
        }
    }

    var statusTitle: String {
        switch self {
        case .stopped, .portOccupied: return "Proxy Stopped"
        case .inApp: return "Xcode Proxy Running"
        case .repoGPSRoute(let port): return "RepoGPS Route Running · port \(port)"
        case .external: return "Proxy Running"
        }
    }

    /// What quitting ProxyPilot does to the proxy in each state.
    enum QuitCleanup: Equatable {
        /// The GUI's own listener: stop it, as Quit always has.
        case stopInAppProxy
        /// An external proxy (the RepoGPS route or any other CLI daemon):
        /// leave it running.
        case leaveExternalRunning
        case nothingToStop
    }

    /// Quit stops only what this app owns.
    ///
    /// The quit-time stop dates from when `stopProxy()` could only stop the
    /// built-in proxy. Its external branch was added later for the explicit
    /// Stop button, and quitting inherited it, so quitting the GUI ended the
    /// RepoGPS route (and any Xcode-launcher or terminal daemon) on its port.
    /// The GUI never spawns an external daemon, and nothing it can read
    /// proves who did, so every external proxy is left running — not only a
    /// recognised RepoGPS route, which `route status` (refreshed at most every
    /// 30 seconds) could miss.
    var quitCleanup: QuitCleanup {
        switch self {
        case .inApp: return .stopInAppProxy
        case .repoGPSRoute, .external: return .leaveExternalRunning
        case .stopped, .portOccupied: return .nothingToStop
        }
    }

    /// Actions in menu order. A stop that is already in flight hides stops
    /// and restarts, matching `AppViewModel.canStopProxy`.
    func actions(isStoppingCLIProxy: Bool) -> [Action] {
        switch self {
        case .stopped:
            return [.startXcodeProxy]
        case .portOccupied:
            return []
        case .inApp:
            return isStoppingCLIProxy ? [] : [.stopXcodeProxy, .restartXcodeProxy]
        case .repoGPSRoute:
            // No Xcode restart here: it would stop this daemon and start the
            // built-in proxy on the same port, replacing the RepoGPS route.
            return isStoppingCLIProxy ? [] : [.stopRepoGPSRoute]
        case .external:
            return isStoppingCLIProxy ? [] : [.stopExternalProxy, .restartExternalProxy]
        }
    }
}

// MARK: - Shared presentation

/// One vocabulary for every proxy control surface (menu bar, Home strip,
/// Settings toolbar, Xcode sections), so a label or a confirmation cannot
/// drift between them. `MenuBarProxyOwnership` keeps its name from build 172,
/// where the menu bar was its first consumer.
extension MenuBarProxyOwnership.Action {
    enum Confirmation: Equatable {
        /// Restarting interrupts requests; the route named is the one restarted into.
        case restart(route: String)
        /// Stopping interrupts requests and starts nothing.
        case stop(route: String)
    }

    var title: String {
        switch self {
        case .startXcodeProxy: return "Start Xcode Proxy"
        case .stopXcodeProxy: return "Stop Xcode Proxy"
        case .restartXcodeProxy, .restartExternalProxy: return "Apply & Restart"
        case .stopRepoGPSRoute: return "Stop RepoGPS Route"
        case .stopExternalProxy: return "Stop Proxy"
        }
    }

    /// For compact strips and toolbars.
    var compactTitle: String {
        switch self {
        case .startXcodeProxy: return "Start Xcode"
        case .stopXcodeProxy: return "Stop Xcode"
        case .restartXcodeProxy, .restartExternalProxy: return "Restart"
        case .stopRepoGPSRoute: return "Stop RepoGPS"
        case .stopExternalProxy: return "Stop"
        }
    }

    var systemImage: String {
        switch self {
        case .startXcodeProxy: return "play.fill"
        case .restartXcodeProxy, .restartExternalProxy: return "arrow.clockwise"
        case .stopXcodeProxy, .stopRepoGPSRoute, .stopExternalProxy: return "stop.fill"
        }
    }

    var isDestructive: Bool {
        switch self {
        case .stopXcodeProxy, .stopRepoGPSRoute, .stopExternalProxy: return true
        case .startXcodeProxy, .restartXcodeProxy, .restartExternalProxy: return false
        }
    }

    /// The menu's confirmations, applied on every surface.
    var confirmation: Confirmation? {
        switch self {
        case .restartXcodeProxy, .restartExternalProxy: return .restart(route: "the Xcode proxy")
        case .stopRepoGPSRoute: return .stop(route: "the RepoGPS proxy")
        case .startXcodeProxy, .stopXcodeProxy, .stopExternalProxy: return nil
        }
    }
}

extension MenuBarProxyOwnership {
    /// What an Xcode-route section offers. Those sections apply the Xcode
    /// selection, which would stop a serving RepoGPS route and start the
    /// built-in proxy on the same port, so in that state they offer only the
    /// route's own stop, as the menu does.
    enum XcodeSectionControls: Equatable {
        /// Apply/Start the Xcode selection, plus a stop titled for what is running (nil: nothing to stop).
        case xcode(stopTitle: String?)
        case repoGPSRouteServing(port: Int)
    }

    var xcodeSectionControls: XcodeSectionControls {
        switch self {
        case .repoGPSRoute(let port): return .repoGPSRouteServing(port: port)
        case .inApp: return .xcode(stopTitle: MenuBarProxyOwnership.Action.stopXcodeProxy.title)
        case .external: return .xcode(stopTitle: MenuBarProxyOwnership.Action.stopExternalProxy.title)
        case .stopped, .portOccupied: return .xcode(stopTitle: nil)
        }
    }
}
