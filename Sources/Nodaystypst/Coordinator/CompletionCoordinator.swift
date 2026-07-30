import AppKit
import Foundation
import Observation

/// Coordinates the Phase A prediction loop: debounce → predict → overlay.
///
/// Observes `AccessibilityObserver.snapshot` and `AppPreferences.isPaused` via
/// `withObservationTracking`, cancelling and replacing a single `Task`-based
/// debounce on every change. A `UInt64` generation counter invalidates stale
/// responses, and `PredictClient.cancel()` is called immediately before each
/// debounce cycle so the in-flight request does not waste network resources.
///
/// ## Trust Model
/// The static `shouldPredict` gate enforces every safety check before a
/// prediction is allowed: paused, AX trust, secure field, geometry trust, and
/// API-key availability.  Only current-generation trusted successes are shown
/// at the current caret rect.  Failures other than `.failed` are silent;
/// `.failed` writes a non-sensitive string to `AppPreferences.lastError`.
///
/// ## Scope
/// Key and insertion mechanics remain in `AcceptInsertMonitor`; this type only
/// owns its overlay-aligned lifecycle and reject callback. It performs no
/// field-content or request-body logging.
@MainActor
@Observable
final class CompletionCoordinator {
    private struct AcceptedContinuation {
        let previousContext: FieldContext
        let expectedContext: FieldContext
        let remainder: String
    }

    // MARK: - Static gate

    /// Returns `true` only when every safety gate passes.
    ///
    /// - Parameters:
    ///   - isPaused: `true` when the user has paused predictions.
    ///   - axTrusted: `true` when the Accessibility permission is granted.
    ///   - snapshotSecure: `true` when the focused field is a secure / password field.
    ///   - geometryTrusted: `true` when the adapter verified caret geometry.
    ///   - hasAPIKey: `true` when a non-empty OpenRouter API key is stored in the Keychain.
    /// - Returns: `isPaused == false && axTrusted && !snapshotSecure && geometryTrusted && hasAPIKey`
    nonisolated static func shouldPredict(
        isPaused: Bool,
        axTrusted: Bool,
        snapshotSecure: Bool,
        geometryTrusted: Bool,
        hasAPIKey: Bool
    ) -> Bool {
        !isPaused && axTrusted && !snapshotSecure && geometryTrusted && hasAPIKey
    }

    /// Suppresses conversational answers when the caret follows a question.
    /// Whitespace after `?` remains suppressed until the user starts the next
    /// sentence with a non-whitespace character.
    nonisolated static func shouldSuppressAfterQuestionMark(
        prefix: String
    ) -> Bool {
        prefix.last(where: { !$0.isWhitespace }) == "?"
    }

    // MARK: - Dependencies

    private let observer: AccessibilityObserver
    private let predictClient: PredictClient
    private let overlay: GhostOverlay
    private let preferences: AppPreferences
    private let keychainStore: KeychainStore
    private let writingStyleStore: WritingStyleStore
    private var isAccessibilityTrusted: @MainActor () -> Bool

    // MARK: - Private state

    private var generation: UInt64 = 0
    private var observationID: UInt64 = 0
    private var debounceTask: Task<Void, Never>?
    private var isRunning = false
    private var acceptMonitor: AcceptInsertMonitor?
    private var acceptedContinuation: AcceptedContinuation?
    private var learningTask: Task<Void, Never>?

    // Non-sensitive state exposed in the Settings diagnostics section.
    private(set) var lastInteraction = "None"
    var isRunningForDiagnostics: Bool { isRunning }
    var isOverlayVisibleForDiagnostics: Bool { overlay.isVisible }

    // MARK: - Initialisation

    init(
        observer: AccessibilityObserver,
        predictClient: PredictClient,
        overlay: GhostOverlay,
        preferences: AppPreferences,
        keychainStore: KeychainStore,
        writingStyleStore: WritingStyleStore,
        isAccessibilityTrusted: @escaping @MainActor () -> Bool = AccessibilityPermission.isTrusted
    ) {
        self.observer = observer
        self.predictClient = predictClient
        self.overlay = overlay
        self.preferences = preferences
        self.keychainStore = keychainStore
        self.writingStyleStore = writingStyleStore
        self.isAccessibilityTrusted = isAccessibilityTrusted
    }

    // MARK: - Lifecycle

    func updateAccessibilityTrustedProvider(
        _ provider: @escaping @MainActor () -> Bool
    ) {
        isAccessibilityTrusted = provider
    }

    /// Starts the prediction loop.  Idempotent — a second call is a no-op
    /// when the coordinator is already running.
    func start() {
        guard !isRunning else { return }
        isRunning = true

        // Wire accept monitor after all stored properties initialize.
        if acceptMonitor == nil {
            acceptMonitor = AcceptInsertMonitor(
                overlay: overlay,
                observer: observer,
                preferences: preferences
            )
            acceptMonitor?.setRejectHandler { [weak self] in
                guard let self else { return }
                self.lastInteraction = "Rejected by continued typing"
                self.acceptedContinuation = nil
                self.debounceTask?.cancel()
                self.debounceTask = nil
                self.generation &+= 1
                self.hideOverlay()
                Task { await self.predictClient.cancel() }
            }
            acceptMonitor?.setAcceptanceHandler {
                [weak self] remainder, previousContext, expectedContext, fieldID in
                guard let self else { return }
                self.lastInteraction = "Accepted with Tab"
                self.acceptedContinuation = AcceptedContinuation(
                    previousContext: previousContext,
                    expectedContext: expectedContext,
                    remainder: remainder
                )
                self.enqueueBaselineAdvance(
                    WritingObservation(
                        fieldID: fieldID,
                        bundleID: expectedContext.bundleID,
                        role: expectedContext.elementRole,
                        prefix: expectedContext.prefix
                    )
                )
            }
        }

        observationID &+= 1
        observeState(observationID: observationID)
        handleStateChange()
    }

    /// Stops the prediction loop, cancels the debounce, hides the overlay,
    /// and cancels any in-flight `PredictClient` request.
    func stop() {
        isRunning = false
        generation &+= 1
        observationID &+= 1
        debounceTask?.cancel()
        debounceTask = nil
        acceptedContinuation = nil
        hideOverlay()
        Task { await predictClient.cancel() }
    }

    // MARK: - Observation lifecycle

    /// One-shot observation that tracks both inputs and re-arms after every change.
    ///
    /// `withObservationTracking` fires `onChange` on an arbitrary queue, so
    /// both `handleStateChange()` and the re-registration are wrapped in a
    /// `Task { @MainActor }` to satisfy the `@MainActor` isolation of
    /// `observer` and `self`.
    private func observeState(observationID: UInt64) {
        withObservationTracking {
            _ = observer.snapshot
            _ = preferences.isPaused
        } onChange: { [weak self] in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self,
                      self.isRunning,
                      self.observationID == observationID else { return }
                self.observeState(observationID: observationID)
                self.handleStateChange()
            }
        }
    }

    // MARK: - State change handler

    /// Cancels the current debounce, bumps the generation, and starts a new
    /// cycle if all gates pass.  Called on every `snapshot` or `isPaused`
    /// change and once on `start()`.
    private func handleStateChange() {
        guard isRunning else { return }

        // Cancel current debounce cycle and bump generation.
        debounceTask?.cancel()
        generation &+= 1
        let currentGen = generation

        // Read current snapshot and preferences.
        let snap = observer.snapshot
        let paused = preferences.isPaused
        let axTrusted = isAccessibilityTrusted()

        if let acceptedContinuation {
            if let snap, snap.context == acceptedContinuation.expectedContext {
                debounceTask = Task { await predictClient.cancel() }
                guard !acceptedContinuation.remainder.isEmpty,
                      !paused,
                      axTrusted,
                      !snap.isSecure,
                      snap.geometryTrusted,
                      let caretRect = snap.caretRect else {
                    self.acceptedContinuation = nil
                    hideOverlay()
                    return
                }
                showOverlay(
                    text: acceptedContinuation.remainder,
                    screenRect: caretRect,
                    font: nil,
                    geometryTrusted: true,
                    placement: overlayPlacement(for: snap.adapterKind)
                )
                return
            }
            if let snap, snap.context == acceptedContinuation.previousContext {
                debounceTask = Task { await predictClient.cancel() }
                return
            }
            self.acceptedContinuation = nil
        }

        hideOverlay()

        if let snap,
           !snap.isSecure,
           SupportedAppPolicy.allowsPredictions(
               bundleID: snap.context.bundleID
           ) {
            enqueueLearning(snapshot: snap)
        }

        guard let snap,
              SupportedAppPolicy.allowsPredictions(
                  bundleID: snap.context.bundleID
              ),
              !snap.context.prefix.isEmpty,
              !Self.shouldSuppressAfterQuestionMark(
                  prefix: snap.context.prefix
              ),
              !paused,
              axTrusted,
              !snap.isSecure,
              snap.geometryTrusted,
              snap.caretRect != nil else {
            DebugLog.write(
                "handleStateChange: gate failed "
                + "snapNil=\(snap == nil) "
                + "prefixEmpty=\(snap?.context.prefix.isEmpty ?? true) "
                + "questionBoundary=\(snap.map { Self.shouldSuppressAfterQuestionMark(prefix: $0.context.prefix) } ?? false) "
                + "paused=\(paused) axTrusted=\(axTrusted) "
                + "secure=\(snap?.isSecure ?? true) "
                + "geometryTrusted=\(snap?.geometryTrusted ?? false) "
                + "caretRect=\(snap?.caretRect != nil)"
            )
            debounceTask = Task { await predictClient.cancel() }
            return
        }

        DebugLog.write("handleStateChange: gates passed bundleID=\(snap.context.bundleID) starting debounce")
        // --- Debounce → predict → overlay ---
        debounceTask = Task { [weak self] in
            guard let self else { return }

            await self.predictClient.cancel()
            guard !Task.isCancelled else { return }

            // Debounce sleep.
            try? await Task.sleep(nanoseconds: PredictionConstants.debounceNanoseconds)

            guard !Task.isCancelled else { return }

            // Re-validate after sleep: generation must still be current,
            // pause must be off, AX must be trusted, snapshot must exist
            // and not be secure, geometry must be trusted, prefix must be
            // non-empty, caret must be available, and an API key must be
            // present.
            guard self.isRunning,
                  self.generation == currentGen,
                  let currentSnap = self.observer.snapshot,
                  currentSnap == snap,
                  !currentSnap.context.prefix.isEmpty,
                  !Self.shouldSuppressAfterQuestionMark(
                      prefix: currentSnap.context.prefix
                  ),
                  currentSnap.caretRect != nil,
                  CompletionCoordinator.shouldPredict(
                      isPaused: self.preferences.isPaused,
                      axTrusted: self.isAccessibilityTrusted(),
                      snapshotSecure: currentSnap.isSecure,
                      geometryTrusted: currentSnap.geometryTrusted,
                      hasAPIKey: self.keychainHasAPIKey()
                  ) else {
                if self.generation == currentGen {
                    self.hideOverlay()
                }
                return
            }

            let predictionText = FieldContext.boundedPredictionText(
                prefix: currentSnap.context.prefix,
                suffix: currentSnap.context.suffix
            )
            let styleSummary = self.preferences.isLearningEnabled(
                for: currentSnap.context.bundleID
            ) ? await self.writingStyleStore.promptSummary(
                bundleID: currentSnap.context.bundleID
            ) : ""
            guard !Task.isCancelled,
                  self.isRunning,
                  self.generation == currentGen else { return }

            // --- Call PredictClient ---
            let result = await self.predictClient.predict(
                prefix: predictionText.prefix,
                suffix: predictionText.suffix,
                generation: currentGen,
                styleSummary: styleSummary
            )

            // Only a current, still-trusted snapshot may process results.
            guard self.isRunning,
                  self.generation == currentGen,
                  !self.preferences.isPaused,
                  self.isAccessibilityTrusted(),
                  let latestSnapshot = self.observer.snapshot,
                  latestSnapshot == currentSnap,
                  !latestSnapshot.isSecure,
                  latestSnapshot.geometryTrusted,
                  let latestCaretRect = latestSnapshot.caretRect else {
                if self.generation == currentGen {
                    self.hideOverlay()
                }
                return
            }

            switch result {
            case .success(let text):
                self.preferences.lastError = nil
                DebugLog.write("predict: success length=\(text.count)")
                if GhostOverlay.shouldPresent(
                    text: text,
                    geometryTrusted: latestSnapshot.geometryTrusted
                ) {
                    self.showOverlay(
                        text: text,
                        screenRect: latestCaretRect,
                        font: nil,
                        geometryTrusted: latestSnapshot.geometryTrusted,
                        placement: self.overlayPlacement(
                            for: latestSnapshot.adapterKind
                        )
                    )
                    self.lastInteraction = "Suggestion shown"
                    DebugLog.write("overlay.show: length=\(text.count) rect=\(latestCaretRect)")
                } else {
                    DebugLog.write("predict: shouldPresent=false length=\(text.count)")
                    self.hideOverlay()
                }

            case .cancelled, .timedOut, .stale:
                DebugLog.write("predict: \(result) for bundleID=\(latestSnapshot.context.bundleID)")
                self.hideOverlay()

            case .failed(let message):
                DebugLog.write("predict: failed")
                self.hideOverlay()
                // Only .failed writes to preferences.lastError (non-sensitive).
                self.preferences.lastError = message
            }
        }
    }

    // MARK: - Overlay + monitor helpers

    /// Hides the overlay and stops the accept monitor. Safe to call
    /// when the overlay is already hidden or the monitor is nil.
    private func hideOverlay() {
        overlay.hide()
        acceptMonitor?.stop()
    }

    /// Shows the overlay with trusted geometry, then starts the accept
    /// monitor so Tab/typing-reject can respond.
    private func showOverlay(
        text: String,
        screenRect: CGRect,
        font: NSFont?,
        geometryTrusted: Bool,
        placement: GhostOverlay.Placement
    ) {
        overlay.show(
            text: text,
            screenRect: screenRect,
            font: font,
            geometryTrusted: geometryTrusted,
            placement: placement
        )
        acceptMonitor?.start()
    }

    private func overlayPlacement(for adapterKind: String) -> GhostOverlay.Placement {
        adapterKind == "codex" ? .fieldBanner : .inline
    }

    // MARK: - Helpers

    /// Returns `true` when the Keychain holds a non-empty OpenRouter API key.
    private func keychainHasAPIKey() -> Bool {
        do {
            guard let key = try keychainStore.loadAPIKey(), !key.isEmpty else {
                return false
            }
            return true
        } catch {
            return false
        }
    }

    private func enqueueLearning(snapshot: FocusedFieldSnapshot) {
        guard preferences.isLearningEnabled(for: snapshot.context.bundleID) else {
            return
        }
        let observation = WritingObservation(
            fieldID: snapshot.fieldID,
            bundleID: snapshot.context.bundleID,
            role: snapshot.context.elementRole,
            prefix: snapshot.context.prefix
        )
        let previous = learningTask
        let store = writingStyleStore
        learningTask = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            await store.observe(observation)
        }
    }

    private func enqueueBaselineAdvance(_ observation: WritingObservation) {
        guard preferences.isLearningEnabled(for: observation.bundleID) else {
            return
        }
        let previous = learningTask
        let store = writingStyleStore
        learningTask = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            await store.advanceBaseline(observation)
        }
    }
}
