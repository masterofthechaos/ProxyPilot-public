import SwiftUI

/// Runs a proxy control action the same way on every surface, including the
/// menu's confirmations. Callers decide which actions to show from
/// `MenuBarProxyOwnership.actions(isStoppingCLIProxy:)`.
@MainActor
enum ProxyControlActionRunner {
    static func run(_ action: MenuBarProxyOwnership.Action, vm: AppViewModel) {
        switch action.confirmation {
        case .restart(let route):
            guard RouteInterruptionConfirmation.confirm(route: route) else { return }
        case .stop(let route):
            guard RouteInterruptionConfirmation.confirmStop(route: route) else { return }
        case nil:
            break
        }
        Task {
            switch action {
            case .startXcodeProxy:
                await vm.startProxy()
            case .stopXcodeProxy, .stopExternalProxy:
                await vm.stopProxy()
            case .restartXcodeProxy, .restartExternalProxy:
                await vm.restartProxy()
            case .stopRepoGPSRoute:
                // The existing verified CLI stop (`proxypilot stop --port`);
                // `route.json` keeps the selection for Start RepoGPS Proxy.
                await vm.stopProxy()
                await vm.refreshRouteControlNow()
            }
        }
    }

    /// Starts the selected-but-idle RepoGPS route. Nothing is serving it, so
    /// there is no request to interrupt and no confirmation.
    static func startRepoGPSRoute(vm: AppViewModel) {
        Task { await vm.routeControl.ensureRoute() }
    }
}
