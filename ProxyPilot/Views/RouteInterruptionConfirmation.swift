import AppKit

/// Native menus cannot reliably host SwiftUI confirmation sheets.
@MainActor
enum RouteInterruptionConfirmation {
    static func confirm(route: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Apply and restart \(route)?"
        alert.informativeText = "Requests using this proxy will be interrupted, including other clients. Continue only when you are ready to interrupt them."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Apply & Restart")
        return alert.runModal() == .alertSecondButtonReturn
    }
}
