import XCTest
@testable import ProxyPilot

@MainActor
final class DockTileControllerTests: XCTestCase {
    func testDockTileInstallsForAllBundlesOutsideXCTest() {
        XCTAssertTrue(ProxyPilotDockTileController.shouldInstall(
            bundleIdentifier: "com.example.ProxyPilot",
            environment: [:]
        ))
        XCTAssertTrue(ProxyPilotDockTileController.shouldInstall(
            bundleIdentifier: "com.example.ProxyPilot-alpha",
            environment: [:]
        ))
        XCTAssertFalse(ProxyPilotDockTileController.shouldInstall(
            bundleIdentifier: "com.example.ProxyPilot",
            environment: ["XCTestConfigurationFilePath": "/tmp/tests.xctestconfiguration"]
        ))
    }

    func testModelNameNormalizationUsesLeafAndRemovesExacto() {
        XCTAssertEqual(
            ProxyPilotDockModelName.normalize("anthropic/claude-opus-4.8-thinking:exacto"),
            "CLAUDE-OPUS-4.8-THINKING"
        )
        XCTAssertEqual(ProxyPilotDockModelName.normalize("models/gemini_3.5-pro"), "GEMINI-3.5-PRO")
        XCTAssertEqual(ProxyPilotDockModelName.normalize("  local model 🧪  "), "LOCAL MODEL")
    }

    func testInactivePresentationUsesOrdinaryIconOnly() {
        let presentation = ProxyPilotDockPresentation.derive(
            isListening: false,
            pendingRequestCount: 0,
            activeModels: [],
            lastModelSeen: "gpt-5.6",
            configuredModel: "gpt-5.6",
            hasRecentFailure: false
        )

        XCTAssertEqual(presentation.activity, .inactive)
        XCTAssertEqual(presentation.modelLabel, "")
    }

    func testIdlePresentationUsesLastModelThenConfiguredFallback() {
        let lastModel = ProxyPilotDockPresentation.derive(
            isListening: true,
            pendingRequestCount: 0,
            activeModels: [],
            lastModelSeen: "openai/gpt-5.6",
            configuredModel: "anthropic/claude-sonnet-4.5",
            hasRecentFailure: false
        )
        XCTAssertEqual(lastModel.activity, .idle)
        XCTAssertEqual(lastModel.modelLabel, "GPT-5.6")

        let configuredModel = ProxyPilotDockPresentation.derive(
            isListening: true,
            pendingRequestCount: 0,
            activeModels: [],
            lastModelSeen: "",
            configuredModel: "anthropic/claude-sonnet-4.5",
            hasRecentFailure: false
        )
        XCTAssertEqual(configuredModel.modelLabel, "CLAUDE-SONNET-4.5")
    }

    func testProcessingPresentationUsesAggregateActiveModels() {
        let single = ProxyPilotDockPresentation.derive(
            isListening: true,
            pendingRequestCount: 2,
            activeModels: ["x-ai/grok-build-0.1"],
            lastModelSeen: "",
            configuredModel: "",
            hasRecentFailure: false
        )
        XCTAssertEqual(single.activity, .processing)
        XCTAssertEqual(single.modelLabel, "GROK-BUILD-0.1")

        let multiple = ProxyPilotDockPresentation.derive(
            isListening: true,
            pendingRequestCount: 2,
            activeModels: ["openai/gpt-5.6", "anthropic/claude-opus-4.8"],
            lastModelSeen: "",
            configuredModel: "",
            hasRecentFailure: false
        )
        XCTAssertEqual(multiple.activity, .processing)
        XCTAssertEqual(multiple.modelLabel, ProxyPilotDockPresentation.neutralMultiModelLabel)

        let equivalentAliases = ProxyPilotDockPresentation.derive(
            isListening: true,
            pendingRequestCount: 2,
            activeModels: ["openai/gpt-5.6", "gpt-5.6"],
            lastModelSeen: "",
            configuredModel: "",
            hasRecentFailure: false
        )
        XCTAssertEqual(equivalentAliases.modelLabel, "GPT-5.6")
    }

    func testFailureIsBriefIdleTreatmentAndDoesNotOverrideProcessing() {
        let failed = ProxyPilotDockPresentation.derive(
            isListening: true,
            pendingRequestCount: 0,
            activeModels: [],
            lastModelSeen: "deepseek/deepseek-v4",
            configuredModel: "",
            hasRecentFailure: true
        )
        XCTAssertEqual(failed.activity, .failed)

        let stillProcessing = ProxyPilotDockPresentation.derive(
            isListening: true,
            pendingRequestCount: 1,
            activeModels: ["deepseek/deepseek-v4"],
            lastModelSeen: "",
            configuredModel: "",
            hasRecentFailure: true
        )
        XCTAssertEqual(stillProcessing.activity, .processing)
    }

    func testShortNamesFitAndLongNamesRequireMarqueeWidth() {
        let availableWidth = ProxyPilotDockTileView.signRect.width
            - (ProxyPilotDockTileView.signHorizontalInset * 2)
        XCTAssertLessThanOrEqual(ProxyPilotDockLEDMatrix.textWidth("GPT-5.6"), availableWidth)
        XCTAssertGreaterThan(
            ProxyPilotDockLEDMatrix.textWidth("CLAUDE-OPUS-4.8-THINKING"),
            availableWidth
        )
    }

    func testReduceMotionDisablesAnimation() {
        let processing = ProxyPilotDockPresentation(activity: .processing, modelLabel: "LONG-MODEL-NAME")
        XCTAssertTrue(ProxyPilotDockTileView.shouldAnimate(processing, reduceMotion: false))
        XCTAssertFalse(ProxyPilotDockTileView.shouldAnimate(processing, reduceMotion: true))
        XCTAssertFalse(ProxyPilotDockTileView.shouldAnimate(
            ProxyPilotDockPresentation(activity: .idle, modelLabel: "GPT-5.6"),
            reduceMotion: false
        ))
    }

    func testSquircleMatchesSystemIconRect() {
        let bounds = NSRect(x: 0, y: 0, width: 128, height: 128)
        let iconRect = ProxyPilotDockGeometry.iconRect(in: bounds)
        XCTAssertEqual(iconRect.minX, 12.5, accuracy: 0.001)
        XCTAssertEqual(iconRect.width, 103, accuracy: 0.001)
        let squircle = ProxyPilotDockGeometry.squircle(in: iconRect)
        // The sign must sit entirely inside the icon shape, corners included.
        let sign = ProxyPilotDockTileView.signRect.insetBy(dx: 1, dy: 1)
        for corner in [
            NSPoint(x: sign.minX, y: sign.minY), NSPoint(x: sign.maxX, y: sign.minY),
            NSPoint(x: sign.minX, y: sign.maxY), NSPoint(x: sign.maxX, y: sign.maxY)
        ] {
            XCTAssertTrue(squircle.contains(corner), "sign corner \(corner) falls outside the icon")
        }
    }

    /// Renders every tile state to PNGs for visual review. Skipped unless
    /// PROXYPILOT_DOCK_SNAPSHOT_DIR is set (pass TEST_RUNNER_PROXYPILOT_DOCK_SNAPSHOT_DIR to xcodebuild).
    func testRenderDockTileSnapshotsWhenRequested() throws {
        guard let directory = ProcessInfo.processInfo.environment["PROXYPILOT_DOCK_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set PROXYPILOT_DOCK_SNAPSHOT_DIR to render Dock tile snapshots")
        }
        let view = ProxyPilotDockTileView(frame: NSRect(x: 0, y: 0, width: 128, height: 128))
        let cases: [(String, ProxyPilotDockPresentation, Bool, CGFloat, CGFloat)] = [
            ("inactive", .init(activity: .inactive, modelLabel: ""), false, 0, 0),
            ("idle", .init(activity: .idle, modelLabel: "GLM-5"), false, 0, 0),
            ("failed", .init(activity: .failed, modelLabel: "GLM-5"), false, 0, 0),
            ("processing-p00", .init(activity: .processing, modelLabel: "GPT-5.6"), false, 0, 0),
            ("processing-p25", .init(activity: .processing, modelLabel: "GPT-5.6"), false, 0.25, 0),
            ("processing-p60", .init(activity: .processing, modelLabel: "GEMINI-4-PRO"), false, 0.6, 30),
            ("processing-reduce-motion", .init(activity: .processing, modelLabel: "GEMINI-4-PRO"), true, 0, 0)
        ]
        for (name, presentation, reduceMotion, phase, offset) in cases {
            view.presentation = presentation
            view.reduceMotion = reduceMotion
            view.ringPhase = phase
            view.scrollOffset = offset
            let rep = try XCTUnwrap(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 512, pixelsHigh: 512,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ))
            rep.size = view.bounds.size
            view.cacheDisplay(in: view.bounds, to: rep)
            let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
        view.presentation = .init(activity: .inactive, modelLabel: "")
    }
}
