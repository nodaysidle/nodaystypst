@preconcurrency import ApplicationServices
import AppKit
import CoreGraphics
import Foundation
import Observation

// MARK: - FocusedFieldSnapshot

struct FocusedFieldSnapshot: Equatable {
    let fieldID: UInt
    let context: FieldContext
    let caretRect: CGRect?
    let fieldBounds: CGRect?
    let isSecure: Bool
    let geometryTrusted: Bool
    let adapterKind: String
}

struct AccessibilityDiagnostics: Equatable {
    let bundleID: String
    let role: String
    let adapterKind: String
    let fieldDecision: String
    let isSecure: Bool
    let geometryTrusted: Bool
}

// MARK: - AccessibilityObserver

@MainActor
@Observable
final class AccessibilityObserver {
    private(set) var snapshot: FocusedFieldSnapshot?
    private(set) var lastDiagnostics: AccessibilityDiagnostics?

    private var observer: AXObserver?
    private var runLoopSource: CFRunLoopSource?
    private var observedApplicationElement: AXUIElement?
    private var observedFocusedElement: AXUIElement?
    private var workspaceActivationObserver: NSObjectProtocol?
    private var contentBlindEventTap: CFMachPort?
    private var contentBlindRunLoopSource: CFRunLoopSource?
    private var contentBlindRefreshTask: Task<Void, Never>?
    private var currentPID: pid_t = 0
    private var isRunning = false
    private let adapterRegistry = AdapterRegistry()

    // MARK: - Public API

    func start() {
        guard AccessibilityPermission.isTrusted() else {
            stop()
            return
        }
        guard !isRunning else {
            updateSnapshot()
            return
        }
        isRunning = true
        workspaceActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleApplicationActivation()
            }
        }
        installContentBlindRefreshTap()
        installObserver()
        updateSnapshot()
    }

    func stop() {
        isRunning = false
        if let workspaceActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceActivationObserver)
            self.workspaceActivationObserver = nil
        }
        removeObserver()
        removeContentBlindRefreshTap()
        contentBlindRefreshTask?.cancel()
        contentBlindRefreshTask = nil
        snapshot = nil
    }

    nonisolated static func shouldUseContentBlindRefresh(bundleID: String) -> Bool {
        bundleID == SupportedAppPolicy.orionBundleID
            || bundleID == SupportedAppPolicy.antinoteBundleID
    }

    /// Synchronously refreshes the AX snapshot after nodaystypst inserts an
    /// accepted word. Secure metadata is still evaluated before field content.
    func refreshSnapshotAfterInsertion() {
        guard isRunning else { return }
        updateSnapshot()
        contentBlindRefreshTask?.cancel()
        contentBlindRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 12_000_000)
            guard !Task.isCancelled, let self, self.isRunning else { return }
            self.updateSnapshot()
        }
    }

    // MARK: - Observer Lifecycle

    private func installObserver() {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }
        let pid = frontApp.processIdentifier
        currentPID = pid

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard AXObserverCreate(pid, axCallback, &observer) == .success,
              let observer else {
            return
        }

        // Observe focused-element changes on the application element
        let appElement = AXUIElementCreateApplication(pid)
        observedApplicationElement = appElement
        AXObserverAddNotification(
            observer,
            appElement,
            kAXFocusedUIElementChangedNotification as CFString,
            selfPtr
        )

        // Observe value + selection on the currently focused element
        refreshElementObservers(observer, refcon: selfPtr)

        runLoopSource = AXObserverGetRunLoopSource(observer)
        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
    }

    private func refreshElementObservers(
        _ observer: AXObserver,
        refcon: UnsafeMutableRawPointer?
    ) {
        if let observedFocusedElement {
            AXObserverRemoveNotification(
                observer,
                observedFocusedElement,
                kAXValueChangedNotification as CFString
            )
            AXObserverRemoveNotification(
                observer,
                observedFocusedElement,
                kAXSelectedTextChangedNotification as CFString
            )
            self.observedFocusedElement = nil
        }

        guard let focusedElement = focusedElement(for: currentPID) else {
            return
        }

        observedFocusedElement = focusedElement
        AXObserverAddNotification(
            observer,
            focusedElement,
            kAXValueChangedNotification as CFString,
            refcon
        )
        AXObserverAddNotification(
            observer,
            focusedElement,
            kAXSelectedTextChangedNotification as CFString,
            refcon
        )
    }

    private func removeObserver() {
        if let observer, let observedFocusedElement {
            AXObserverRemoveNotification(
                observer,
                observedFocusedElement,
                kAXValueChangedNotification as CFString
            )
            AXObserverRemoveNotification(
                observer,
                observedFocusedElement,
                kAXSelectedTextChangedNotification as CFString
            )
        }
        if let observer, let observedApplicationElement {
            AXObserverRemoveNotification(
                observer,
                observedApplicationElement,
                kAXFocusedUIElementChangedNotification as CFString
            )
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
        observedFocusedElement = nil
        observedApplicationElement = nil
        observer = nil
        currentPID = 0
    }

    // MARK: - Content-blind fallback

    /// Orion and Antinote do not reliably emit AX value/selection
    /// notifications. This listen-only tap observes only
    /// that a key-down event occurred, then asks AX to reread the focused
    /// element after the host handles it. The event payload is never inspected,
    /// retained, or logged.
    private func installContentBlindRefreshTap() {
        guard contentBlindEventTap == nil else { return }

        let mask: CGEventMask = 1 << CGEventType.keyDown.rawValue
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else {
                    return Unmanaged.passUnretained(event)
                }
                let observer = Unmanaged<AccessibilityObserver>
                    .fromOpaque(refcon)
                    .takeUnretainedValue()
                Task { @MainActor [weak observer] in
                    observer?.handleContentBlindEvent(type: type)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: selfPointer
        ) else {
            DebugLog.write("contentBlind: tapCreate FAILED (Accessibility not granted?)")
            return
        }

        guard let source = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            tap,
            0
        ) else {
            CFMachPortInvalidate(tap)
            DebugLog.write("contentBlind: runLoopSource FAILED")
            return
        }

        contentBlindEventTap = tap
        contentBlindRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        DebugLog.write("contentBlind: tap installed and enabled")
    }

    private func removeContentBlindRefreshTap() {
        if let source = contentBlindRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            contentBlindRunLoopSource = nil
        }
        if let tap = contentBlindEventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            contentBlindEventTap = nil
        }
    }

    private func handleContentBlindEvent(type: CGEventType) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            DebugLog.write("contentBlind: tap disabled (re-enabling) type=\(type.rawValue)")
            if let contentBlindEventTap {
                CGEvent.tapEnable(tap: contentBlindEventTap, enable: true)
            }
            return
        }
        guard type == .keyDown else { return }

        guard isRunning else {
            DebugLog.write("contentBlind: skip (observer not running)")
            return
        }
        let frontBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none"
        let shouldRefresh = Self.shouldUseContentBlindRefresh(bundleID: frontBundle)
        DebugLog.write("contentBlind: keyDown frontBundle=\(frontBundle) shouldRefresh=\(shouldRefresh)")
        guard shouldRefresh else { return }

        contentBlindRefreshTask?.cancel()
        contentBlindRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 12_000_000)
            guard !Task.isCancelled, let self, self.isRunning else { return }
            self.updateSnapshot()
        }
    }

    // MARK: - Snapshot Update

    private func updateSnapshot() {
        guard AccessibilityPermission.isTrusted() else {
            DebugLog.write("updateSnapshot: AX not trusted, snapshot=nil")
            snapshot = nil
            return
        }

        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            DebugLog.write("updateSnapshot: no frontmost app, snapshot=nil")
            snapshot = nil
            return
        }

        let bundleID = frontApp.bundleIdentifier ?? "unknown"
        let appName = frontApp.localizedName ?? "Unknown"
        let appInfo = RunningAppInfo(bundleID: bundleID, localizedName: appName)
        DebugLog.write("updateSnapshot: frontmost=\(appName) bundleID=\(bundleID)")

        guard let focusedElement = focusedElement(
            for: frontApp.processIdentifier
        ) else {
            DebugLog.write(
                "updateSnapshot: focused element unavailable bundleID=\(bundleID)"
            )
            snapshot = nil
            return
        }

        // Read role metadata before any field content so secure fields can be
        // short-circuited without exposing their value as predict-ready context.
        let role = axString(focusedElement, kAXRoleAttribute)
        let subrole = axString(focusedElement, kAXSubroleAttribute)
        let isPasswordField = axBool(focusedElement, "AXIsPassword")
            || axBool(focusedElement, "AXIsPasswordField")
        let isSecure = SecureFieldGate.isSecure(
            role: role,
            subrole: subrole,
            isPasswordField: isPasswordField
        )

        // --- Adapter selection ---
        let adapter = adapterRegistry.adapter(for: appInfo, role: role)
        let adapterKind = adapterKindName(for: adapter)
        let fieldBounds = axBounds(focusedElement)

        if isSecure {
            DebugLog.write("updateSnapshot: SECURE field blocked bundleID=\(bundleID) role=\(role ?? "nil")")
            snapshot = FocusedFieldSnapshot(
                fieldID: CFHash(focusedElement),
                context: FieldContext(
                    prefix: "",
                    suffix: "",
                    bundleID: bundleID,
                    elementRole: role ?? ""
                ),
                caretRect: nil,
                fieldBounds: fieldBounds,
                isSecure: true,
                geometryTrusted: false,
                adapterKind: adapterKind
            )
            updateDiagnosticsIfKnown(
                bundleID: bundleID,
                role: role,
                adapterKind: adapterKind,
                fieldDecision: "Secure field blocked",
                isSecure: true,
                geometryTrusted: false
            )
            return
        }

        // Stay content-blind outside the supported targets. This also
        // prevents prediction, learning, overlays, and Tab monitoring there.
        guard SupportedAppPolicy.allowsPredictions(bundleID: bundleID) else {
            DebugLog.write("updateSnapshot: bundle not in allowlist bundleID=\(bundleID)")
            snapshot = FocusedFieldSnapshot(
                fieldID: CFHash(focusedElement),
                context: FieldContext(
                    prefix: "",
                    suffix: "",
                    bundleID: bundleID,
                    elementRole: role ?? ""
                ),
                caretRect: nil,
                fieldBounds: fieldBounds,
                isSecure: false,
                geometryTrusted: false,
                adapterKind: adapterKind
            )
            return
        }


        let fieldMetadata = [
            subrole,
            axString(focusedElement, kAXIdentifierAttribute),
            axString(focusedElement, kAXTitleAttribute),
            axString(focusedElement, kAXDescriptionAttribute),
            axString(focusedElement, kAXHelpAttribute),
        ].compactMap { $0 }
        guard SupportedAppPolicy.allowsField(
            bundleID: bundleID,
            role: role,
            metadata: fieldMetadata
        ) else {
            DebugLog.write(
                "updateSnapshot: field rejected before content bundleID=\(bundleID) role=\(role ?? "nil")"
            )
            snapshot = FocusedFieldSnapshot(
                fieldID: CFHash(focusedElement),
                context: FieldContext(
                    prefix: "",
                    suffix: "",
                    bundleID: bundleID,
                    elementRole: role ?? ""
                ),
                caretRect: nil,
                fieldBounds: fieldBounds,
                isSecure: false,
                geometryTrusted: false,
                adapterKind: adapterKind
            )
            updateDiagnosticsIfKnown(
                bundleID: bundleID,
                role: role,
                adapterKind: adapterKind,
                fieldDecision: "Rejected before content",
                isSecure: false,
                geometryTrusted: false
            )
            return
        }

        let selectedRange = axSelectedTextRange(focusedElement)
        guard let contextValue = axContextValue(
            focusedElement,
            selectedRange: selectedRange
        ) else {
            snapshot = nil
            updateDiagnosticsIfKnown(
                bundleID: bundleID,
                role: role,
                adapterKind: adapterKind,
                fieldDecision: "Unreadable AX value",
                isSecure: false,
                geometryTrusted: false
            )
            return
        }
        let fieldID = CFHash(focusedElement)
        let context = adapter.readContext(
            bundleID: bundleID,
            role: role ?? "",
            fullValue: contextValue.value,
            caretIndex: contextValue.localCaretIndex
        )
        let caretBounds = axCaretBounds(
            at: contextValue.absoluteCaretIndex,
            from: focusedElement
        )
        let caretRect = adapter.caretScreenRect(
            proposed: caretBounds,
            fieldBounds: fieldBounds
        )
        let geometryTrusted = caretRect != nil && adapter.geometryTrusted(
            rect: caretRect,
            fieldBounds: fieldBounds
        )

        snapshot = FocusedFieldSnapshot(
            fieldID: fieldID,
            context: context,
            caretRect: caretRect,
            fieldBounds: fieldBounds,
            isSecure: isSecure,
            geometryTrusted: geometryTrusted,
            adapterKind: adapterKind
        )
        updateDiagnosticsIfKnown(
            bundleID: bundleID,
            role: role,
            adapterKind: adapterKind,
            fieldDecision: "Eligible editable field",
            isSecure: false,
            geometryTrusted: geometryTrusted
        )
        DebugLog.write(
            "updateSnapshot: built snap bundleID=\(bundleID) role=\(role ?? "nil") "
            + "context_utf16=\(contextValue.value.utf16.count) "
            + "caretIndex=\(contextValue.absoluteCaretIndex) "
            + "caretRect=\(caretRect.map { "\($0)" } ?? "nil") "
            + "fieldBounds=\(fieldBounds.map { "\($0)" } ?? "nil") "
            + "geometryTrusted=\(geometryTrusted)"
        )
    }

    private func updateDiagnosticsIfKnown(
        bundleID: String,
        role: String?,
        adapterKind: String,
        fieldDecision: String,
        isSecure: Bool,
        geometryTrusted: Bool
    ) {
        guard SupportedAppPolicy.allowsPredictions(bundleID: bundleID) else {
            return
        }
        lastDiagnostics = AccessibilityDiagnostics(
            bundleID: bundleID,
            role: role ?? "Unknown",
            adapterKind: adapterKind,
            fieldDecision: fieldDecision,
            isSecure: isSecure,
            geometryTrusted: geometryTrusted
        )
    }

    // MARK: - AX Attribute Helpers

    /// Some Electron hosts do not publish their focused editor through the
    /// system-wide element, but do expose it on their application element.
    /// Prefer the app-scoped query and retain the system-wide query as a
    /// compatibility fallback for native hosts.
    private func focusedElement(for pid: pid_t) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(pid)
        if let focused = axElement(
            appElement,
            attribute: kAXFocusedUIElementAttribute
        ) {
            return focused
        }

        return axElement(
            AXUIElementCreateSystemWide(),
            attribute: kAXFocusedUIElementAttribute
        )
    }

    private func axElement(
        _ element: AXUIElement,
        attribute: String
    ) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success,
              let candidate = value,
              CFGetTypeID(candidate) == AXUIElementGetTypeID() else {
            return nil
        }
        return (candidate as! AXUIElement)
    }

    private struct AXContextValue {
        let value: String
        let localCaretIndex: Int
        let absoluteCaretIndex: Int
    }

    /// Prefer AX's parameterized range API so each keystroke reads at most the
    /// bounded caret window. Hosts that do not expose it fall back to one full
    /// read without caching the document in this process.
    private func axContextValue(
        _ element: AXUIElement,
        selectedRange: CFRange?
    ) -> AXContextValue? {
        if let selectedRange,
           let totalLength = axInt(element, kAXNumberOfCharactersAttribute) {
            let requestedCaret = selectedRange.location + selectedRange.length
            let ranges = FieldContext.utf16ContextWindow(
                caretIndex: requestedCaret,
                totalLength: totalLength
            )
            let prefix = ranges.prefixLength == 0
                ? ""
                : axString(
                    element,
                    range: CFRange(
                        location: ranges.prefixLocation,
                        length: ranges.prefixLength
                    )
                )
            let suffix = ranges.suffixLength == 0
                ? ""
                : axString(
                    element,
                    range: CFRange(
                        location: ranges.suffixLocation,
                        length: ranges.suffixLength
                    )
                )
            if let prefix, let suffix {
                return AXContextValue(
                    value: prefix + suffix,
                    localCaretIndex: prefix.utf16.count,
                    absoluteCaretIndex: ranges.suffixLocation
                )
            }
        }

        guard let fullValue = axString(element, kAXValueAttribute) else {
            return nil
        }
        let absoluteCaretIndex = selectedRange.map {
            $0.location + $0.length
        } ?? fullValue.utf16.count
        let bounded = FieldContext.boundedValue(
            fullValue,
            caretIndex: absoluteCaretIndex
        )
        return AXContextValue(
            value: bounded.text,
            localCaretIndex: bounded.caretIndex,
            absoluteCaretIndex: min(
                max(0, absoluteCaretIndex),
                fullValue.utf16.count
            )
        )
    }

    private func axString(_ element: AXUIElement, _ attribute: String) -> String? {
        var val: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &val) == .success else {
            return nil
        }
        return val as? String
    }

    private func axBool(_ element: AXUIElement, _ attribute: String) -> Bool {
        var val: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &val) == .success else {
            return false
        }
        return (val as? Bool) ?? false
    }

    private func axInt(_ element: AXUIElement, _ attribute: String) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success,
              let number = value as? NSNumber else {
            return nil
        }
        let result = number.intValue
        return result >= 0 ? result : nil
    }

    private func axString(_ element: AXUIElement, range: CFRange) -> String? {
        var mutableRange = range
        guard let rangeValue = AXValueCreate(.cfRange, &mutableRange) else {
            return nil
        }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            rangeValue,
            &value
        ) == .success else {
            return nil
        }
        return value as? String
    }

    private func axSelectedTextRange(_ element: AXUIElement) -> CFRange? {
        var val: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &val
        ) == .success else {
            return nil
        }
        guard let candidate = val else { return nil }
        guard CFGetTypeID(candidate) == AXValueGetTypeID() else {
            return nil
        }
        let axValue = candidate as! AXValue
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(axValue, .cfRange, &range),
              range.location >= 0,
              range.length >= 0 else {
            return nil
        }
        return range
    }

    private func axBounds(_ element: AXUIElement) -> CGRect? {
        var posVal: CFTypeRef?
        var sizeVal: CFTypeRef?
        var position = CGPoint.zero
        var size = CGSize.zero

        guard AXUIElementCopyAttributeValue(
            element,
            kAXPositionAttribute as CFString,
            &posVal
        ) == .success,
           let candidate = posVal,
           CFGetTypeID(candidate) == AXValueGetTypeID() else {
            return nil
        }
        let axPos = candidate as! AXValue
        guard AXValueGetValue(axPos, .cgPoint, &position) else {
            return nil
        }

        guard AXUIElementCopyAttributeValue(
            element,
            kAXSizeAttribute as CFString,
            &sizeVal
        ) == .success,
           let candidate = sizeVal,
           CFGetTypeID(candidate) == AXValueGetTypeID() else {
            return nil
        }
        let axSize = candidate as! AXValue
        guard AXValueGetValue(axSize, .cgSize, &size) else {
            return nil
        }

        return Self.validBounds(position: position, size: size)
    }

    nonisolated static func validBounds(
        position: CGPoint,
        size: CGSize
    ) -> CGRect? {
        guard position.x.isFinite,
              position.y.isFinite,
              size.width.isFinite,
              size.height.isFinite,
              size.width > 0,
              size.height > 0 else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    private func axCaretBounds(at caretIndex: Int, from element: AXUIElement) -> CGRect? {
        var cfRange = CFRange(location: caretIndex, length: 0)
        if let rangeAX = AXValueCreate(.cfRange, &cfRange) {
            var boundsVal: CFTypeRef?
            let result = AXUIElementCopyParameterizedAttributeValue(
                element,
                kAXBoundsForRangeParameterizedAttribute as CFString,
                rangeAX,
                &boundsVal
            )
            if result == .success,
               let candidate = boundsVal,
               CFGetTypeID(candidate) == AXValueGetTypeID() {
                let axBounds = candidate as! AXValue
                var rect = CGRect.zero
                if AXValueGetValue(axBounds, .cgRect, &rect),
                   rect.width > 0 || rect.height > 0 {
                    return rect
                }
            }
        }

        return axTextMarkerCaretBounds(from: element)
    }

    /// Chromium and Electron commonly omit `AXBoundsForRange` while exposing
    /// the equivalent text-marker API. The selected marker range is queried
    /// without reading field contents and yields an exact caret rect when the
    /// host supports it.
    private func axTextMarkerCaretBounds(
        from element: AXUIElement
    ) -> CGRect? {
        var markerRange: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            "AXSelectedTextMarkerRange" as CFString,
            &markerRange
        ) == .success,
              let markerRange else {
            return nil
        }

        var boundsVal: CFTypeRef?
        let result = AXUIElementCopyParameterizedAttributeValue(
            element,
            "AXBoundsForTextMarkerRange" as CFString,
            markerRange,
            &boundsVal
        )
        guard result == .success else { return nil }
        guard let candidate = boundsVal else { return nil }
        guard CFGetTypeID(candidate) == AXValueGetTypeID() else {
            return nil
        }
        let axBounds = candidate as! AXValue
        var rect = CGRect.zero
        guard AXValueGetValue(axBounds, .cgRect, &rect) else {
            return nil
        }
        return rect.width > 0 || rect.height > 0 ? rect : nil
    }

    // MARK: - Adapter Kind

    private func adapterKindName(for adapter: any FieldAdapter) -> String {
        if adapter is CodexAdapter { return "codex" }
        if adapter is ChromeElectronAdapter { return "chrome-electron" }
        if adapter is TerminalAdapter { return "terminal" }
        return "native"
    }
}

// MARK: - AX Observer Callback

private func axCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let accessibilityObserver = Unmanaged<AccessibilityObserver>
        .fromOpaque(refcon)
        .takeUnretainedValue()
    let note = notification as String
    Task { @MainActor [weak accessibilityObserver] in
        accessibilityObserver?.handleAXNotification(notification: note)
    }
}

extension AccessibilityObserver {
    fileprivate func handleAXNotification(notification: String) {
        guard isRunning else { return }
        DebugLog.write("ax: notification=\(notification)")

        // Rebuild observer if frontmost app changed
        if let frontApp = NSWorkspace.shared.frontmostApplication,
           frontApp.processIdentifier != currentPID {
            DebugLog.write("ax: app changed (pid \(currentPID) → \(frontApp.processIdentifier))")
            removeObserver()
            installObserver()
        } else if notification == kAXFocusedUIElementChangedNotification as String,
                  let observer {
            refreshElementObservers(
                observer,
                refcon: Unmanaged.passUnretained(self).toOpaque()
            )
        }

        updateSnapshot()
    }

    private func handleApplicationActivation() {
        guard isRunning else { return }
        removeObserver()
        installObserver()
        updateSnapshot()
    }
}
