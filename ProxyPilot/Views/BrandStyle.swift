import AppKit
import SwiftUI

enum SlicewriteStudioBrand {
    static let name = "Slicewrite Studio"
    static let attributionLeadIn = "a developer tool by "
    static let attributionText = attributionLeadIn + name
    static let websiteURL = URL(string: "https://slicewrite.dev")!
}

/// Hues sampled directly from the app icon's circuit trail (pink -> violet -> blue-violet).
/// Distinct from `vm.proxyPilotAccentColor`, which is user-customizable; these stay fixed
/// as the app's brand identity.
enum ProxyPilotBrandPalette {
    static let pink = Color(proxyPilotHex: "#F678C0")
    static let violet = Color(proxyPilotHex: "#B27DFB")
    static let blueViolet = Color(proxyPilotHex: "#7674FD")
}

/// Icon + wordmark, styled to echo the website nav brand. Text uses the system font
/// (not the website's bundled Inter) to stay native on macOS.
struct ProxyPilotBrandMark: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                .resizable()
                .interpolation(.high)
                .frame(width: 18, height: 18)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .shadow(color: ProxyPilotBrandPalette.violet.opacity(0.22), radius: 3, y: 1)

            Text(AppBuildBadge.currentAppDisplayName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.trailing, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(AppBuildBadge.currentAppDisplayName)
    }
}

/// Two soft radial washes anchored at opposite corners, tinted with the brand palette.
/// Light mode needs *more* of the wash, not less: a light tint over a white base has
/// far less contrast to work with than the same tint over a dark one, so it needs both
/// a higher opacity and a deeper hue to register at all. The pink reads as brand color
/// against the dark base but washes out to grey against white, so light mode swaps it
/// for the palette's violet.
private struct ProxyPilotAmbientBackground: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    private var washOpacity: Double {
        colorScheme == .dark ? 0.14 : 0.18
    }

    private var topTrailingTint: Color {
        colorScheme == .dark ? ProxyPilotBrandPalette.pink : ProxyPilotBrandPalette.violet
    }

    private var bottomLeadingTint: Color {
        ProxyPilotBrandPalette.blueViolet
    }

    func body(content: Content) -> some View {
        content.background {
            ZStack {
                Color(nsColor: .windowBackgroundColor)

                RadialGradient(
                    colors: [topTrailingTint.opacity(washOpacity), .clear],
                    center: .topTrailing,
                    startRadius: 0,
                    endRadius: 480
                )

                RadialGradient(
                    colors: [bottomLeadingTint.opacity(washOpacity), .clear],
                    center: .bottomLeading,
                    startRadius: 0,
                    endRadius: 480
                )
            }
            .ignoresSafeArea()
        }
    }
}

extension View {
    func proxyPilotAmbientBackground() -> some View {
        modifier(ProxyPilotAmbientBackground())
    }

    @ViewBuilder
    func proxyPilotTransparentWindowToolbar() -> some View {
        if #available(macOS 26.0, *) {
            toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else {
            self
        }
    }
}
