import SwiftUI

enum AppBuildBadge {
    struct Descriptor {
        let text: String
        let tintName: String
        let tint: Color
    }

    static var current: Descriptor? {
        descriptor(bundleIdentifier: Bundle.main.bundleIdentifier)
    }

    static func isAlphaBundle(_ bundleIdentifier: String?) -> Bool {
        bundleIdentifier?.hasSuffix(".ProxyPilot-alpha") == true
    }

    static func descriptor(bundleIdentifier: String?) -> Descriptor? {
        guard isAlphaBundle(bundleIdentifier) else {
            return nil
        }
        return Descriptor(text: "Alpha", tintName: "pink", tint: .pink)
    }

    static func appDisplayName(bundleIdentifier: String?) -> String {
        isAlphaBundle(bundleIdentifier) ? "ProxyPilot Alpha" : "ProxyPilot"
    }

    static var currentAppDisplayName: String {
        appDisplayName(bundleIdentifier: Bundle.main.bundleIdentifier)
    }
}

enum AppVersionDisplay {
    static func text(version: String, build: String) -> String {
        "v\(version) (\(build))"
    }
}

struct AppVersionFooter: View {
    let versionText: String
    let buildText: String
    /// Shown until the harness tour is completed. Defaulted so non-onboarding call
    /// sites (and previews) keep compiling unchanged.
    var showsNewFeaturesPill: Bool = false
    var onOpenNewFeatures: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(AppVersionDisplay.text(version: versionText, build: buildText))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                if let badge = AppBuildBadge.current {
                    Text(badge.text)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(badge.tint.opacity(0.15), in: Capsule())
                        .foregroundStyle(badge.tint)
                }
            }
            // The version line owns its own label so an interactive pill beside it
            // stays reachable; a label on the whole footer would swallow the button.
            .accessibilityElement(children: .combine)
            .accessibilityLabel("ProxyPilot version \(versionText), build \(buildText)")

            Link(destination: SlicewriteStudioBrand.websiteURL) {
                HStack(spacing: 0) {
                    Text(SlicewriteStudioBrand.attributionLeadIn)
                        .foregroundStyle(.tertiary)

                    Text(SlicewriteStudioBrand.name)
                        .fontWeight(.bold)
                        .foregroundStyle(.secondary)
                        .underline()
                }
                .font(.caption2)
            }
            .buttonStyle(.plain)
            .help("Visit Slicewrite Studio")
            .accessibilityLabel(SlicewriteStudioBrand.attributionText)
            .accessibilityHint("Opens slicewrite.dev in your default browser")

            if showsNewFeaturesPill, let onOpenNewFeatures {
                NewFeaturesPill(action: onOpenNewFeatures)
                    .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .leading)))
            }
        }
    }
}

struct SettingsSidebarView: View {
    @Binding var selection: SettingsSection

    let sections: [SettingsSection]
    let versionText: String
    let buildText: String
    var showsNewFeaturesPill: Bool = false
    var onOpenNewFeatures: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(sections) { section in
                        Button {
                            selection = section
                        } label: {
                            SettingsSidebarRow(
                                section: section,
                                isSelected: selection == section
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(section.title)
                        .accessibilityValue(section.detail)
                    }
                }
                .padding(8)
            }

            Divider()

            AppVersionFooter(
                versionText: versionText,
                buildText: buildText,
                showsNewFeaturesPill: showsNewFeaturesPill,
                onOpenNewFeatures: onOpenNewFeatures
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }
}

private struct SettingsSidebarRow: View {
    let section: SettingsSection
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: section.systemImage)
                .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(section.title)
                    .lineLimit(1)

                Text(section.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .selectedContentBackgroundColor).opacity(0.18))
            }
        }
    }
}
