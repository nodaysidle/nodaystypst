import AppKit
import SwiftUI

enum AppLaunchConfiguration {
    static let qaSettingsFlag = "--qa-settings"
    static let backgroundFlag = "--background"

    nonisolated static func shouldOpenQASettings(
        arguments: [String]
    ) -> Bool {
        arguments.contains(qaSettingsFlag)
    }

    nonisolated static func shouldOpenSettings(
        arguments: [String]
    ) -> Bool {
        !arguments.contains(backgroundFlag)
    }
}

@MainActor
final class AppSettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = AppSettingsWindowController()
    private static let contentSize = NSSize(width: 520, height: 760)
    static let settingsStyleMask: NSWindow.StyleMask = [.titled, .closable]

    private init() {
        super.init(window: nil)
    }

    static func requiresFrameRepair(_ frame: NSRect) -> Bool {
        !frame.origin.x.isFinite
            || !frame.origin.y.isFinite
            || !frame.width.isFinite
            || !frame.height.isFinite
            || frame.width < 100
            || frame.height < 100
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(
        services: AppServices,
        showsQADiagnostics: Bool = false
    ) {
        DebugLog.write(
            "settings.show: requested qa=\(showsQADiagnostics)"
        )
        if window == nil {
            let settingsController = DesktopSettingsViewController(
                services: services,
                showsQADiagnostics: showsQADiagnostics
            )
            let settingsWindow = NSWindow(
                contentRect: NSRect(origin: .zero, size: Self.contentSize),
                styleMask: Self.settingsStyleMask,
                backing: .buffered,
                defer: false
            )
            settingsWindow.identifier = NSUserInterfaceItemIdentifier(
                "com.nodays.nodaystypst.settings.v2"
            )
            settingsWindow.isRestorable = false
            settingsWindow.contentViewController = settingsController
            settingsWindow.initialFirstResponder =
                settingsController.preferredInitialFirstResponder
            settingsWindow.setContentSize(Self.contentSize)
            settingsController.view.frame = NSRect(
                origin: .zero,
                size: Self.contentSize
            )
            settingsWindow.delegate = self
            settingsWindow.isReleasedWhenClosed = false
            settingsWindow.contentMinSize = Self.contentSize
            settingsWindow.contentMaxSize = Self.contentSize
            settingsWindow.center()
            window = settingsWindow
            DebugLog.write("settings.show: window created")
        } else if let settingsController = window?.contentViewController
            as? DesktopSettingsViewController {
            settingsController.refresh()
        }

        window?.title = showsQADiagnostics
            ? "nodaystypst QA Settings"
            : "nodaystypst Settings"
        let activationChanged = NSApplication.shared.setActivationPolicy(.regular)
        DebugLog.write(
            "settings.show: regularActivation=\(activationChanged)"
        )
        NSApplication.shared.activate(ignoringOtherApps: true)
        window?.deminiaturize(nil)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        if let settingsController = window?.contentViewController
            as? DesktopSettingsViewController {
            window?.makeFirstResponder(
                settingsController.preferredInitialFirstResponder
            )
        }
        ensureUsableWindowFrame()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            [weak self] in
            self?.ensureUsableWindowFrame()
        }
        DebugLog.write(
            "settings.show: visible=\(window?.isVisible == true) "
            + "windowCount=\(NSApplication.shared.windows.count)"
        )
    }

    func windowWillClose(_ notification: Notification) {
        DebugLog.write("settings.close: prediction service remains running")
        window?.contentViewController = nil
        window = nil
    }

    private func ensureUsableWindowFrame() {
        guard let window,
              Self.requiresFrameRepair(window.frame) else {
            return
        }
        window.setContentSize(Self.contentSize)
        window.center()
        DebugLog.write(
            "settings.frame: repaired width=\(window.frame.width) "
            + "height=\(window.frame.height)"
        )
    }
}

@MainActor
final class AppLifecycleDelegate: NSObject, NSApplicationDelegate {
    private let automaticTerminationReason = "nodaystypst completion service"
    private var terminationWasRequested = false

    static func requestTermination() {
        guard let delegate = NSApplication.shared.delegate
            as? AppLifecycleDelegate else {
            NSApplication.shared.terminate(nil)
            return
        }
        delegate.allowNextTerminationRequest()
        NSApplication.shared.terminate(nil)
    }

    func allowNextTerminationRequest() {
        terminationWasRequested = true
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        ProcessInfo.processInfo.disableAutomaticTermination(
            automaticTerminationReason
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let shouldOpenSettings = AppLaunchConfiguration.shouldOpenSettings(
            arguments: ProcessInfo.processInfo.arguments
        )
        let shouldOpenQASettings = AppLaunchConfiguration.shouldOpenQASettings(
            arguments: ProcessInfo.processInfo.arguments
        )
        DebugLog.write(
            "applicationDidFinishLaunching: settings=\(shouldOpenSettings) "
            + "qa=\(shouldOpenQASettings)"
        )
        if shouldOpenSettings {
            AppSettingsWindowController.shared.show(
                services: .shared,
                showsQADiagnostics: shouldOpenQASettings
            )
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        AppSettingsWindowController.shared.show(services: .shared)
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        false
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        terminationWasRequested ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        ProcessInfo.processInfo.enableAutomaticTermination(
            automaticTerminationReason
        )
    }
}

@main
struct NodaystypstApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycleDelegate.self)
    private var appDelegate
    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    AppSettingsWindowController.shared.show(services: .shared)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
