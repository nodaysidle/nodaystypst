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

// MARK: - AccessibilityObserver

@MainActor
@Observable
final class AccessibilityObserver {
    private(set) var snapshot: FocusedFieldSnapshot?

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
              let observer else { return }

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

        let systemWide = AXUIElementCreateSystemWide()
        var focusedVal: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedVal
        ) == .success,
              let focusedElement = focusedVal as! AXUIElement? else { return }

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
            return
        }

        guard let source = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            tap,
            0
        ) else {
            CFMachPortInvalidate(tap)
            return
        }

        contentBlindEventTap = tap
        contentBlindRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
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
            if let contentBlindEventTap {
                CGEvent.tapEnable(tap: contentBlindEventTap, enable: true)
            }
            return
        }
        guard type == .keyDown else { return }

        guard isRunning,
              let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              Self.shouldUseContentBlindRefresh(bundleID: bundleID) else {
            return
        }

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
            snapshot = nil
            return
        }

        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            snapshot = nil
            return
        }

        let bundleID = frontApp.bundleIdentifier ?? "unknown"
        let appName = frontApp.localizedName ?? "Unknown"
        let appInfo = RunningAppInfo(bundleID: bundleID, localizedName: appName)

        let systemWide = AXUIElementCreateSystemWide()
        var focusedVal: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedVal
        ) == .success,
              let focusedElement = focusedVal as! AXUIElement? else {
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
            return
        }

        // Stay content-blind outside the two user-selected targets. This also
        // prevents prediction, learning, overlays, and Tab monitoring there.
        guard SupportedAppPolicy.allowsPredictions(bundleID: bundleID) else {
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

        let fullValue = axString(focusedElement, kAXValueAttribute) ?? ""
        let selectedRange = axSelectedTextRange(focusedElement)
        let caretIndex = selectedRange.map { $0.location + $0.length }
            ?? fullValue.utf16.count
        let context = adapter.readContext(
            bundleID: bundleID,
            role: role ?? "",
            fullValue: fullValue,
            caretIndex: caretIndex
        )
        let caretBounds = axCaretBounds(at: caretIndex, from: focusedElement)
        let caretRect = adapter.caretScreenRect(
            proposed: caretBounds,
            fieldBounds: fieldBounds
        )
        let geometryTrusted = caretRect != nil && adapter.geometryTrusted(
            rect: caretRect,
            fieldBounds: fieldBounds
        )

        snapshot = FocusedFieldSnapshot(
            fieldID: CFHash(focusedElement),
            context: context,
            caretRect: caretRect,
            fieldBounds: fieldBounds,
            isSecure: isSecure,
            geometryTrusted: geometryTrusted,
            adapterKind: adapterKind
        )
    }

    // MARK: - AX Attribute Helpers

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

    private func axSelectedTextRange(_ element: AXUIElement) -> CFRange? {
        var val: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &val
        ) == .success,
              let axValue = val as! AXValue? else {
            return nil
        }
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

        if AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posVal) == .success,
           let axPos = posVal as! AXValue? {
            AXValueGetValue(axPos, .cgPoint, &position)
        }
        if AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeVal) == .success,
           let axSize = sizeVal as! AXValue? {
            AXValueGetValue(axSize, .cgSize, &size)
        }

        guard size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: position, size: size)
    }

    private func axCaretBounds(at caretIndex: Int, from element: AXUIElement) -> CGRect? {
        var cfRange = CFRange(location: caretIndex, length: 0)
        guard let rangeAX = AXValueCreate(.cfRange, &cfRange) else { return nil }

        var boundsVal: CFTypeRef?
        let result = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeAX,
            &boundsVal
        )
        guard result == .success, let axBounds = boundsVal as! AXValue? else {
            return nil
        }
        var rect = CGRect.zero
        AXValueGetValue(axBounds, .cgRect, &rect)
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

        // Rebuild observer if frontmost app changed
        if let frontApp = NSWorkspace.shared.frontmostApplication,
           frontApp.processIdentifier != currentPID {
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
