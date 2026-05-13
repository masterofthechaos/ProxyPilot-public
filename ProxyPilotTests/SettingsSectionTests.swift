import XCTest
@testable import ProxyPilot

final class SettingsSectionTests: XCTestCase {
    func testSettingsSectionsExposeNativeSidebarMetadataInOrder() {
        XCTAssertEqual(SettingsSection.allCases, [.home, .proxy, .keys, .advanced, .customization])
        XCTAssertEqual(SettingsSection.home.title, "Home")
        XCTAssertEqual(SettingsSection.proxy.title, "Proxy")
        XCTAssertEqual(SettingsSection.keys.title, "Keys & Providers")
        XCTAssertEqual(SettingsSection.advanced.title, "Advanced")
        XCTAssertEqual(SettingsSection.customization.title, "Customization")
        XCTAssertEqual(SettingsSection.home.systemImage, "house")
        XCTAssertEqual(SettingsSection.proxy.systemImage, "network")
        XCTAssertEqual(SettingsSection.keys.systemImage, "key")
        XCTAssertEqual(SettingsSection.advanced.systemImage, "gearshape")
        XCTAssertEqual(SettingsSection.customization.systemImage, "paintpalette")
    }

    func testSettingsSectionsExposeCompactTabTitlesForCollapsedSidebar() {
        XCTAssertEqual(SettingsSection.collapsedTabSections, [.home, .proxy, .keys, .advanced])
        XCTAssertEqual(SettingsSection.collapsedTabSections.map(\.compactTitle), ["Home", "Proxy", "Keys & Providers", "Advanced"])
    }

    func testProxySectionFocusExposesModelsTargetAndHighlightDuration() {
        XCTAssertEqual(ProxySectionFocus.models.rawValue, "models")
        XCTAssertEqual(ProxySectionFocus.models.highlightDurationSeconds, 4)
    }
}
