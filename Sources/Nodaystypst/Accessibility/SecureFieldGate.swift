import Foundation

enum SecureFieldGate {
    static func isSecure(
        role: String?,
        subrole: String?,
        isPasswordField: Bool
    ) -> Bool {
        if isPasswordField {
            return true
        }

        let markers = ["AXSecureTextField", "secure", "password"]
        let attributes = [role, subrole]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")

        if markers.contains(where: { attributes.contains($0.lowercased()) }) {
            return true
        }

        if subrole == "AXSecureTextField" {
            return true
        }

        return false
    }
}
