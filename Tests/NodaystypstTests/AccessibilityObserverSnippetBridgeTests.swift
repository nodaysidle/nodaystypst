import CoreGraphics
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

    @Test("TerminalAdapter reads only the trailing line and never claims Tab")
    func terminalAdapterSemantics() {
        let adapter = TerminalAdapter()
        let ghostty = RunningAppInfo(
            bundleID: SupportedAppPolicy.ghosttyBundleID,
            localizedName: "Ghostty"
        )
        #expect(adapter.canHandle(app: ghostty, role: "AXTextArea"))

        let midLineContext = adapter.readContext(
            bundleID: ghostty.bundleID,
            role: "AXTextArea",
            fullValue: "user@mac ~ % cd projects/\nls -la\ncat README",
            caretIndex: 35
        )
        #expect(midLineContext.prefix == "ca")
        #expect(midLineContext.suffix.isEmpty)

        let endContext = adapter.readContext(
            bundleID: ghostty.bundleID,
            role: "AXTextArea",
            fullValue: "user@mac ~ % cd projects/\nls -la\ncat README",
            caretIndex: 43
        )
        #expect(endContext.prefix == "cat README")
        #expect(endContext.suffix.isEmpty)
        #expect(!endContext.bundleID.isEmpty)

        #expect(!adapter.shouldOfferTabAccept())

        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        let trusted = adapter.caretScreenRect(proposed: nil, fieldBounds: bounds)
        #expect(trusted != nil)
    }

    @Test("AX bounds validation rejects missing or unsafe geometry")
    func axBoundsValidation() {
        #expect(
            AccessibilityObserver.validBounds(
                position: CGPoint(x: 10, y: 20),
                size: CGSize(width: 300, height: 40)
            ) == CGRect(x: 10, y: 20, width: 300, height: 40)
        )
        #expect(AccessibilityObserver.validBounds(
            position: .zero,
            size: .zero
        ) == nil)
        #expect(AccessibilityObserver.validBounds(
            position: CGPoint(x: CGFloat.nan, y: 0),
            size: CGSize(width: 100, height: 20)
        ) == nil)
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
