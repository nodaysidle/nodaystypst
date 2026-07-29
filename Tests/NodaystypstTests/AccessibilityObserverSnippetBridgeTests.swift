import Testing
@testable import Nodaystypst

@Suite("AccessibilityObserver mapping")
struct AccessibilityObserverSnippetBridgeTests {
    @Test("content-blind refresh is scoped to Orion and Antinote")
    func contentBlindRefreshScope() {
        #expect(AccessibilityObserver.shouldUseContentBlindRefresh(
            bundleID: "com.kagi.kagimacOS"
        ))
        #expect(!AccessibilityObserver.shouldUseContentBlindRefresh(
            bundleID: "com.openai.codex"
        ))
        #expect(AccessibilityObserver.shouldUseContentBlindRefresh(
            bundleID: "com.chabomakers.Antinote"
        ))
        #expect(!AccessibilityObserver.shouldUseContentBlindRefresh(
            bundleID: "net.shinyfrog.bear"
        ))
        #expect(!AccessibilityObserver.shouldUseContentBlindRefresh(
            bundleID: "com.apple.TextEdit"
        ))
    }

    @Test("secure snapshots never expose long secrets as predict-ready")
    func secureFlag() {
        let snapshot = FocusedFieldSnapshot(
            fieldID: 1,
            context: FieldContext(
                prefix: "",
                suffix: "",
                bundleID: "com.apple.Notes",
                elementRole: "AXTextField"
            ),
            caretRect: nil,
            fieldBounds: nil,
            isSecure: true,
            geometryTrusted: false,
            adapterKind: "native"
        )

        #expect(snapshot.isSecure)
        #expect(snapshot.context.prefix.isEmpty)
        #expect(!snapshot.geometryTrusted)
    }
}
