import Testing
@testable import Nodaystypst

@Suite("AccessibilityPermission")
struct AccessibilityPermissionTests {
    @Test("isTrusted returns a Bool without crashing")
    func isTrustedCallable() {
        let _: Bool = AccessibilityPermission.isTrusted()
    }
}
