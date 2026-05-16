import Combine
import Foundation
import Sparkle

@MainActor
enum SoftwareUpdateChannelPolicy {
    static let alphaChannel = "alpha"

    static func allowedChannels(alphaUpdatesEnabled: Bool, isAlphaBuild: Bool) -> Set<String> {
        if alphaUpdatesEnabled || isAlphaBuild {
            return [alphaChannel]
        }
        return []
    }
}

@MainActor
final class SoftwareUpdateService: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published var canCheckForUpdates = false
    @Published var alphaUpdatesEnabled: Bool {
        didSet {
            defaults.set(alphaUpdatesEnabled, forKey: Self.alphaUpdatesEnabledDefaultsKey)
            didRunLaunchBackgroundCheck = false
        }
    }

    static let alphaUpdatesEnabledDefaultsKey = "proxypilot.updates.alphaChannelEnabled"

    private lazy var updaterController: SPUStandardUpdaterController = {
        SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
    }()

    private let defaults: UserDefaults
    private var cancellables: Set<AnyCancellable> = []
    private var didRunLaunchBackgroundCheck = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        alphaUpdatesEnabled = defaults.bool(forKey: Self.alphaUpdatesEnabledDefaultsKey)
        super.init()

        let updater = updaterController.updater
        updater.automaticallyChecksForUpdates = true

        updater.publisher(for: \.canCheckForUpdates)
            .sink { [weak self] canCheck in
                guard let self else { return }
                self.canCheckForUpdates = canCheck
                self.runLaunchBackgroundCheckIfNeeded()
            }
            .store(in: &cancellables)
    }

    func checkForUpdates() {
        updaterController.updater.checkForUpdates()
    }

    func checkForUpdatesInBackground() {
        runLaunchBackgroundCheckIfNeeded()
    }

    nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        MainActor.assumeIsolated {
            SoftwareUpdateChannelPolicy.allowedChannels(
                alphaUpdatesEnabled: alphaUpdatesEnabled,
                isAlphaBuild: AppBuildBadge.current != nil
            )
        }
    }

    private func runLaunchBackgroundCheckIfNeeded() {
        guard !didRunLaunchBackgroundCheck else { return }
        guard canCheckForUpdates else { return }
        didRunLaunchBackgroundCheck = true
        updaterController.updater.checkForUpdatesInBackground()
    }
}
