import SwiftUI

struct SettingsSidebarView: View {
    @Binding var selection: SettingsSection

    let versionText: String
    let buildText: String

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(SettingsSection.allCases) { section in
                    SettingsSidebarRow(section: section)
                        .tag(section)
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("ProxyPilot")

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("v\(versionText) (\(buildText))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    Text("Beta")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.15), in: Capsule())
                        .foregroundStyle(.orange)
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

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: section.systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(section.title)
                    .lineLimit(1)

                Text(section.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}
