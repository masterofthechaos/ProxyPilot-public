import AppKit
import SwiftUI

struct CustomizationView: View {
    @EnvironmentObject private var vm: AppViewModel

    private var liquidGlassAppearanceAvailable: Bool {
        if #available(macOS 26.0, *) {
            return true
        }
        return false
    }

    private var effectiveLiquidGlassEnabled: Bool {
        liquidGlassAppearanceAvailable && vm.liquidGlassEnabled
    }

    var body: some View {
        Form {
            appearanceSection
            windowToolbarSection
            homeDashboardSection
            menuBarSection
        }
        .formStyle(.grouped)
    }

    private var appearanceSection: some View {
        Section("Appearance") {
            Picker("Theme", selection: Binding(
                get: { vm.appearancePreference },
                set: { vm.appearancePreference = $0 }
            )) {
                ForEach(AppAppearancePreference.allCases) { preference in
                    Text(preference.title).tag(preference)
                }
            }
            .pickerStyle(.segmented)

            ColorPicker("ProxyPilot accent color", selection: Binding(
                get: { vm.proxyPilotAccentColor },
                set: { vm.proxyPilotAccentHex = $0.proxyPilotHexString ?? ProxyPilotAccentColor.defaultHex }
            ), supportsOpacity: false)
            .help("Used for ProxyPilot-specific highlights and glows. Native macOS controls keep their system tint.")

            Toggle(vm.liquidGlassPreferenceTitle, isOn: Binding(
                get: { effectiveLiquidGlassEnabled },
                set: { if liquidGlassAppearanceAvailable { vm.liquidGlassEnabled = $0 } }
            ))
            .toggleStyle(.switch)
            .disabled(!liquidGlassAppearanceAvailable)
            .help(liquidGlassAppearanceAvailable
                  ? vm.liquidGlassPreferenceDescription
                  : "Liquid Glass requires macOS 26 or later.")

            Text(vm.liquidGlassPreferenceDescription)
                .font(.caption)
                .foregroundStyle(.secondary)

            liquidGlassPreview

            if !liquidGlassAppearanceAvailable {
                Text("Liquid Glass requires macOS 26 or later. ProxyPilot will use its standard macOS appearance on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var liquidGlassPreview: some View {
        ViewThatFits {
            HStack {
                Text("Control strip preview")
                    .foregroundStyle(.secondary)

                Spacer()

                liquidGlassPreviewControls
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Control strip preview")
                    .foregroundStyle(.secondary)
                liquidGlassPreviewControls
            }
        }
    }

    private var liquidGlassPreviewControls: some View {
        GlassControlGroup(cornerRadius: 14, padding: 3) {
            HStack(spacing: 2) {
                Label("Start", systemImage: "play.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)

                Rectangle()
                    .fill(Color(nsColor: .separatorColor).opacity(0.5))
                    .frame(width: 1, height: 20)
                    .padding(.horizontal, 2)

                Label("Refresh", systemImage: "arrow.triangle.2.circlepath")
                    .labelStyle(.titleAndIcon)
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .environment(\.proxypilotLiquidGlassEnabled, effectiveLiquidGlassEnabled)
    }

    private var windowToolbarSection: some View {
        Section("Window & Toolbar") {
            Picker("Default section", selection: Binding(
                get: { vm.defaultSettingsSection },
                set: { vm.defaultSettingsSection = $0 }
            )) {
                ForEach(SettingsSection.sidebarSections) { section in
                    Text(section.title).tag(section)
                }
            }
            .pickerStyle(.menu)

            Toggle("Launch at Login", isOn: Binding(
                get: { vm.launchAtLogin },
                set: { _ in vm.toggleLaunchAtLogin() }
            ))
            .toggleStyle(.switch)
            .help("Automatically start ProxyPilot when you log in.")

            LabeledContent("Toolbar status") {
                Text("Hidden when stopped")
                    .foregroundStyle(.secondary)
            }

            Text("ProxyPilot hides the stopped status pill so the toolbar stays quiet. Running, CLI-owned, recovery, and problem states still appear in the toolbar.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var homeDashboardSection: some View {
        Section("Home Dashboard") {
            ForEach(HomeDashboardSection.allCases) { section in
                Toggle(isOn: Binding(
                    get: { vm.visibleHomeDashboardSections.contains(section) },
                    set: { vm.setHomeDashboardSection(section, isVisible: $0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(section.title)
                        Text(section.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
            }
        }
    }

    private var menuBarSection: some View {
        Section("Menu Bar") {
            Toggle("Show ProxyPilot in the menu bar", isOn: Binding(
                get: { vm.showMenuBarExtra },
                set: { vm.showMenuBarExtra = $0 }
            ))
            .toggleStyle(.switch)

            VStack(alignment: .leading, spacing: 10) {
                ViewThatFits {
                    HStack {
                        Text("Menu bar content")
                            .font(.headline)
                        Spacer()
                        Button("Reset") {
                            vm.resetMenuBarCustomization()
                        }
                        .font(.caption)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Menu bar content")
                            .font(.headline)
                        Button("Reset") {
                            vm.resetMenuBarCustomization()
                        }
                        .font(.caption)
                    }
                }

                ForEach(vm.menuBarSectionOrder) { section in
                    menuBarSectionRow(section)
                }

                Text("Open Settings and Quit stay fixed so the menu bar extra always has a recovery path.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!vm.showMenuBarExtra)
        }
    }

    private func menuBarSectionRow(_ section: MenuBarSection) -> some View {
        HStack(spacing: 10) {
            Toggle(isOn: Binding(
                get: { vm.visibleMenuBarSections.contains(section) },
                set: { vm.setMenuBarSection(section, isVisible: $0) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(section.title)
                    Text(section.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.checkbox)

            Spacer()

            Button {
                vm.moveMenuBarSection(section, up: true)
            } label: {
                Image(systemName: "chevron.up")
            }
            .disabled(vm.menuBarSectionOrder.first == section)
            .help("Move \(section.title) up")

            Button {
                vm.moveMenuBarSection(section, up: false)
            } label: {
                Image(systemName: "chevron.down")
            }
            .disabled(vm.menuBarSectionOrder.last == section)
            .help("Move \(section.title) down")
        }
    }
}

private extension Color {
    var proxyPilotHexString: String? {
        guard let color = NSColor(self).usingColorSpace(.deviceRGB) else { return nil }
        let red = Int(round(color.redComponent * 255))
        let green = Int(round(color.greenComponent * 255))
        let blue = Int(round(color.blueComponent * 255))
        return String(format: "#%02X%02X%02X", red, green, blue)
    }
}
