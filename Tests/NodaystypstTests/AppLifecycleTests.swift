import AppKit
import Testing
@testable import Nodaystypst

@Suite("App lifecycle")
@MainActor
struct AppLifecycleTests {
    @Test("QA diagnostics require their explicit launch flag")
    func qaSettingsLaunchFlag() {
        #expect(
            AppLaunchConfiguration.shouldOpenQASettings(
                arguments: ["Nodaystypst", "--qa-settings"]
            )
        )
        #expect(
            !AppLaunchConfiguration.shouldOpenQASettings(
                arguments: ["Nodaystypst"]
            )
        )
    }

    @Test("background launch keeps Settings closed until reopen")
    func backgroundLaunchFlag() {
        #expect(
            !AppLaunchConfiguration.shouldOpenSettings(
                arguments: ["Nodaystypst", "--background"]
            )
        )
        #expect(
            AppLaunchConfiguration.shouldOpenSettings(
                arguments: ["Nodaystypst"]
            )
        )
    }

    @Test("desktop Settings exposes required controls")
    func desktopSettingsControls() {
        let suiteName = "nodaystypst-settings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let services = AppServices(
            preferences: AppPreferences(defaults: defaults),
            keychainStore: KeychainStore(
                service: suiteName,
                account: "test-key"
            ),
            accessibilityTrusted: false
        )
        let controller = DesktopSettingsViewController(
            services: services,
            showsQADiagnostics: false
        )
        #expect(
            controller.preferredContentSize == NSSize(width: 520, height: 760)
        )
        let descendants = allSubviews(of: controller.view)
        let buttonTitles = descendants
            .compactMap { ($0 as? NSButton)?.title }
        let sectionTitles = descendants
            .compactMap { ($0 as? NSBox)?.title }

        #expect(buttonTitles.contains("Pause predictions"))
        #expect(buttonTitles.contains("Personalize predictions"))
        #expect(buttonTitles.contains("Clear All Learned Data"))
        #expect(buttonTitles.contains("Open System Settings"))
        #expect(sectionTitles.contains("OpenRouter"))
        #expect(sectionTitles.contains("Compatibility"))
        #expect(sectionTitles.contains("Accessibility"))
        #expect(
            !(controller.preferredInitialFirstResponder is NSSecureTextField)
        )
    }

    @Test("desktop Settings repairs collapsed AeroSpace frames")
    func settingsFrameRepairPolicy() {
        #expect(
            !AppSettingsWindowController.settingsStyleMask.contains(
                .resizable
            )
        )
        #expect(
            !AppSettingsWindowController.settingsStyleMask.contains(
                .miniaturizable
            )
        )
        #expect(
            AppSettingsWindowController.requiresFrameRepair(
                NSRect(x: 14, y: 44, width: 0, height: 0)
            )
        )
        #expect(
            !AppSettingsWindowController.requiresFrameRepair(
                NSRect(x: 14, y: 44, width: 520, height: 760)
            )
        )
        #expect(
            AppSettingsWindowController.requiresFrameRepair(
                NSRect(x: CGFloat.nan, y: 0, width: 520, height: 760)
            )
        )
    }

    @Test("completion service stays alive without windows")
    func doesNotTerminateAfterLastWindowCloses() {
        let delegate = AppLifecycleDelegate()
        #expect(
            !delegate.applicationShouldTerminateAfterLastWindowClosed(
                NSApplication.shared
            )
        )
    }

    @Test("unsolicited application termination is cancelled")
    func cancelsUnsolicitedTermination() {
        let delegate = AppLifecycleDelegate()
        #expect(
            delegate.applicationShouldTerminate(NSApplication.shared)
                == .terminateCancel
        )
    }

    @Test("explicit Quit is allowed")
    func allowsExplicitTermination() {
        let delegate = AppLifecycleDelegate()
        delegate.allowNextTerminationRequest()
        #expect(
            delegate.applicationShouldTerminate(NSApplication.shared)
                == .terminateNow
        )
    }

    private func allSubviews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(allSubviews)
    }
}
