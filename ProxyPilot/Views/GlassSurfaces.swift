import SwiftUI

private struct ProxyPilotLiquidGlassEnabledKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var proxypilotLiquidGlassEnabled: Bool {
        get { self[ProxyPilotLiquidGlassEnabledKey.self] }
        set { self[ProxyPilotLiquidGlassEnabledKey.self] = newValue }
    }
}

struct GlassControlGroup<Content: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.proxypilotLiquidGlassEnabled) private var liquidGlassEnabled

    private let cornerRadius: CGFloat
    private let padding: CGFloat
    private let content: Content

    init(
        cornerRadius: CGFloat = 18,
        padding: CGFloat = 4,
        @ViewBuilder content: () -> Content
    ) {
        self.cornerRadius = cornerRadius
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        if #available(macOS 26.0, *), liquidGlassEnabled, !reduceTransparency {
            GlassEffectContainer(spacing: 8) {
                content
                    .padding(padding)
                    .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
        } else {
            content
                .padding(padding)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(.secondary.opacity(0.16))
                }
        }
    }
}

struct DashboardCard<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
