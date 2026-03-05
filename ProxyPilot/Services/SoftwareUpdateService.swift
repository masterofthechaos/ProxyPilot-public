import Combine
import Foundation
import Sparkle

@MainActor
final class SoftwareUpdateService: ObservableObject {
    @Published var canCheckForUpdates = false

    private let updaterController: SPUStandardUpdaterController
    private var cancellables: Set<AnyCancellable> = []
    private var didRunLaunchBackgroundCheck = false

    init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        updaterController.updater.automaticallyChecksForUpdates = true

        updaterController.updater.publisher(for: \.canCheckForUpdates)
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

    private func runLaunchBackgroundCheckIfNeeded() {
        guard !didRunLaunchBackgroundCheck else { return }
        guard canCheckForUpdates else { return }
        didRunLaunchBackgroundCheck = true
        updaterController.updater.checkForUpdatesInBackground()
    }
}
