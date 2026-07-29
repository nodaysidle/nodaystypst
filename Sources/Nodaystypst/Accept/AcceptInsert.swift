@preconcurrency import ApplicationServices
@preconcurrency import AppKit
@preconcurrency import CoreGraphics
import Foundation

// MARK: - AcceptInsert policy

/// Pure policy methods for Tab-accept decisions.
///
/// These are deliberately simple, testable, and independent of any dynamic
/// state so that policy unit tests can verify the decision logic in isolation.
enum AcceptInsert {
    static let codexBundleID = CodexAdapter.bundleID

    struct WordAcceptance: Equatable, Sendable {
        let accepted: String
        let remaining: String
    }

    /// Splits the shown ghost into the next accepted token and the remainder.
    /// Leading boundary whitespace belongs to the accepted token; whitespace
    /// before a later token remains with the ghost so repeated Tab presses
    /// preserve natural spacing. Punctuation attached to a token stays with it.
    static func nextWord(in shownGhost: String) -> WordAcceptance? {
        guard !shownGhost.isEmpty else { return nil }

        var boundary = shownGhost.startIndex
        while boundary < shownGhost.endIndex,
              shownGhost[boundary].isWhitespace {
            boundary = shownGhost.index(after: boundary)
        }
        while boundary < shownGhost.endIndex,
              !shownGhost[boundary].isWhitespace {
            boundary = shownGhost.index(after: boundary)
        }

        guard boundary > shownGhost.startIndex else { return nil }
        return WordAcceptance(
            accepted: String(shownGhost[..<boundary]),
            remaining: String(shownGhost[boundary...])
        )
    }

    /// Codex owns repeated Tab presses for composer focus traversal. Accepting
    /// its entire already-bounded 2–4-word banner in one synthetic insertion
    /// avoids leaking a later Tab into the host UI. Other adapters retain the
    /// normal one-word-at-a-time policy.
    static func acceptance(
        in shownGhost: String,
        bundleID: String
    ) -> WordAcceptance? {
        guard !shownGhost.isEmpty else { return nil }
        if usesSyntheticTextInsertion(bundleID: bundleID) {
            return WordAcceptance(accepted: shownGhost, remaining: "")
        }
        return nextWord(in: shownGhost)
    }

    /// Returns `true` when Tab should trigger an accept:
    /// the ghost must be visible AND the active adapter must consent via
    /// `shouldOfferTabAccept()`.
    static func shouldAcceptTab(ghostVisible: Bool, adapterAllows: Bool) -> Bool {
        ghostVisible && adapterAllows
    }

    /// Codex's ProseMirror AX value setter replaces the whole document and
    /// resets its selection to zero. It therefore receives the already-approved
    /// token through a tagged Unicode key event at the live caret instead.
    static func usesSyntheticTextInsertion(bundleID: String) -> Bool {
        bundleID == codexBundleID
    }

    /// Codex needs its AX revalidation and synthetic insertion to run after
    /// the CGEvent tap callback returns. Keeping the callback bounded prevents
    /// macOS from disabling the tap and letting a later Tab escape into the
    /// host's focus traversal.
    static func requiresDeferredTabAcceptance(adapterKind: String) -> Bool {
        adapterKind == "codex"
    }

    /// Resolves the live caret from AX selection metadata when available, or
    /// from the already-secure-gated suffix when WebKit omits that attribute.
    /// The caller still re-derives and compares the full `FieldContext` before
    /// insertion, so a stale or inconsistent fallback is rejected.
    static func caretIndex(
        valueUTF16Count: Int,
        selectedLocation: Int?,
        selectedLength: Int?,
        expectedSuffixUTF16Count: Int
    ) -> Int? {
        if let selectedLocation,
           let selectedLength,
           selectedLocation >= 0,
           selectedLength >= 0,
           selectedLocation + selectedLength <= valueUTF16Count {
            return selectedLocation + selectedLength
        }

        let fallback = valueUTF16Count - expectedSuffixUTF16Count
        return (0...valueUTF16Count).contains(fallback) ? fallback : nil
    }
}

// MARK: - AcceptInsertMonitor

/// Cross-app key monitor that watches for Tab / character keystrokes while
/// the ghost overlay is visible and dispatches accept or reject accordingly.
///
/// Because **nodaystypst** is a non-activating menu-bar app, an ordinary
/// `NSEvent.addLocalMonitorForEvents` will not capture keystrokes directed
/// at the host application.  A supplemental **CGEvent tap** is therefore
/// installed at `.headInsertEventTap` to detect key events system-wide and,
/// when appropriate, suppress Tab so the host focus never receives it.
///
/// ## Lifecycle
///
/// - Call `start()` when the ghost overlay becomes visible.  Idempotent.
/// - Call `stop()` when the overlay hides or the monitor is no longer needed.
///
/// ## Behaviour
///
/// | Condition | Action |
/// |---|---|
/// | Tab + overlay visible + adapter allows | Insert next word, retain remainder, swallow Tab |
/// | Tab + overlay visible + adapter disallows | Hide, stop, **let Tab pass** |
/// | Non-Tab character / editing key + overlay visible | Hide, stop, call reject handler |
/// | Insertion failure (any kind) | Hide, stop, set generic `lastError` |
///
/// No field-content logging. Word splitting is deterministic and local.
@MainActor
final class AcceptInsertMonitor {
    private enum MonitorError: Error {
        case adapterDisallows
    }

    private static let syntheticInsertionEventTag: Int64 = 0x4E_44_54_59

    // MARK: - Dependencies

    private let overlay: GhostOverlay
    private let observer: AccessibilityObserver
    private let preferences: AppPreferences
    private let adapterRegistry: AdapterRegistry

    // MARK: - Private infrastructure

    private var localMonitor: Any?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var rejectHandler: (@MainActor () -> Void)?
    private var acceptanceHandler: (
        @MainActor (String, FieldContext, FieldContext, UInt) -> Void
    )?
    private var codexAcceptanceScheduled = false

    // MARK: - Init

    init(
        overlay: GhostOverlay,
        observer: AccessibilityObserver,
        preferences: AppPreferences,
        adapterRegistry: AdapterRegistry = AdapterRegistry()
    ) {
        self.overlay = overlay
        self.observer = observer
        self.preferences = preferences
        self.adapterRegistry = adapterRegistry
    }

    // MARK: - Public API

    /// Sets the handler that fires when a non-Tab character key is pressed
    /// while the overlay is visible.  The coordinator should wire this to
    /// its restart / reject path so that stale prediction state is discarded.
    func setRejectHandler(_ handler: @escaping @MainActor () -> Void) {
        rejectHandler = handler
    }

    /// Reports the unaccepted ghost remainder and the exact post-insert AX
    /// context so the coordinator can preserve it without a network round trip.
    func setAcceptanceHandler(
        _ handler: @escaping @MainActor (
            String,
            FieldContext,
            FieldContext,
            UInt
        ) -> Void
    ) {
        acceptanceHandler = handler
    }

    /// Installs both the local NSEvent keyDown monitor and the suppressing
    /// CGEvent tap.  Only takes effect when the overlay is currently visible.
    /// Idempotent — subsequent calls while already running are no-ops.
    func start() {
        guard overlay.isVisible, localMonitor == nil else { return }

        // Local NSEvent keyDown monitor (per plan spec; the real workhorse
        // is the CGEvent tap, but both are installed for robustness).
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            var result: NSEvent? = event
            MainActor.assumeIsolated {
                result = self?.handleLocalKeyEvent(event) ?? event
            }
            return result
        }

        guard installEventTap() else {
            overlay.hide()
            preferences.lastError = "Keyboard monitoring is unavailable."
            stop()
            return
        }
    }

    /// Removes both the local NSEvent monitor and the CGEvent tap.
    /// Safe to call when already stopped.
    func stop() {
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
        removeEventTap()
    }

    // MARK: - CGEvent tap

    private func installEventTap() -> Bool {
        guard eventTap == nil else { return true }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let mask: CGEventMask = 1 << CGEventType.keyDown.rawValue

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { (_proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<AcceptInsertMonitor>
                    .fromOpaque(refcon)
                    .takeUnretainedValue()
                // The tap source is attached to the main run loop below, so
                // the callback executes synchronously on the main actor.
                return MainActor.assumeIsolated {
                    monitor.handleTapEvent(type: type, event: event)
                }
            },
            userInfo: selfPtr
        ) else {
            return false
        }

        guard let source = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            tap,
            0
        ) else {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            return false
        }
        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func removeEventTap() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            eventTap = nil
        }
    }

    /// Handles a tap callback synchronously on the main run loop. Accepted
    /// Tab events return `nil`, preventing the host's default focus traversal.
    private func handleTapEvent(
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown, let nsEvent = NSEvent(cgEvent: event) else {
            return Unmanaged.passUnretained(event)
        }

        if event.getIntegerValueField(.eventSourceUserData)
            == Self.syntheticInsertionEventTag {
            return Unmanaged.passUnretained(event)
        }

        if isTab(nsEvent) {
            if overlay.isVisible,
               let adapterKind = observer.snapshot?.adapterKind,
               AcceptInsert.requiresDeferredTabAcceptance(
                   adapterKind: adapterKind
               ) {
                scheduleCodexTabAccept()
                return nil
            }
            return performTabAccept() ? nil : Unmanaged.passUnretained(event)
        }

        if isTypingOrEditingKey(nsEvent) {
            handleReject()
        }
        return Unmanaged.passUnretained(event)
    }

    // MARK: - Local NSEvent monitor handler

    /// Dispatches local-monitor key events.  May not fire for non-activating
    /// apps, but the CGEvent tap provides the same coverage.
    private func handleLocalKeyEvent(_ event: NSEvent) -> NSEvent? {
        guard overlay.isVisible else { return event }

        if isTab(event) {
            return performTabAccept() ? nil : event
        }
        if isTypingOrEditingKey(event) {
            handleReject()
        }
        return event
    }

    private func isTab(_ event: NSEvent) -> Bool {
        let acceptModifiers: NSEvent.ModifierFlags = [
            .command, .control, .option, .shift,
        ]
        guard event.modifierFlags.intersection(acceptModifiers).isEmpty else {
            return false
        }
        return event.keyCode == 48 || event.characters == "\t"
    }

    /// Reject character/editing keys without swallowing them. Navigation and
    /// function keys remain untouched; character shortcuts still pass through
    /// after dismissing the stale ghost.
    private func isTypingOrEditingKey(_ event: NSEvent) -> Bool {
        // Delete, forward-delete, Return, keypad Enter, and Space.
        if [51, 117, 36, 76, 49].contains(event.keyCode) {
            return true
        }

        guard let characters = event.characters, !characters.isEmpty else {
            return false
        }
        return characters.unicodeScalars.contains { scalar in
            let value = scalar.value
            return !CharacterSet.controlCharacters.contains(scalar)
                && !(0xF700...0xF8FF).contains(value)
        }
    }

    // MARK: - Tab accept (next-word insertion)

    /// Swallows Codex's physical Tab immediately, then performs the heavier AX
    /// validation on the next main-actor turn so the event tap never times out.
    private func scheduleCodexTabAccept() {
        guard !codexAcceptanceScheduled else { return }
        codexAcceptanceScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.codexAcceptanceScheduled = false }
            _ = self.performTabAccept()
        }
    }

    /// Reads the **live** focused AX element's value and caret index,
    /// derives the active adapter, and inserts the next shown word. Native
    /// hosts receive an AX value write plus collapsed selection; Codex receives
    /// a tagged Unicode event at its existing caret because its AX value setter
    /// resets ProseMirror selection to zero. The overlay then hides.
    /// Returns `true` when the Tab must be swallowed. An adapter-disallowed
    /// Tab is allowed through; a failed attempted accept is swallowed so host
    /// focus cannot escape after presenting an actionable ghost.
    private func performTabAccept() -> Bool {
        guard overlay.isVisible, let ghostText = overlay.currentText else {
            return false
        }

        do {
            let target = try resolveLiveTarget()
            guard let acceptance = AcceptInsert.acceptance(
                in: ghostText,
                bundleID: target.bundleID
            ) else {
                overlay.hide()
                stop()
                return true
            }
            let usesSyntheticInsertion = AcceptInsert.usesSyntheticTextInsertion(
                bundleID: target.bundleID
            )

            let newValue = try target.adapter.insertAcceptedText(
                acceptance.accepted,
                intoCurrentValue: target.currentValue,
                caretIndex: target.caretIndex
            )

            let insertPoint = target.caretIndex + acceptance.accepted.utf16.count
            if usesSyntheticInsertion {
                guard postAcceptedText(acceptance.accepted) else {
                    throw AdapterError.insertFailed
                }
            } else {
                guard AXUIElementSetAttributeValue(
                    target.element,
                    kAXValueAttribute as CFString,
                    newValue as CFTypeRef
                ) == .success else {
                    throw AdapterError.insertFailed
                }

                var cfRange = CFRange(location: insertPoint, length: 0)
                if let rangeAX = AXValueCreate(.cfRange, &cfRange) {
                    AXUIElementSetAttributeValue(
                        target.element,
                        kAXSelectedTextRangeAttribute as CFString,
                        rangeAX
                    )
                }
            }

            let updatedContext = target.adapter.readContext(
                bundleID: target.bundleID,
                role: target.role,
                fullValue: newValue,
                caretIndex: insertPoint
            )

            acceptanceHandler?(
                acceptance.remaining,
                target.currentContext,
                updatedContext,
                CFHash(target.element)
            )
            overlay.hide()
            observer.refreshSnapshotAfterInsertion()
            if acceptance.remaining.isEmpty {
                stop()
            }
            return true
        } catch MonitorError.adapterDisallows {
            handleDisallowed()
            return false
        } catch {
            overlay.hide()
            preferences.lastError = "Unable to insert completion."
            stop()
            // Once a visible ghost made Tab actionable, never let a failed AX
            // revalidation escape into the host application's focus traversal.
            return true
        }
    }

    /// Posts only the accepted completion token. The event is tagged so this
    /// monitor ignores its own generated keyDown while Codex receives ordinary
    /// Unicode input at the already-focused caret.
    private func postAcceptedText(_ text: String) -> Bool {
        let utf16 = Array(text.utf16)
        guard !utf16.isEmpty,
              let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: 0,
                  keyDown: true
              ),
              let keyUp = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: 0,
                  keyDown: false
              ) else {
            return false
        }

        utf16.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            keyDown.keyboardSetUnicodeString(
                stringLength: buffer.count,
                unicodeString: baseAddress
            )
        }
        keyDown.setIntegerValueField(
            .eventSourceUserData,
            value: Self.syntheticInsertionEventTag
        )
        keyUp.setIntegerValueField(
            .eventSourceUserData,
            value: Self.syntheticInsertionEventTag
        )
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    // MARK: - Reject (non-Tab key while ghost visible)

    /// Hides the overlay, stops the monitor, and calls the reject handler
    /// (typically wired to the coordinator's restart path so the debounce
    /// loop discards stale state and can re-predict on the next keystroke).
    private func handleReject() {
        guard overlay.isVisible else { return }
        overlay.hide()
        stop()
        rejectHandler?()
    }

    // MARK: - Disallowed (adapter says no)

    /// Hides the overlay and stops the monitor **without** calling the
    /// reject handler.  The Tab event is allowed to pass through to the
    /// host application (the CGEvent tap does not swallow it).
    private func handleDisallowed() {
        overlay.hide()
        stop()
    }

    // MARK: - Live AX state reading

    private struct LiveTarget {
        let element: AXUIElement
        let currentValue: String
        let caretIndex: Int
        let adapter: any FieldAdapter
        let bundleID: String
        let role: String
        let currentContext: FieldContext
    }

    /// Resolves and revalidates the focused field before reading its value.
    /// Live secure-field metadata, app identity, role, and bounded context must
    /// still match the snapshot that produced the shown ghost.
    private func resolveLiveTarget() throws -> LiveTarget {
        guard AccessibilityPermission.isTrusted(),
              let snapshot = observer.snapshot,
              !snapshot.isSecure,
              snapshot.geometryTrusted,
              let frontApp = NSWorkspace.shared.frontmostApplication,
              let bundleID = frontApp.bundleIdentifier,
              bundleID == snapshot.context.bundleID else {
            throw AdapterError.insertFailed
        }

        let systemWide = AXUIElementCreateSystemWide()
        var focusedVal: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedVal
        ) == .success,
              let focusedElement = focusedVal as! AXUIElement? else {
            throw AdapterError.insertFailed
        }

        let role = axString(focusedElement, kAXRoleAttribute)
        let subrole = axString(focusedElement, kAXSubroleAttribute)
        let isPasswordField = axBool(focusedElement, "AXIsPassword")
            || axBool(focusedElement, "AXIsPasswordField")
        let appInfo = RunningAppInfo(
            bundleID: bundleID,
            localizedName: frontApp.localizedName ?? ""
        )
        let adapter = adapterRegistry.adapter(for: appInfo, role: role)

        guard !adapter.isSecure(
            role: role,
            subrole: subrole,
            isPasswordField: isPasswordField
        ),
              snapshot.context.elementRole == (role ?? "") else {
            throw AdapterError.insertFailed
        }
        guard adapter.shouldOfferTabAccept() else {
            throw MonitorError.adapterDisallows
        }

        // Read field content only after the live secure gate passes.
        var valueVal: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focusedElement,
            kAXValueAttribute as CFString,
            &valueVal
        ) == .success,
              let currentValue = valueVal as? String else {
            throw AdapterError.insertFailed
        }

        var selectedLocation: Int?
        var selectedLength: Int?
        var rangeVal: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            focusedElement,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeVal
        ) == .success,
           let axValue = rangeVal as! AXValue? {
            var range = CFRange(location: 0, length: 0)
            if AXValueGetValue(axValue, .cfRange, &range) {
                selectedLocation = range.location
                selectedLength = range.length
            }
        }

        guard let caretIndex = AcceptInsert.caretIndex(
            valueUTF16Count: currentValue.utf16.count,
            selectedLocation: selectedLocation,
            selectedLength: selectedLength,
            expectedSuffixUTF16Count: snapshot.context.suffix.utf16.count
        ) else {
            throw AdapterError.insertFailed
        }

        let liveContext = adapter.readContext(
            bundleID: bundleID,
            role: role ?? "",
            fullValue: currentValue,
            caretIndex: caretIndex
        )
        guard liveContext == snapshot.context else {
            throw AdapterError.insertFailed
        }

        return LiveTarget(
            element: focusedElement,
            currentValue: currentValue,
            caretIndex: caretIndex,
            adapter: adapter,
            bundleID: bundleID,
            role: role ?? "",
            currentContext: liveContext
        )
    }

    private func axString(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success else {
            return nil
        }
        return value as? String
    }

    private func axBool(_ element: AXUIElement, _ attribute: String) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success else {
            return false
        }
        return (value as? Bool) ?? false
    }
}
