import CoreGraphics

struct RunningAppInfo: Sendable {
    var bundleID: String
    var localizedName: String
}

enum AdapterError: Error {
    case insertFailed
}

protocol FieldAdapter: AnyObject {
    func canHandle(app: RunningAppInfo, role: String?) -> Bool
    func isSecure(role: String?, subrole: String?, isPasswordField: Bool) -> Bool
    func readContext(
        bundleID: String,
        role: String,
        fullValue: String,
        caretIndex: Int
    ) -> FieldContext
    func caretScreenRect(proposed: CGRect?, fieldBounds: CGRect?) -> CGRect?
    func geometryTrusted(rect: CGRect?, fieldBounds: CGRect?) -> Bool
    func insertAcceptedText(
        _ text: String,
        intoCurrentValue value: String,
        caretIndex: Int
    ) throws -> String
    func shouldOfferTabAccept() -> Bool
}

extension FieldAdapter {
    func isSecure(role: String?, subrole: String?, isPasswordField: Bool) -> Bool {
        SecureFieldGate.isSecure(
            role: role,
            subrole: subrole,
            isPasswordField: isPasswordField
        )
    }

    func readContext(
        bundleID: String,
        role: String,
        fullValue: String,
        caretIndex: Int
    ) -> FieldContext {
        let index = clampedStringIndex(in: fullValue, offset: caretIndex)
        let rawPrefix = String(fullValue[..<index])
        let suffix = String(fullValue[index...])

        return FieldContext(
            prefix: FieldContext.boundedPrefix(rawPrefix),
            suffix: suffix,
            bundleID: bundleID,
            elementRole: role
        )
    }

    func caretScreenRect(proposed: CGRect?, fieldBounds: CGRect?) -> CGRect? {
        nil
    }

    func geometryTrusted(rect: CGRect?, fieldBounds: CGRect?) -> Bool {
        false
    }

    func insertAcceptedText(
        _ text: String,
        intoCurrentValue value: String,
        caretIndex: Int
    ) throws -> String {
        let index = clampedStringIndex(in: value, offset: caretIndex)
        return String(value[..<index]) + text + String(value[index...])
    }

    func shouldOfferTabAccept() -> Bool {
        false
    }

    private func clampedStringIndex(in value: String, offset: Int) -> String.Index {
        let clampedOffset = min(max(offset, 0), value.utf16.count)
        return String.Index(utf16Offset: clampedOffset, in: value)
    }
}
