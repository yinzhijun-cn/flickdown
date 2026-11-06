import AppKit
import Sparkle
import Testing
@testable import Flickdown

@MainActor
struct UpdateMenuTests {
    @Test("发布包提供手动检查和自动检查开关，本地开发包隐藏两项")
    func updateActionsDependOnUpdaterAvailability() throws {
        let app = NSApplication.shared
        let servicesMenu = app.servicesMenu
        let windowsMenu = app.windowsMenu
        defer {
            app.servicesMenu = servicesMenu
            app.windowsMenu = windowsMenu
        }

        let check = #selector(SPUStandardUpdaterController.checkForUpdates(_:))
        let toggle = #selector(AppDelegate.toggleAutomaticUpdateChecks(_:))
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        let release = try #require(MainMenu.build(updaterController: controller).items.first?.submenu)
        #expect(release.items.first { $0.action == check }?.target === controller)
        #expect(release.items.contains { $0.action == toggle })

        let local = try #require(MainMenu.build(updaterController: nil).items.first?.submenu)
        #expect(!local.items.contains { $0.action == check || $0.action == toggle })
    }
}
