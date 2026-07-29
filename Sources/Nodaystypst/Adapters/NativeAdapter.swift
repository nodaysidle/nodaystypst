import CoreGraphics

final class NativeAdapter: FieldAdapter {
    func canHandle(app: RunningAppInfo, role: String?) -> Bool {
        true
    }

    func geometryTrusted(rect: CGRect?, fieldBounds: CGRect?) -> Bool {
        guard let rect,
              rect.width >= 0,
              rect.height > 0,
              Self.isFinite(rect) else {
            return false
        }
        guard let fieldBounds,
              !fieldBounds.isEmpty,
              Self.isFinite(fieldBounds) else {
            return false
        }
        return fieldBounds.insetBy(dx: -2, dy: -2).intersects(rect)
    }

    private static func isFinite(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite
            && rect.origin.y.isFinite
            && rect.width.isFinite
            && rect.height.isFinite
    }

    func caretScreenRect(proposed: CGRect?, fieldBounds: CGRect?) -> CGRect? {
        guard geometryTrusted(rect: proposed, fieldBounds: fieldBounds) else {
            return nil
        }
        return proposed
    }

    func shouldOfferTabAccept() -> Bool {
        true
    }
}
