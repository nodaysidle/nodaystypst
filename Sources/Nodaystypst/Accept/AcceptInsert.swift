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

    /// One Tab accepts the entire already-bounded 2–4-word completion. The
    /// adapter still controls whether Tab may be claimed at all.
    static func acceptance(
        in shownGhost: String,
        bundleID: String
    ) -> WordAcceptance? {
        guard !shownGhost.isEmpty else { return nil }
        return WordAcceptance(accepted: shownGhost, remaining: "")
    }

    /// Returns `true` when Tab should trigger an accept:
    /// the ghost must be visible AND the active adapter must consent via
    /// `shouldOfferTabAccept()`.
    static func shouldAcceptTab(ghostVisible: Bool, adapterAllows: Bool) -> Bool {
        ghostVisible && adapterAllows
    }

    /// ChatGPT's ProseMirror editor needs an atomic Accessibility edit. Posting
    /// the completion as synthetic character events can drop or reorder spaces
    /// and leading characters under load.
    static func usesAtomicAccessibilityInsertion(bundleID: String) -> Bool {
        bundleID == codexBundleID
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
/// Because **nodaystypst** inserts into another app without activating it, an ordinary
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
/// | Tab + overlay visible + adapter allows | Insert shown completion and swallow Tab |
/// | Tab + overlay visible + adapter disallows | Hide, stop, **let Tab pass** |
/// | Non-Tab character / editing key + overlay visible | Hide, stop, call reject handler |
/// | Insertion failure (any kind) | Hide, stop, set generic `lastError` |
///
/// No field-content logging.
@MainActor
final class AcceptInsertMonitor {
    private enum MonitorError: Error {
        case adapterDisallows
    }

    // MARK: - Dependencies

    private let overlay: GhostOverlay
    private let observer: AccessibilityObserver
    private let preferences: AppPreferences
    private let adapterRegistry: AdapterRegistry

    // MARK: - Private infrastructure

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var rejectHandler: (@MainActor () -> Void)?
    private var acceptanceHandler: (
        @MainActor (String, FieldContext, FieldContext, UInt) -> Void
    )?
    private var tabAcceptanceScheduled = false

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

    /// Installs the suppressing CGEvent tap. Only takes effect when the overlay
    /// is currently visible. Idempotent — subsequent calls while already running
    /// are no-ops.
    func start() {
        guard overlay.isVisible, eventTap == nil else { return }

        guard installEventTap() else {
            overlay.hide()
            preferences.lastError = "Keyboard monitoring is unavailable."
            stop()
            return
        }
    }

    /// Removes the CGEvent tap. Safe to call when already stopped.
    func stop() {
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

        if isTab(nsEvent) {
            if overlay.isVisible, canAttemptTabAccept() {
                scheduleTabAccept()
                return nil
            }
            if overlay.isVisible { handleDisallowed() }
            return Unmanaged.passUnretained(event)
        }

        if isTypingOrEditingKey(nsEvent) {
            handleReject()
        }
        return Unmanaged.passUnretained(event)
    }

    // MARK: - Tab accept (deferred)

    /// Cheap pre-check using the cached snapshot. The expensive live AX
    /// revalidation runs in the deferred task, so the CGEvent tap callback
    /// stays bounded and macOS never disables the tap mid-press.
    private func canAttemptTabAccept() -> Bool {
        guard AccessibilityPermission.isTrusted(),
              let snapshot = observer.snapshot,
              !snapshot.isSecure,
              snapshot.geometryTrusted,
              let frontApp = NSWorkspace.shared.frontmostApplication,
              let bundleID = frontApp.bundleIdentifier,
              bundleID == snapshot.context.bundleID else {
            return false
        }
        let adapter = adapterRegistry.adapter(
            for: RunningAppInfo(
                bundleID: bundleID,
                localizedName: frontApp.localizedName ?? ""
            ),
            role: snapshot.context.elementRole
        )
        return AcceptInsert.shouldAcceptTab(
            ghostVisible: overlay.isVisible,
            adapterAllows: adapter.shouldOfferTabAccept()
        )
    }

    /// Schedules the live AX revalidation + insertion on the next main-actor
    /// turn so the CGEvent tap callback never exceeds its time budget.
    private func scheduleTabAccept() {
        guard !tabAcceptanceScheduled else { return }
        tabAcceptanceScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.tabAcceptanceScheduled = false }
            _ = self.performTabAccept()
        }
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

    // MARK: - Tab accept

    /// Reads the **live** focused AX element's value and caret index,
    /// derives the active adapter, and inserts the shown completion. Native
    /// hosts receive an AX value write plus collapsed selection. ChatGPT first
    /// receives a single selected-text replacement at the verified caret, with
    /// a guarded full-value fallback only when the editor stayed unchanged.
    /// Both routes verify the exact resulting value and caret. The overlay then
    /// hides.
    /// Returns `true` when the Tab must be swallowed. An adapter-disallowed
    /// Tab is allowed through; a failed attempted accept is swallowed so host
    /// focus cannot escape after presenting an actionable ghost.
    private func performTabAccept() -> Bool {
        guard overlay.isVisible, let ghostText = overlay.currentText else {
            return false
        }

        DebugLog.write("accept: begin ghost_utf16=\(ghostText.utf16.count)")
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
            let usesAtomicAccessibilityInsertion = AcceptInsert
                .usesAtomicAccessibilityInsertion(
                bundleID: target.bundleID
            )

            let newValue = try target.adapter.insertAcceptedText(
                acceptance.accepted,
                intoCurrentValue: target.currentValue,
                caretIndex: target.caretIndex
            )

            let insertPoint = target.caretIndex + acceptance.accepted.utf16.count
            if usesAtomicAccessibilityInsertion {
                let route = try insertAtomically(
                    acceptance.accepted,
                    into: target,
                    expectedValue: newValue,
                    insertPoint: insertPoint
                )
                DebugLog.write("accept: atomic AX route=\(route.rawValue)")
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

            let updatedWindow = FieldContext.boundedValue(
                newValue,
                caretIndex: insertPoint
            )
            let updatedContext = target.adapter.readContext(
                bundleID: target.bundleID,
                role: target.role,
                fullValue: updatedWindow.text,
                caretIndex: updatedWindow.caretIndex
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
            DebugLog.write(
                "accept: completed bundleID=\(target.bundleID) "
                + "accepted_utf16=\(acceptance.accepted.utf16.count)"
            )
            return true
        } catch MonitorError.adapterDisallows {
            DebugLog.write("accept: adapter disallowed")
            handleDisallowed()
            return false
        } catch {
            DebugLog.write("accept: failed type=\(String(describing: type(of: error)))")
            overlay.hide()
            preferences.lastError = "Unable to insert completion."
            stop()
            // Once a visible ghost made Tab actionable, never let a failed AX
            // revalidation escape into the host application's focus traversal.
            return true
        }
    }

    private enum AtomicAXInsertionRoute: String {
        case selectedText
        case fullValue
    }

    /// Inserts ChatGPT's bounded completion as one AX edit and verifies the
    /// exact resulting value before the accept is reported. If selected-text
    /// replacement is unsupported, the full-value fallback is permitted only
    /// while the field still equals the value revalidated for this Tab press.
    private func insertAtomically(
        _ text: String,
        into target: LiveTarget,
        expectedValue: String,
        insertPoint: Int
    ) throws -> AtomicAXInsertionRoute {
        guard !text.isEmpty else { throw AdapterError.insertFailed }

        if setCollapsedSelection(
            on: target.element,
            location: target.caretIndex
        ), AXUIElementSetAttributeValue(
            target.element,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        ) == .success,
           let verifiedElement = waitForValue(
               expectedValue,
               originalValue: target.currentValue,
               target: target
           ),
           ensureCollapsedSelection(
               on: verifiedElement,
               location: insertPoint,
               target: target
           ) {
            return .selectedText
        }

        // Never replace a value that changed after the live Tab revalidation.
        guard let unchangedElement = waitForValue(
            target.currentValue,
            originalValue: target.currentValue,
            target: target
        ) else {
            throw AdapterError.insertFailed
        }

        guard AXUIElementSetAttributeValue(
            unchangedElement,
            kAXValueAttribute as CFString,
            expectedValue as CFTypeRef
        ) == .success,
              let verifiedElement = waitForValue(
                  expectedValue,
                  originalValue: target.currentValue,
                  target: target
              ),
              ensureCollapsedSelection(
                  on: verifiedElement,
                  location: insertPoint,
                  target: target
              ) else {
            throw AdapterError.insertFailed
        }

        return .fullValue
    }

    /// AX-backed web editors may replace their focused accessibility element
    /// after a mutation, so verification checks both the original element and
    /// a freshly resolved focused element for a short bounded interval.
    private func waitForValue(
        _ expectedValue: String,
        originalValue: String,
        target: LiveTarget
    ) -> AXUIElement? {
        var candidate = target.element
        for attempt in 0..<5 {
            if axString(candidate, kAXValueAttribute) == expectedValue {
                return candidate
            }
            if let refreshed = refreshedFocusedElement(for: target) {
                candidate = refreshed
                if axString(candidate, kAXValueAttribute) == expectedValue {
                    return candidate
                }
            }
            if attempt < 4 {
                Thread.sleep(forTimeInterval: 0.01)
            }
        }

        // `originalValue` is intentionally accepted only by callers that use
        // it as an unchanged-state guard before the full-value fallback.
        return expectedValue == originalValue
            && axString(candidate, kAXValueAttribute) == originalValue
            ? candidate
            : nil
    }

    private func ensureCollapsedSelection(
        on element: AXUIElement,
        location: Int,
        target: LiveTarget
    ) -> Bool {
        var candidate = element
        for attempt in 0..<3 {
            if isCollapsedSelection(on: candidate, location: location) {
                return true
            }
            if setCollapsedSelection(on: candidate, location: location),
               isCollapsedSelection(on: candidate, location: location) {
                return true
            }
            if let refreshed = refreshedFocusedElement(for: target) {
                candidate = refreshed
            }
            if attempt < 2 {
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        return false
    }

    private func isCollapsedSelection(
        on element: AXUIElement,
        location: Int
    ) -> Bool {
        guard let range = selectedTextRange(on: element) else { return false }
        return range.location == location && range.length == 0
    }

    private func setCollapsedSelection(
        on element: AXUIElement,
        location: Int
    ) -> Bool {
        var cfRange = CFRange(location: location, length: 0)
        guard let rangeAX = AXValueCreate(.cfRange, &cfRange) else {
            return false
        }
        return AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            rangeAX
        ) == .success
    }

    private func selectedTextRange(on element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &value
        ) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        let rangeValue = value as! AXValue
        var range = CFRange(location: 0, length: 0)
        return AXValueGetValue(rangeValue, .cfRange, &range) ? range : nil
    }

    private func refreshedFocusedElement(for target: LiveTarget) -> AXUIElement? {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            == target.bundleID else {
            return nil
        }

        let systemWide = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success,
              let focusedValue,
              CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            return nil
        }
        let element = focusedValue as! AXUIElement
        let role = axString(element, kAXRoleAttribute)
        let subrole = axString(element, kAXSubroleAttribute)
        let metadata = [
            subrole,
            axString(element, kAXIdentifierAttribute),
            axString(element, kAXTitleAttribute),
            axString(element, kAXDescriptionAttribute),
            axString(element, kAXHelpAttribute),
        ].compactMap { $0 }

        guard role == target.role,
              !target.adapter.isSecure(
                  role: role,
                  subrole: subrole,
                  isPasswordField: axBool(element, "AXIsPassword")
                      || axBool(element, "AXIsPasswordField")
              ),
              SupportedAppPolicy.allowsField(
                  bundleID: target.bundleID,
                  role: role,
                  metadata: metadata
              ) else {
            return nil
        }
        return element
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
              let focused = focusedVal,
              CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            throw AdapterError.insertFailed
        }
        let focusedElement = focused as! AXUIElement

        let role = axString(focusedElement, kAXRoleAttribute)
        let subrole = axString(focusedElement, kAXSubroleAttribute)
        let isPasswordField = axBool(focusedElement, "AXIsPassword")
            || axBool(focusedElement, "AXIsPasswordField")
        let appInfo = RunningAppInfo(
            bundleID: bundleID,
            localizedName: frontApp.localizedName ?? ""
        )
        let adapter = adapterRegistry.adapter(for: appInfo, role: role)

        let fieldMetadata = [
            subrole,
            axString(focusedElement, kAXIdentifierAttribute),
            axString(focusedElement, kAXTitleAttribute),
            axString(focusedElement, kAXDescriptionAttribute),
            axString(focusedElement, kAXHelpAttribute),
        ].compactMap { $0 }

        guard !adapter.isSecure(
            role: role,
            subrole: subrole,
            isPasswordField: isPasswordField
        ),
              SupportedAppPolicy.allowsField(
                  bundleID: bundleID,
                  role: role,
                  metadata: fieldMetadata
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
           let range = rangeVal,
           CFGetTypeID(range) == AXValueGetTypeID() {
            let axValue = range as! AXValue
            var cfRange = CFRange(location: 0, length: 0)
            if AXValueGetValue(axValue, .cfRange, &cfRange) {
                selectedLocation = cfRange.location
                selectedLength = cfRange.length
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

        let liveWindow = FieldContext.boundedValue(
            currentValue,
            caretIndex: caretIndex
        )
        let liveContext = adapter.readContext(
            bundleID: bundleID,
            role: role ?? "",
            fullValue: liveWindow.text,
            caretIndex: liveWindow.caretIndex
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
