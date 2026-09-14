import XCTest
@testable import ProxyPilot

final class SettingsSectionTests: XCTestCase {
    func testGlassNavigationSurfaceHonorsAvailabilityPreferenceAndAccessibility() {
        XCTAssertTrue(
            GlassNavigationSurfacePolicy.usesLiquidGlass(
                platformAvailable: true,
                liquidGlassEnabled: true,
                reduceTransparency: false
            )
        )
        XCTAssertFalse(
            GlassNavigationSurfacePolicy.usesLiquidGlass(
                platformAvailable: false,
                liquidGlassEnabled: true,
                reduceTransparency: false
            )
        )
        XCTAssertFalse(
            GlassNavigationSurfacePolicy.usesLiquidGlass(
                platformAvailable: true,
                liquidGlassEnabled: false,
                reduceTransparency: false
            )
        )
        XCTAssertFalse(
            GlassNavigationSurfacePolicy.usesLiquidGlass(
                platformAvailable: true,
                liquidGlassEnabled: true,
                reduceTransparency: true
            )
        )
    }

    func testAppVersionDisplayIncludesVersionAndBuild() {
        XCTAssertEqual(
            AppVersionDisplay.text(version: "1.14.0", build: "137"),
            "v1.14.0 (137)"
        )
    }

    func testSettingsSectionsExposeNativeSidebarMetadataInOrder() {
        XCTAssertEqual(SettingsSection.allCases, [.home, .history, .harnesses, .proxy, .routing, .keys, .advanced, .customization])
        XCTAssertEqual(SettingsSection.sidebarSections, [.home, .history, .harnesses, .proxy, .routing, .keys, .advanced, .customization])
        XCTAssertEqual(SettingsSection.home.title, "Home")
        XCTAssertEqual(SettingsSection.history.title, "Session History")
        XCTAssertEqual(SettingsSection.harnesses.title, "Coding Harnesses")
        XCTAssertEqual(SettingsSection.proxy.title, "Proxy")
        XCTAssertEqual(SettingsSection.routing.title, "Routing")
        XCTAssertEqual(SettingsSection.keys.title, "Keys & Providers")
        XCTAssertEqual(SettingsSection.advanced.title, "Advanced")
        XCTAssertEqual(SettingsSection.customization.title, "Customization")
        XCTAssertEqual(SettingsSection.home.systemImage, "house")
        XCTAssertEqual(SettingsSection.history.systemImage, "clock.arrow.circlepath")
        XCTAssertEqual(SettingsSection.harnesses.systemImage, "terminal")
        XCTAssertEqual(SettingsSection.proxy.systemImage, "network")
        XCTAssertEqual(SettingsSection.routing.systemImage, "arrow.triangle.branch")
        XCTAssertEqual(SettingsSection.keys.systemImage, "key")
        XCTAssertEqual(SettingsSection.advanced.systemImage, "gearshape")
        XCTAssertEqual(SettingsSection.customization.systemImage, "paintpalette")
    }

    func testSettingsSectionsExposeCompactTabTitlesForCollapsedSidebar() {
        XCTAssertEqual(SettingsSection.collapsedTabSections, [.home, .history, .harnesses, .proxy, .routing, .keys, .advanced])
        XCTAssertEqual(SettingsSection.collapsedTabSections.map(\.compactTitle), ["Home", "History", "Harnesses", "Proxy", "Routing", "Keys & Providers", "Advanced"])
        XCTAssertFalse(SettingsSection.collapsedTabSections.contains(.customization))
    }

    func testRepoGPSRoutingFeatureFiltersNavigationWithoutRemovingSection() {
        XCTAssertTrue(SettingsSection.allCases.contains(.routing))
        XCTAssertFalse(
            SettingsSection.availableSidebarSections(repoGPSRoutingEnabled: false).contains(.routing)
        )
        XCTAssertFalse(
            SettingsSection.availableCollapsedTabSections(repoGPSRoutingEnabled: false).contains(.routing)
        )
        XCTAssertTrue(
            SettingsSection.availableSidebarSections(repoGPSRoutingEnabled: true).contains(.routing)
        )
        XCTAssertTrue(
            SettingsSection.availableCollapsedTabSections(repoGPSRoutingEnabled: true).contains(.routing)
        )
    }

    func testRepoGPSRoutingFeatureRequiresInstallerOwnedExecutable() {
        let home = URL(fileURLWithPath: "/Users/example")
        let expected = "/Users/example/.local/bin/rgps"

        XCTAssertEqual(RepoGPSRoutingFeatureFlag.candidateExecutable(home: home).path, expected)
        XCTAssertTrue(RepoGPSRoutingFeatureFlag.isEnabled(home: home) { $0 == expected })
        XCTAssertFalse(RepoGPSRoutingFeatureFlag.isEnabled(home: home) { _ in false })
    }

    func testMenuBarCustomizationReordersAroundHiddenRepoGPSSection() {
        let order: [MenuBarSection] = [.statusDetails, .repoGPSRoute, .modelPicker, .sessionStats]
        let excluded: Set<MenuBarSection> = [.repoGPSRoute]

        XCTAssertEqual(
            MenuBarSection.visibleOrder(from: order, excluding: excluded),
            [.statusDetails, .modelPicker, .sessionStats]
        )
        XCTAssertEqual(
            MenuBarSection.reordered(order, moving: .statusDetails, up: false, excluding: excluded),
            [.modelPicker, .repoGPSRoute, .statusDetails, .sessionStats]
        )
        XCTAssertEqual(
            MenuBarSection.reordered(order, moving: .sessionStats, up: true, excluding: excluded),
            [.statusDetails, .repoGPSRoute, .sessionStats, .modelPicker]
        )
    }

    func testMenuBarCustomizationReorderingPreservesExistingBehaviorWhenVisible() {
        let order: [MenuBarSection] = [.statusDetails, .repoGPSRoute, .modelPicker, .sessionStats]

        XCTAssertEqual(
            MenuBarSection.reordered(order, moving: .modelPicker, up: true),
            [.statusDetails, .modelPicker, .repoGPSRoute, .sessionStats]
        )
    }

    func testProxySectionFocusExposesTargetsAndHighlightDuration() {
        XCTAssertEqual(ProxySectionFocus.models.rawValue, "models")
        XCTAssertEqual(ProxySectionFocus.models.highlightDurationSeconds, 4)
        XCTAssertEqual(ProxySectionFocus.agentRegistration.rawValue, "agentRegistration")
        XCTAssertEqual(ProxySectionFocus.agentRegistration.highlightDurationSeconds, 4)
    }

    func testSlicewriteStudioBrandUsesCanonicalIdentityAndSecureWebsite() {
        XCTAssertEqual(SlicewriteStudioBrand.name, "Slicewrite Studio")
        XCTAssertEqual(
            SlicewriteStudioBrand.attributionText,
            "a developer tool by Slicewrite Studio"
        )
        XCTAssertEqual(SlicewriteStudioBrand.websiteURL.scheme, "https")
        XCTAssertEqual(SlicewriteStudioBrand.websiteURL.host, "slicewrite.dev")
        XCTAssertEqual(SlicewriteStudioBrand.websiteURL.path, "")
    }

    func testModelSelectionListLayoutStaysBoundedForLargeProviderCatalogs() {
        // Pins the bounded-scroll cap so a provider with hundreds of non-collapsible
        // models (e.g. OpenRouter) can't silently regress back to an unbounded frame
        // that pushes the Xcode/Agent sections off screen.
        XCTAssertEqual(ModelSelectionListLayout.minHeight, 120)
        XCTAssertEqual(ModelSelectionListLayout.maxHeight, 400)
        XCTAssertLessThan(ModelSelectionListLayout.minHeight, ModelSelectionListLayout.maxHeight)
    }
}
