import Testing
@testable import Nodaystypst

@Suite("SecureFieldGate")
struct SecureFieldGateTests {
    @Test("blocks password role")
    func passwordRole() {
        #expect(
            SecureFieldGate.isSecure(
                role: "AXTextField",
                subrole: "AXSecureTextField",
                isPasswordField: false
            )
        )
        #expect(
            SecureFieldGate.isSecure(
                role: "AXTextField",
                subrole: nil,
                isPasswordField: true
            )
        )
    }

    @Test("blocks secure and password markers case-insensitively")
    func secureMarkers() {
        #expect(
            SecureFieldGate.isSecure(
                role: "AXSecureTextField",
                subrole: nil,
                isPasswordField: false
            )
        )
        #expect(
            SecureFieldGate.isSecure(
                role: "AXTextField",
                subrole: "password-entry",
                isPasswordField: false
            )
        )
    }

    @Test("allows normal text area")
    func normalField() {
        #expect(
            !SecureFieldGate.isSecure(
                role: "AXTextArea",
                subrole: nil,
                isPasswordField: false
            )
        )
    }
}
