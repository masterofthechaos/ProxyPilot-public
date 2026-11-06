import AppKit
import Combine
import QuartzCore
import SwiftUI

enum ProxyPilotDockActivity: Equatable {
    case inactive
    case idle
    case processing
    case failed
}

struct ProxyPilotDockPresentation: Equatable {
    static let neutralMultiModelLabel = "MULTI MODEL"
    static let readyLabel = "READY"

    let activity: ProxyPilotDockActivity
    let modelLabel: String

    static func derive(
        isListening: Bool,
        pendingRequestCount: Int,
        activeModels: Set<String>,
        lastModelSeen: String,
        configuredModel: String,
        hasRecentFailure: Bool
    ) -> Self {
        guard isListening else {
            return Self(activity: .inactive, modelLabel: "")
        }

        if pendingRequestCount > 0 {
            let normalizedActiveModels = Set(
                activeModels
                    .map(ProxyPilotDockModelName.normalize)
                    .filter { !$0.isEmpty }
            )
            let label: String
            if normalizedActiveModels.count > 1 {
                label = neutralMultiModelLabel
            } else if let activeModel = normalizedActiveModels.first {
                label = activeModel
            } else {
                label = ProxyPilotDockModelName.normalize(lastModelSeen)
            }
            return Self(
                activity: .processing,
                modelLabel: label.isEmpty ? readyLabel : label
            )
        }

        let normalizedLastModel = ProxyPilotDockModelName.normalize(lastModelSeen)
        let normalizedConfiguredModel = ProxyPilotDockModelName.normalize(configuredModel)
        let label = normalizedLastModel.isEmpty ? normalizedConfiguredModel : normalizedLastModel
        return Self(
            activity: hasRecentFailure ? .failed : .idle,
            modelLabel: label.isEmpty ? readyLabel : label
        )
    }
}

enum ProxyPilotDockModelName {
    static let maximumInputCharacters = 256
    static let maximumLabelCharacters = 32

    static func normalize(_ rawValue: String) -> String {
        var value = String(rawValue.prefix(maximumInputCharacters))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "" }

        if value.lowercased().hasSuffix(":exacto") {
            value.removeLast(":exacto".count)
        }
        if let leaf = value.split(separator: "/", omittingEmptySubsequences: true).last {
            value = String(leaf)
        }

        value = value
            .replacingOccurrences(of: "_", with: "-")
            .uppercased()

        let supported = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._:+ ")
        value = String(value.map { supported.contains($0) ? $0 : " " })
        let normalized = value
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return String(normalized.prefix(maximumLabelCharacters))
    }
}

enum ProxyPilotDockLEDMatrix {
    static let dotPitch: CGFloat = 1.8
    static let dotDiameter: CGFloat = 1.4
    static let glyphAdvance: CGFloat = dotPitch * 6
    /// Height of one 7-row glyph, from the bottom of the lowest dot to the top of the highest.
    static let glyphHeight: CGFloat = (dotPitch * 6) + dotDiameter

    static func textWidth(_ text: String) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        return (CGFloat(text.count) * glyphAdvance) - dotPitch
    }

    static func rows(for character: Character) -> [String] {
        glyphs[character] ?? glyphs["?"]!
    }

    private static let glyphs: [Character: [String]] = [
        " ": ["00000", "00000", "00000", "00000", "00000", "00000", "00000"],
        "?": ["01110", "10001", "00001", "00010", "00100", "00000", "00100"],
        "A": ["01110", "10001", "10001", "11111", "10001", "10001", "10001"],
        "B": ["11110", "10001", "10001", "11110", "10001", "10001", "11110"],
        "C": ["01111", "10000", "10000", "10000", "10000", "10000", "01111"],
        "D": ["11110", "10001", "10001", "10001", "10001", "10001", "11110"],
        "E": ["11111", "10000", "10000", "11110", "10000", "10000", "11111"],
        "F": ["11111", "10000", "10000", "11110", "10000", "10000", "10000"],
        "G": ["01111", "10000", "10000", "10111", "10001", "10001", "01111"],
        "H": ["10001", "10001", "10001", "11111", "10001", "10001", "10001"],
        "I": ["11111", "00100", "00100", "00100", "00100", "00100", "11111"],
        "J": ["00111", "00010", "00010", "00010", "10010", "10010", "01100"],
        "K": ["10001", "10010", "10100", "11000", "10100", "10010", "10001"],
        "L": ["10000", "10000", "10000", "10000", "10000", "10000", "11111"],
        "M": ["10001", "11011", "10101", "10101", "10001", "10001", "10001"],
        "N": ["10001", "11001", "10101", "10011", "10001", "10001", "10001"],
        "O": ["01110", "10001", "10001", "10001", "10001", "10001", "01110"],
        "P": ["11110", "10001", "10001", "11110", "10000", "10000", "10000"],
        "Q": ["01110", "10001", "10001", "10001", "10101", "10010", "01101"],
        "R": ["11110", "10001", "10001", "11110", "10100", "10010", "10001"],
        "S": ["01111", "10000", "10000", "01110", "00001", "00001", "11110"],
        "T": ["11111", "00100", "00100", "00100", "00100", "00100", "00100"],
        "U": ["10001", "10001", "10001", "10001", "10001", "10001", "01110"],
        "V": ["10001", "10001", "10001", "10001", "10001", "01010", "00100"],
        "W": ["10001", "10001", "10001", "10101", "10101", "10101", "01010"],
        "X": ["10001", "10001", "01010", "00100", "01010", "10001", "10001"],
        "Y": ["10001", "10001", "01010", "00100", "00100", "00100", "00100"],
        "Z": ["11111", "00001", "00010", "00100", "01000", "10000", "11111"],
        "0": ["01110", "10001", "10011", "10101", "11001", "10001", "01110"],
        "1": ["00100", "01100", "00100", "00100", "00100", "00100", "01110"],
        "2": ["01110", "10001", "00001", "00010", "00100", "01000", "11111"],
        "3": ["11110", "00001", "00001", "01110", "00001", "00001", "11110"],
        "4": ["00010", "00110", "01010", "10010", "11111", "00010", "00010"],
        "5": ["11111", "10000", "10000", "11110", "00001", "00001", "11110"],
        "6": ["01110", "10000", "10000", "11110", "10001", "10001", "01110"],
        "7": ["11111", "00001", "00010", "00100", "01000", "01000", "01000"],
        "8": ["01110", "10001", "10001", "01110", "10001", "10001", "01110"],
        "9": ["01110", "10001", "10001", "01111", "00001", "00001", "01110"],
        "-": ["00000", "00000", "00000", "11111", "00000", "00000", "00000"],
        ".": ["00000", "00000", "00000", "00000", "00000", "01100", "01100"],
        ":": ["00000", "01100", "01100", "00000", "01100", "01100", "00000"],
        "+": ["00000", "00100", "00100", "11111", "00100", "00100", "00000"]
    ]
}

/// Colors sampled from the three route nodes in the ProxyPilot app icon, so the
/// Dock overlay reads as part of the icon rather than something pasted on top.
enum ProxyPilotDockPalette {
    private static var colors: [NSColor] {
        let preset = ProxyPilotGradientPreset(rawValue: UserDefaults.standard.string(forKey: ProxyPilotGradientPreset.defaultsKey) ?? "") ?? .violet
        return preset.colors.map { NSColor($0) }
    }
    static var pink: NSColor { colors[0] }
    static var violet: NSColor { colors[1] }
    static var indigo: NSColor { colors[2] }
    static let ledLit = NSColor(srgbRed: 0.95, green: 0.92, blue: 1.0, alpha: 1)
    static let failure = NSColor(srgbRed: 1.0, green: 0.36, blue: 0.42, alpha: 1)
    static let housing = NSColor(srgbRed: 0.05, green: 0.0, blue: 0.10, alpha: 0.86)
}

/// Geometry of the icon shape macOS actually draws in the Dock.
enum ProxyPilotDockGeometry {
    /// macOS renders app icons as an 824/1024 squircle inset 100/1024 from the canvas edge.
    static let iconInsetFraction: CGFloat = 100.0 / 1024.0
    /// A continuous-corner rounded rect at 0.26 x side matches the system icon mask
    /// to sub-pixel accuracy at 1024px (measured against NSWorkspace's rendered icon).
    static let cornerRadiusFraction: CGFloat = 0.26

    static func iconRect(in bounds: NSRect) -> NSRect {
        bounds.insetBy(dx: bounds.width * iconInsetFraction, dy: bounds.height * iconInsetFraction)
    }

    static func squircle(in rect: NSRect) -> CGPath {
        RoundedRectangle(cornerRadius: rect.width * cornerRadiusFraction, style: .continuous)
            .path(in: rect)
            .cgPath
    }
}

@MainActor
final class ProxyPilotDockTileView: NSView {
    /// Model-name sign. Sits inside the squircle's bottom edge, above the activity ring.
    static let signRect = NSRect(x: 22, y: 20, width: 84, height: 16)
    static let signHorizontalInset: CGFloat = 4
    static let marqueeGap: CGFloat = 18
    /// Marquee speed in points per second.
    static let marqueeSpeed: CGFloat = 12
    static let ringLineWidth: CGFloat = 3.5
    /// Seconds for the comet to travel once around the squircle.
    static let ringLapDuration: CFTimeInterval = 1.8
    static let frameInterval: TimeInterval = 1.0 / 20.0

    var presentation = ProxyPilotDockPresentation(activity: .inactive, modelLabel: "") {
        didSet {
            if presentation.modelLabel != oldValue.modelLabel {
                scrollOffset = 0
                marqueeStart = CACurrentMediaTime()
            }
            updateAnimation()
            needsDisplay = true
        }
    }

    var reduceMotion = false {
        didSet {
            updateAnimation()
            needsDisplay = true
        }
    }

    /// Position of the comet head around the perimeter, 0..<1. Driven by wall-clock
    /// time while animating so a stalled frame never slows the lap.
    var ringPhase: CGFloat = 0
    /// Horizontal marquee offset in points.
    var scrollOffset: CGFloat = 0

    private var animationTimer: Timer?
    private var animationStart: CFTimeInterval = 0
    private var marqueeStart: CFTimeInterval = 0

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let icon = NSApp.applicationIconImage else { return }
        icon.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)

        guard presentation.activity != .inactive,
              let context = NSGraphicsContext.current?.cgContext else { return }

        // Everything below is clipped to the icon's own squircle, so no overlay can
        // spill past the icon edge into the Dock.
        let iconRect = ProxyPilotDockGeometry.iconRect(in: bounds)
        context.saveGState()
        context.addPath(ProxyPilotDockGeometry.squircle(in: iconRect))
        context.clip()
        drawActivityRing(in: context, iconRect: iconRect)
        drawSignHousing()
        drawModelLabel()
        context.restoreGState()
    }

    static func shouldAnimate(_ presentation: ProxyPilotDockPresentation, reduceMotion: Bool) -> Bool {
        presentation.activity == .processing && !reduceMotion
    }

    private var availableSignWidth: CGFloat {
        Self.signRect.width - (Self.signHorizontalInset * 2)
    }

    private var modelTextWidth: CGFloat {
        ProxyPilotDockLEDMatrix.textWidth(presentation.modelLabel)
    }

    private var shouldScrollModel: Bool {
        presentation.activity == .processing && modelTextWidth > availableSignWidth && !reduceMotion
    }

    private func updateAnimation() {
        guard Self.shouldAnimate(presentation, reduceMotion: reduceMotion) else {
            animationTimer?.invalidate()
            animationTimer = nil
            ringPhase = 0
            scrollOffset = 0
            return
        }
        // Already spinning: keep the lap continuous across label changes.
        guard animationTimer == nil else { return }

        animationStart = CACurrentMediaTime()
        marqueeStart = animationStart
        let timer = Timer(
            timeInterval: Self.frameInterval,
            target: self,
            selector: #selector(animationTick),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    @objc private func animationTick() {
        let now = CACurrentMediaTime()
        ringPhase = CGFloat(((now - animationStart) / Self.ringLapDuration).truncatingRemainder(dividingBy: 1))
        if shouldScrollModel {
            let cycleWidth = modelTextWidth + Self.marqueeGap
            scrollOffset = (CGFloat(now - marqueeStart) * Self.marqueeSpeed)
                .truncatingRemainder(dividingBy: cycleWidth)
        }
        needsDisplay = true
        NSApp.dockTile.display()
    }

    // MARK: - Activity ring

    private func drawActivityRing(in context: CGContext, iconRect: NSRect) {
        let inset = (Self.ringLineWidth / 2) + 0.75
        let ringPath = ProxyPilotDockGeometry.squircle(in: iconRect.insetBy(dx: inset, dy: inset))
        let stroke = ringPath.copy(
            strokingWithWidth: Self.ringLineWidth,
            lineCap: .round,
            lineJoin: .round,
            miterLimit: 10
        )
        let center = CGPoint(x: iconRect.midX, y: iconRect.midY)

        switch presentation.activity {
        case .inactive, .idle:
            return
        case .failed:
            context.saveGState()
            context.addPath(stroke)
            context.setFillColor(ProxyPilotDockPalette.failure.withAlphaComponent(0.9).cgColor)
            context.fillPath()
            context.restoreGState()
        case .processing:
            context.saveGState()
            context.addPath(stroke)
            context.clip()
            if reduceMotion {
                // Static, seamless full-perimeter gradient.
                drawConicGradient(
                    in: context,
                    center: center,
                    angle: .pi / 2,
                    colors: [
                        ProxyPilotDockPalette.pink,
                        ProxyPilotDockPalette.violet,
                        ProxyPilotDockPalette.indigo,
                        ProxyPilotDockPalette.violet,
                        ProxyPilotDockPalette.pink
                    ],
                    locations: [0, 0.25, 0.5, 0.75, 1]
                )
            } else {
                // Faint track so the full squircle reads, then a comet whose bright
                // pink head leads and whose indigo tail fades out behind it.
                context.setFillColor(ProxyPilotDockPalette.violet.withAlphaComponent(0.16).cgColor)
                context.fill(iconRect)
                // Conic gradients advance counter-clockwise from `angle`, so the head sits
                // at location 0 and the tail trails behind it; decreasing the angle over
                // time spins the comet clockwise, starting from 12 o'clock.
                drawConicGradient(
                    in: context,
                    center: center,
                    angle: (.pi / 2) - (ringPhase * 2 * .pi),
                    colors: [
                        ProxyPilotDockPalette.pink,
                        ProxyPilotDockPalette.pink,
                        ProxyPilotDockPalette.violet.withAlphaComponent(0.9),
                        ProxyPilotDockPalette.indigo.withAlphaComponent(0.5),
                        ProxyPilotDockPalette.indigo.withAlphaComponent(0),
                        ProxyPilotDockPalette.indigo.withAlphaComponent(0)
                    ],
                    locations: [0, 0.03, 0.2, 0.4, 0.55, 1]
                )
            }
            context.restoreGState()
        }
    }

    private func drawConicGradient(
        in context: CGContext,
        center: CGPoint,
        angle: CGFloat,
        colors: [NSColor],
        locations: [CGFloat]
    ) {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let gradient = CGGradient(
                colorsSpace: space,
                colors: colors.map(\.cgColor) as CFArray,
                locations: locations
              ) else { return }
        // CoreGraphics has no Swift-renamed overlay for this API (macOS 14+), so call the C symbol.
        CGContextDrawConicGradient(context, gradient, center, angle)
    }

    // MARK: - Model sign

    private func drawSignHousing() {
        let housing = NSBezierPath(roundedRect: Self.signRect, xRadius: 4, yRadius: 4)
        ProxyPilotDockPalette.housing.setFill()
        housing.fill()

        let rim = NSBezierPath(roundedRect: Self.signRect.insetBy(dx: 0.4, dy: 0.4), xRadius: 3.6, yRadius: 3.6)
        rim.lineWidth = 0.8
        let rimColor = presentation.activity == .failed ? ProxyPilotDockPalette.failure : ProxyPilotDockPalette.violet
        rimColor.withAlphaComponent(0.5).setStroke()
        rim.stroke()
    }

    private func drawModelLabel() {
        let clipRect = Self.signRect.insetBy(dx: 2, dy: 1.5)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: clipRect, xRadius: 2.5, yRadius: 2.5).addClip()

        let y = Self.signRect.minY + ((Self.signRect.height - ProxyPilotDockLEDMatrix.glyphHeight) / 2)
        if shouldScrollModel {
            let cycleWidth = modelTextWidth + Self.marqueeGap
            let firstX = Self.signRect.minX + Self.signHorizontalInset - scrollOffset
            drawLEDText(presentation.modelLabel, at: NSPoint(x: firstX, y: y))
            drawLEDText(presentation.modelLabel, at: NSPoint(x: firstX + cycleWidth, y: y))
        } else {
            let x = Self.signRect.midX - (modelTextWidth / 2)
            drawLEDText(presentation.modelLabel, at: NSPoint(x: x, y: y))
        }

        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawLEDText(_ text: String, at origin: NSPoint) {
        let pitch = ProxyPilotDockLEDMatrix.dotPitch
        let diameter = ProxyPilotDockLEDMatrix.dotDiameter
        let litColor = presentation.activity == .failed ? ProxyPilotDockPalette.failure : ProxyPilotDockPalette.ledLit
        litColor.setFill()

        for (characterIndex, character) in text.enumerated() {
            let rows = ProxyPilotDockLEDMatrix.rows(for: character)
            let glyphX = origin.x + (CGFloat(characterIndex) * ProxyPilotDockLEDMatrix.glyphAdvance)
            for (rowIndex, row) in rows.enumerated() {
                for (columnIndex, bit) in row.enumerated() where bit == "1" {
                    let x = glyphX + (CGFloat(columnIndex) * pitch)
                    let y = origin.y + (CGFloat(6 - rowIndex) * pitch)
                    NSBezierPath(ovalIn: NSRect(x: x, y: y, width: diameter, height: diameter)).fill()
                }
            }
        }
    }
}

@MainActor
final class ProxyPilotDockTileController {
    static let failurePresentationDuration: TimeInterval = 3

    private let tileView = ProxyPilotDockTileView(
        frame: NSRect(x: 0, y: 0, width: 128, height: 128)
    )
    private var state: LocalProxyState?
    private var stateCancellable: AnyCancellable?
    private var accessibilityCancellable: AnyCancellable?
    private var failureExpiryTask: Task<Void, Never>?
    private var isInstalled = false

    static func shouldInstall(
        bundleIdentifier: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        // As of v1.11.6 the Dock Tile ships on both stable and alpha builds.
        // The bundleIdentifier argument is retained for API stability and
        // future channel-specific behavior, but no longer gates installation.
        environment["XCTestConfigurationFilePath"] == nil
    }

    func installIfEligible(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        guard Self.shouldInstall(bundleIdentifier: bundleIdentifier, environment: environment) else { return }
        tileView.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSApp.dockTile.contentView = tileView
        NSApp.dockTile.display()
        isInstalled = true

        accessibilityCancellable = NotificationCenter.default.publisher(
            for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in
            guard let self else { return }
            self.tileView.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            NSApp.dockTile.display()
        }
        refreshPresentation()
    }

    func bind(to state: LocalProxyState) {
        self.state = state
        stateCancellable = state.objectWillChange
            .debounce(for: .milliseconds(8), scheduler: RunLoop.main)
            .sink { [weak self] in
                self?.refreshPresentation()
            }
        refreshPresentation()
    }

    func restoreDefaultIcon() {
        failureExpiryTask?.cancel()
        failureExpiryTask = nil
        stateCancellable = nil
        accessibilityCancellable = nil
        guard isInstalled else { return }
        tileView.presentation = ProxyPilotDockPresentation(activity: .inactive, modelLabel: "")
        NSApp.dockTile.contentView = nil
        NSApp.dockTile.display()
        isInstalled = false
    }

    private func refreshPresentation() {
        guard isInstalled, let state else { return }
        let recentFailure: Bool
        let failureTimeRemaining: TimeInterval?
        if let lastFailureAt = state.lastFailureAt {
            let elapsed = Date().timeIntervalSince(lastFailureAt)
            recentFailure = elapsed < Self.failurePresentationDuration
            failureTimeRemaining = recentFailure ? Self.failurePresentationDuration - elapsed : nil
        } else {
            recentFailure = false
            failureTimeRemaining = nil
        }

        tileView.presentation = ProxyPilotDockPresentation.derive(
            isListening: state.isRunning,
            pendingRequestCount: state.pendingRequestCount,
            activeModels: state.activeModels,
            lastModelSeen: state.lastModelSeen,
            configuredModel: state.activeXcodeAgentModel,
            hasRecentFailure: recentFailure
        )
        NSApp.dockTile.display()

        failureExpiryTask?.cancel()
        failureExpiryTask = nil
        if let failureTimeRemaining, state.pendingRequestCount == 0 {
            failureExpiryTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(failureTimeRemaining))
                guard !Task.isCancelled else { return }
                self?.refreshPresentation()
            }
        }
    }
}
