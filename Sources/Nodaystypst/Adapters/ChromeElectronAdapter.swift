@preconcurrency import ApplicationServices
import CoreGraphics

final class ChromeElectronAdapter: FieldAdapter {
    private static let supportedBundleIDs: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.canary",
        SupportedAppPolicy.obsidianBundleID,
        "com.todesktop.230313mzl4w4u92",
        "com.microsoft.VSCode",
    ]

    private static let geometryTolerance: CGFloat = 2
    private static let caretJumpDiagonalFraction: CGFloat = 0.5

    private let forceUntrustedGeometryForDebug: Bool
    private var currentRole: String?
    private var focusedElementAppearsAddressBar = false
    private var pendingValue: String?
    private var previousSampleValue: String?
    private var previousCaretRect: CGRect?

    init(forceUntrustedGeometryForDebug: Bool = false) {
        self.forceUntrustedGeometryForDebug = forceUntrustedGeometryForDebug
    }

    func canHandle(app: RunningAppInfo, role: String?) -> Bool {
        guard Self.supportedBundleIDs.contains(app.bundleID) else {
            return false
        }
        currentRole = role
        focusedElementAppearsAddressBar = Self.isAddressBarRole(role)
            || Self.focusedAXElementAppearsAddressBar()
        return true
    }

    func readContext(
        bundleID: String,
        role: String,
        fullValue: String,
        caretIndex: Int
    ) -> FieldContext {
        currentRole = role
        pendingValue = fullValue

        let clampedOffset = min(max(caretIndex, 0), fullValue.utf16.count)
        let index = String.Index(utf16Offset: clampedOffset, in: fullValue)
        let rawPrefix = String(fullValue[..<index])

        return FieldContext(
            prefix: FieldContext.boundedPrefix(rawPrefix),
            suffix: String(fullValue[index...]),
            bundleID: bundleID,
            elementRole: role
        )
    }

    func caretScreenRect(proposed: CGRect?, fieldBounds: CGRect?) -> CGRect? {
        guard baselineGeometryTrusted(rect: proposed, fieldBounds: fieldBounds) else {
            return nil
        }
        return proposed
    }

    func geometryTrusted(rect: CGRect?, fieldBounds: CGRect?) -> Bool {
        guard baselineGeometryTrusted(rect: rect, fieldBounds: fieldBounds),
              let rect,
              let fieldBounds else {
            return false
        }

        let valueUnchanged = previousSampleValue != nil
            && previousSampleValue == pendingValue
        if let previousCaretRect,
           isCaretJumpUntrusted(
               previous: previousCaretRect,
               next: rect,
               fieldBounds: fieldBounds,
               valueUnchanged: valueUnchanged
           ) {
            previousSampleValue = pendingValue
            return false
        }

        previousCaretRect = rect
        previousSampleValue = pendingValue
        return true
    }

    func isCaretJumpUntrusted(
        previous: CGRect,
        next: CGRect,
        fieldBounds: CGRect,
        valueUnchanged: Bool
    ) -> Bool {
        guard valueUnchanged,
              Self.isFinite(previous),
              Self.isFinite(next),
              Self.isFinite(fieldBounds),
              fieldBounds.width > 0,
              fieldBounds.height > 0 else {
            return false
        }

        let deltaX = next.midX - previous.midX
        let deltaY = next.midY - previous.midY
        let caretDistance = hypot(deltaX, deltaY)
        let fieldDiagonal = hypot(fieldBounds.width, fieldBounds.height)
        return caretDistance > fieldDiagonal * Self.caretJumpDiagonalFraction
    }

    func shouldOfferTabAccept() -> Bool {
        !forceUntrustedGeometryForDebug
            && !focusedElementAppearsAddressBar
            && !Self.isAddressBarRole(currentRole)
    }

    private func baselineGeometryTrusted(rect: CGRect?, fieldBounds: CGRect?) -> Bool {
        guard !forceUntrustedGeometryForDebug,
              !focusedElementAppearsAddressBar,
              !Self.isAddressBarRole(currentRole),
              let rect,
              let fieldBounds,
              Self.isFinite(rect),
              Self.isFinite(fieldBounds),
              rect.height > 0,
              rect.width >= 0,
              fieldBounds.width > 0,
              fieldBounds.height > 0 else {
            return false
        }

        let toleratedBounds = fieldBounds.insetBy(
            dx: -Self.geometryTolerance,
            dy: -Self.geometryTolerance
        )
        let caretAnchor = CGPoint(x: rect.midX, y: rect.midY)
        return toleratedBounds.contains(caretAnchor)
            && rect.height <= toleratedBounds.height
    }

    private static func isAddressBarRole(_ role: String?) -> Bool {
        guard let role = role?.lowercased() else { return false }
        return role.contains("address")
            || role.contains("omnibox")
            || role.contains("location")
            || role.contains("searchfield")
            || role.contains("combobox")
    }

    static func metadataLooksLikeAddressBar(_ values: [String]) -> Bool {
        values.contains { value in
            let normalized = value.lowercased()
            return normalized.contains("address and search")
                || normalized.contains("address bar")
                || normalized.contains("omnibox")
                || normalized.contains("location bar")
                || normalized.contains("search or enter address")
        }
    }

    private static func focusedAXElementAppearsAddressBar() -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success,
              let focusedElement = focusedValue as! AXUIElement? else {
            return false
        }

        let metadataAttributes = [
            kAXIdentifierAttribute,
            kAXTitleAttribute,
            kAXDescriptionAttribute,
            kAXHelpAttribute,
            kAXSubroleAttribute,
        ]
        let values = metadataAttributes.compactMap { attribute -> String? in
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                focusedElement,
                attribute as CFString,
                &value
            ) == .success else {
                return nil
            }
            return value as? String
        }
        return metadataLooksLikeAddressBar(values)
    }

    private static func isFinite(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite
            && rect.origin.y.isFinite
            && rect.width.isFinite
            && rect.height.isFinite
    }
}
