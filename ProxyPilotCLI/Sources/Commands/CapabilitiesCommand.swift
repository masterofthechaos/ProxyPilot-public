import ArgumentParser
import Foundation

struct CapabilitiesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "capabilities", abstract: "Report machine-readable integration contract versions.")
    @Flag(name: .long) var json = false
    func run() throws {
        let payload: [String: Int] = [
            "route_control": 2,
            "active_model_aliasing": 1,
            "request_attribution": 2,
            "session_storage": 2,
            "independent_request": 1,
            "route_metadata": 1,
            "attributed_usage": 2,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
