import CoreGraphics
import Foundation

/// Adapter for terminal emulators that surface a single text-field AX element
/// (Ghostty today). Reads only the trailing line as prediction context, trusts
/// geometry only when the proposed caret rect falls inside the terminal's
/// content bounds, and **never** claims Tab to avoid clobbering shell
/// completion. Hosts such as Opencode's TUI inherit Ghostty's behaviour when
/// they run inside it.
final class TerminalAdapter: FieldAdapter {
    func canHandle(app: RunningAppInfo, role: String?) -> Bool {
        app.bundleID == SupportedAppPolicy.ghosttyBundleID
    }

    func readContext(
        bundleID: String,
        role: String,
        fullValue: String,
        caretIndex: Int
    ) -> FieldContext {
        let clampedOffset = min(max(caretIndex, 0), fullValue.utf16.count)
        let caret = String.Index(utf16Offset: clampedOffset, in: fullValue)
        let valueBeforeCaret = fullValue[..<caret]
        let lines = valueBeforeCaret.split(
            separator: "\n",
            omittingEmptySubsequences: false
        )
        let trailingLine = lines.last.map(String.init) ?? ""

        return FieldContext(
            prefix: FieldContext.boundedPrefix(trailingLine),
            suffix: "",
            bundleID: bundleID,
            elementRole: role
        )
    }

    func geometryTrusted(rect: CGRect?, fieldBounds: CGRect?) -> Bool {
        guard let rect,
              let fieldBounds,
              rect.origin.x.isFinite,
              rect.origin.y.isFinite,
              rect.size.width.isFinite,
              rect.size.height.isFinite,
              fieldBounds.width > 0,
              fieldBounds.height > 0 else {
            return false
        }
        return fieldBounds.insetBy(dx: -2, dy: -2).contains(rect.origin)
    }

    func caretScreenRect(proposed: CGRect?, fieldBounds: CGRect?) -> CGRect? {
        if let proposed,
           geometryTrusted(rect: proposed, fieldBounds: fieldBounds) {
            return proposed
        }
        guard let fieldBounds, fieldBounds.width > 0, fieldBounds.height > 0 else {
            return nil
        }
        let lineHeight = max(8, fieldBounds.height > 200 ? 18 : fieldBounds.height)
        return CGRect(
            x: fieldBounds.minX,
            y: fieldBounds.maxY - lineHeight,
            width: 0,
            height: lineHeight
        )
    }

    func shouldOfferTabAccept() -> Bool {
        false
    }
}
