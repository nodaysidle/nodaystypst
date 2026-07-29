import CoreGraphics

/// Dedicated adapter for the ChatGPT/Codex macOS composer.
///
/// Codex exposes its ProseMirror value and selection through AX, but its
/// zero-length and character-range bounds are pinned to the screen edge.
/// Rather than synthesize an unreliable inline caret, this adapter returns
/// the verified field rectangle for a visually distinct field-anchored ghost.
/// The fallback is deliberately limited to a collapsed selection at the end
/// of a non-empty value.
final class CodexAdapter: FieldAdapter {
    static let bundleID = "com.openai.codex"

    private var hasEligibleEndCaret = false

    func canHandle(app: RunningAppInfo, role: String?) -> Bool {
        app.bundleID == Self.bundleID && role == "AXTextArea"
    }

    func readContext(
        bundleID: String,
        role: String,
        fullValue: String,
        caretIndex: Int
    ) -> FieldContext {
        hasEligibleEndCaret = !fullValue.isEmpty
            && caretIndex == fullValue.utf16.count

        let clampedOffset = min(max(caretIndex, 0), fullValue.utf16.count)
        let index = String.Index(utf16Offset: clampedOffset, in: fullValue)
        return FieldContext(
            prefix: FieldContext.boundedPrefix(String(fullValue[..<index])),
            suffix: String(fullValue[index...]),
            bundleID: bundleID,
            elementRole: role
        )
    }

    func caretScreenRect(proposed: CGRect?, fieldBounds: CGRect?) -> CGRect? {
        guard hasEligibleEndCaret,
              let fieldBounds,
              Self.isTrustedFieldBounds(fieldBounds) else {
            return nil
        }
        return fieldBounds
    }

    func geometryTrusted(rect: CGRect?, fieldBounds: CGRect?) -> Bool {
        guard hasEligibleEndCaret,
              let rect,
              let fieldBounds,
              rect == fieldBounds else {
            return false
        }
        return Self.isTrustedFieldBounds(fieldBounds)
    }

    func shouldOfferTabAccept() -> Bool {
        true
    }

    private static func isTrustedFieldBounds(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite
            && rect.origin.y.isFinite
            && rect.width.isFinite
            && rect.height.isFinite
            && rect.width >= 120
            && rect.height >= 20
            && rect.height <= 400
    }
}
