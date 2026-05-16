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

struct SettingsSidebarView: View {
    @Binding var selection: SettingsSection

    let versionText: String
    let buildText: String

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(SettingsSection.sidebarSections) { section in
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
            .navigationTitle(AppBuildBadge.currentAppDisplayName)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("v\(versionText) (\(buildText))")
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
            }
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
