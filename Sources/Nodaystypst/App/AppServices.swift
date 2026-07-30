import AppKit
import Observation

@MainActor
@Observable
final class AppServices {
    static let shared = AppServices()

    let preferences: AppPreferences
    let keychainStore: KeychainStore
    let writingStyleStore: WritingStyleStore
    private(set) var accessibilityTrusted: Bool

    let accessibilityObserver: AccessibilityObserver
    let completionCoordinator: CompletionCoordinator

    private var terminateObserver: NSObjectProtocol?

    init(
        preferences: AppPreferences = AppPreferences(),
        keychainStore: KeychainStore = KeychainStore(),
        accessibilityTrusted: Bool = AccessibilityPermission.isTrusted()
    ) {
        self.preferences = preferences
        self.keychainStore = keychainStore
        self.writingStyleStore = WritingStyleStore()
        self.accessibilityTrusted = accessibilityTrusted
        self.accessibilityObserver = AccessibilityObserver()

        let predictClient = PredictClient(
            keychainStore: keychainStore,
            preferences: preferences
        )
        let overlay = GhostOverlay()
        self.completionCoordinator = CompletionCoordinator(
            observer: accessibilityObserver,
            predictClient: predictClient,
            overlay: overlay,
            preferences: preferences,
            keychainStore: keychainStore,
            writingStyleStore: writingStyleStore
        )

        if accessibilityTrusted {
            accessibilityObserver.start()
            completionCoordinator.start()
        }

        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [writingStyleStore] _ in
            Task { await writingStyleStore.flushPending() }
        }

        completionCoordinator.updateAccessibilityTrustedProvider(
            { [weak self] in self?.accessibilityTrusted ?? false }
        )
    }

    func start() {
        guard accessibilityTrusted else { return }
        accessibilityObserver.start()
        completionCoordinator.start()
    }

    func stop() {
        completionCoordinator.stop()
        accessibilityObserver.stop()
    }

    func refreshAccessibilityStatus() {
        let trusted = AccessibilityPermission.isTrusted()
        guard trusted != accessibilityTrusted else { return }
        accessibilityTrusted = trusted

        if trusted {
            accessibilityObserver.start()
            completionCoordinator.start()
        } else {
            completionCoordinator.stop()
            accessibilityObserver.stop()
        }
    }

    func resetLearning(bundleID: String) async -> Bool {
        do {
            try await writingStyleStore.reset(bundleID: bundleID)
            return true
        } catch {
            return false
        }
    }

    func resetAllLearning() async -> Bool {
        do {
            try await writingStyleStore.resetAll()
            return true
        } catch {
            return false
        }
    }
}
