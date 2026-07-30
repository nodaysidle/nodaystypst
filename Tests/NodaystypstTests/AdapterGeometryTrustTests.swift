import CoreGraphics
import Testing
@testable import Nodaystypst

@Suite("Codex field-anchored fallback")
struct CodexAdapterTests {
    @Test("registry routes the Codex composer to its dedicated adapter")
    func routing() {
        let registry = AdapterRegistry()
        let app = RunningAppInfo(
            bundleID: CodexAdapter.bundleID,
            localizedName: "ChatGPT"
        )

        #expect(registry.adapter(for: app, role: "AXTextArea") is CodexAdapter)
        #expect(registry.adapter(for: app, role: "AXButton") is NativeAdapter)
    }

    @Test("end-caret context trusts only bounded field geometry")
    func endCaretGeometry() {
        let adapter = CodexAdapter()
        let field = CGRect(x: 1_074, y: 1_278, width: 713, height: 44)
        let app = RunningAppInfo(
            bundleID: CodexAdapter.bundleID,
            localizedName: "ChatGPT"
        )
        #expect(adapter.canHandle(app: app, role: "AXTextArea"))

        let value = "Codex predictions should"
        _ = adapter.readContext(
            bundleID: CodexAdapter.bundleID,
            role: "AXTextArea",
            fullValue: value,
            caretIndex: value.utf16.count
        )

        let anchor = adapter.caretScreenRect(proposed: nil, fieldBounds: field)
        #expect(anchor == field)
        #expect(adapter.geometryTrusted(rect: anchor, fieldBounds: field))
        #expect(adapter.shouldOfferTabAccept())
    }

    @Test("mid-text caret and malformed fields hide")
    func rejection() {
        let adapter = CodexAdapter()
        let field = CGRect(x: 20, y: 20, width: 500, height: 44)

        _ = adapter.readContext(
            bundleID: CodexAdapter.bundleID,
            role: "AXTextArea",
            fullValue: "hello world",
            caretIndex: 5
        )
        #expect(adapter.caretScreenRect(proposed: nil, fieldBounds: field) == nil)

        _ = adapter.readContext(
            bundleID: CodexAdapter.bundleID,
            role: "AXTextArea",
            fullValue: "hello world",
            caretIndex: 11
        )
        #expect(adapter.caretScreenRect(
            proposed: nil,
            fieldBounds: CGRect(x: 20, y: 20, width: 80, height: 44)
        ) == nil)
        #expect(adapter.caretScreenRect(
            proposed: nil,
            fieldBounds: CGRect(x: 20, y: 20, width: 500, height: 800)
        ) == nil)
    }
}

@Suite("ChromeElectron caret jump")
struct ChromeElectronCaretJumpTests {
    @Test("large jump without value change is untrusted")
    func jump() {
        let adapter = ChromeElectronAdapter()
        let field = CGRect(x: 0, y: 0, width: 400, height: 200)
        let a = CGRect(x: 10, y: 10, width: 5, height: 12)
        let b = CGRect(x: 300, y: 180, width: 5, height: 12)

        #expect(adapter.isCaretJumpUntrusted(
            previous: a,
            next: b,
            fieldBounds: field,
            valueUnchanged: true
        ))
        #expect(!adapter.isCaretJumpUntrusted(
            previous: a,
            next: CGRect(x: 12, y: 10, width: 5, height: 12),
            fieldBounds: field,
            valueUnchanged: true
        ))
        #expect(!adapter.isCaretJumpUntrusted(
            previous: a,
            next: b,
            fieldBounds: field,
            valueUnchanged: false
        ))
    }

    @Test("consecutive unchanged samples reject a large Chromium jump")
    func consecutiveSamples() {
        let adapter = ChromeElectronAdapter()
        let field = CGRect(x: 0, y: 0, width: 400, height: 200)
        let a = CGRect(x: 10, y: 10, width: 5, height: 12)
        let b = CGRect(x: 300, y: 180, width: 5, height: 12)

        _ = adapter.readContext(
            bundleID: "com.google.Chrome",
            role: "AXTextArea",
            fullValue: "unchanged",
            caretIndex: 9
        )
        #expect(adapter.geometryTrusted(rect: a, fieldBounds: field))

        _ = adapter.readContext(
            bundleID: "com.google.Chrome",
            role: "AXTextArea",
            fullValue: "unchanged",
            caretIndex: 9
        )
        #expect(!adapter.geometryTrusted(rect: b, fieldBounds: field))

        _ = adapter.readContext(
            bundleID: "com.google.Chrome",
            role: "AXTextArea",
            fullValue: "changed",
            caretIndex: 7
        )
        #expect(adapter.geometryTrusted(rect: b, fieldBounds: field))
    }

    @Test("forced untrusted and address bar paths hide")
    func forcedUntrustedAndAddressBar() {
        let field = CGRect(x: 0, y: 0, width: 400, height: 200)
        let caret = CGRect(x: 10, y: 10, width: 5, height: 12)
        let forced = ChromeElectronAdapter(forceUntrustedGeometryForDebug: true)
        #expect(forced.caretScreenRect(proposed: caret, fieldBounds: field) == nil)
        #expect(!forced.geometryTrusted(rect: caret, fieldBounds: field))

        let addressBar = ChromeElectronAdapter()
        let chrome = RunningAppInfo(bundleID: "com.google.Chrome", localizedName: "Chrome")
        #expect(addressBar.canHandle(app: chrome, role: "AXAddressField"))
        #expect(!addressBar.shouldOfferTabAccept())
        #expect(!addressBar.geometryTrusted(rect: caret, fieldBounds: field))

        let pageInput = ChromeElectronAdapter()
        #expect(pageInput.canHandle(app: chrome, role: "AXTextField"))
        #expect(pageInput.shouldOfferTabAccept())
    }

    @Test("Chrome address metadata and full insertion policies are deterministic")
    func metadataAndInsertion() throws {
        #expect(ChromeElectronAdapter.metadataLooksLikeAddressBar([
            "Address and search bar",
        ]))
        #expect(!ChromeElectronAdapter.metadataLooksLikeAddressBar([
            "Search this documentation",
        ]))

        let adapter = ChromeElectronAdapter()
        let value = "hello 🌍world"
        let caret = "hello 🌍".utf16.count
        let inserted = try adapter.insertAcceptedText(
            " brave ",
            intoCurrentValue: value,
            caretIndex: caret
        )
        #expect(inserted == "hello 🌍 brave world")
    }

    @Test("Chromium geometry rejects missing, non-finite, and off-field carets")
    func strictGeometry() {
        let adapter = ChromeElectronAdapter()
        let field = CGRect(x: 0, y: 0, width: 400, height: 200)

        #expect(adapter.caretScreenRect(proposed: nil, fieldBounds: field) == nil)
        #expect(adapter.caretScreenRect(proposed: .zero, fieldBounds: field) == nil)
        #expect(adapter.caretScreenRect(
            proposed: CGRect(x: 500, y: 300, width: 2, height: 14),
            fieldBounds: field
        ) == nil)
        #expect(!adapter.geometryTrusted(
            rect: CGRect(x: CGFloat.infinity, y: 10, width: 2, height: 14),
            fieldBounds: field
        ))
    }
}

@Suite("Adapter geometry trust")
struct AdapterGeometryTrustTests {
    @Test("nil or zero rect is untrusted")
    func nilOrZero() {
        let adapter = NativeAdapter()
        let field = CGRect(x: 0, y: 0, width: 100, height: 20)
        #expect(!adapter.geometryTrusted(rect: nil, fieldBounds: field))
        #expect(!adapter.geometryTrusted(rect: .zero, fieldBounds: field))
    }

    @Test("rect outside field bounds is untrusted")
    func outsideBounds() {
        let adapter = NativeAdapter()
        let field = CGRect(x: 0, y: 0, width: 100, height: 20)
        let bad = CGRect(x: 500, y: 500, width: 10, height: 10)
        #expect(!adapter.geometryTrusted(rect: bad, fieldBounds: field))

        let good = CGRect(x: 10, y: 2, width: 8, height: 14)
        #expect(adapter.geometryTrusted(rect: good, fieldBounds: field))
    }

    @Test("caret rect is returned only when geometry is trusted")
    func caretRectPolicy() {
        let adapter = NativeAdapter()
        let field = CGRect(x: 0, y: 0, width: 100, height: 20)
        let good = CGRect(x: 99, y: 2, width: 2, height: 14)
        let tolerated = CGRect(x: 101, y: 2, width: 0.5, height: 14)
        let bad = CGRect(x: 200, y: 2, width: 2, height: 14)

        #expect(adapter.caretScreenRect(proposed: good, fieldBounds: field) == good)
        #expect(adapter.geometryTrusted(rect: tolerated, fieldBounds: field))
        #expect(adapter.caretScreenRect(proposed: bad, fieldBounds: field) == nil)
        #expect(!adapter.geometryTrusted(rect: good, fieldBounds: nil))
    }

    @Test("native context bounds the prefix and preserves suffix")
    func readContext() {
        let adapter = NativeAdapter()
        let rawPrefix = String(repeating: "x", count: 1_200)
        let context = adapter.readContext(
            bundleID: "com.apple.Notes",
            role: "AXTextArea",
            fullValue: rawPrefix + "tail",
            caretIndex: rawPrefix.count
        )

        #expect(context.prefix.count == PredictionConstants.maxPrefixCharacters)
        #expect(context.prefix == String(rawPrefix.suffix(PredictionConstants.maxPrefixCharacters)))
        #expect(context.suffix == "tail")
        #expect(context.bundleID == "com.apple.Notes")
        #expect(context.elementRole == "AXTextArea")
    }

    @Test("context and insertion clamp invalid caret offsets")
    func caretOffsetClamping() throws {
        let adapter = NativeAdapter()
        let beforeStart = adapter.readContext(
            bundleID: "test",
            role: "AXTextArea",
            fullValue: "hello",
            caretIndex: -10
        )
        let afterEnd = try adapter.insertAcceptedText(
            "!",
            intoCurrentValue: "hello",
            caretIndex: 100
        )

        #expect(beforeStart.prefix.isEmpty)
        #expect(beforeStart.suffix == "hello")
        #expect(afterEnd == "hello!")
    }

    @Test("context uses Accessibility UTF-16 caret offsets")
    func utf16CaretOffset() {
        let adapter = NativeAdapter()
        let expectedPrefix = "hello 👋"
        let context = adapter.readContext(
            bundleID: "test",
            role: "AXTextArea",
            fullValue: expectedPrefix + " world",
            caretIndex: expectedPrefix.utf16.count
        )

        #expect(context.prefix == expectedPrefix)
        #expect(context.suffix == " world")
    }

    @Test("native insertion returns the accepted text at the caret")
    func insertAcceptedText() throws {
        let adapter = NativeAdapter()
        let result = try adapter.insertAcceptedText(
            " ",
            intoCurrentValue: "helloworld",
            caretIndex: 5
        )
        #expect(result == "hello world")
        #expect(adapter.shouldOfferTabAccept())
    }

    @Test("zero-width positive-height native caret is trusted")
    func zeroWidthCaretTrusted() {
        let adapter = NativeAdapter()
        let field = CGRect(x: 0, y: 0, width: 400, height: 200)

        let zeroWidth = CGRect(x: 50, y: 10, width: 0, height: 14)
        #expect(adapter.geometryTrusted(rect: zeroWidth, fieldBounds: field))
        #expect(adapter.caretScreenRect(proposed: zeroWidth, fieldBounds: field) == zeroWidth)
    }

    @Test("native adapter rejects zero height, non-finite rects, and out-of-bounds carets")
    func rejectsInvalidGeometry() {
        let adapter = NativeAdapter()
        let field = CGRect(x: 0, y: 0, width: 400, height: 200)

        // zero height
        #expect(!adapter.geometryTrusted(
            rect: CGRect(x: 50, y: 10, width: 2, height: 0),
            fieldBounds: field
        ))

        // non-finite origin
        #expect(!adapter.geometryTrusted(
            rect: CGRect(x: CGFloat.infinity, y: 10, width: 2, height: 14),
            fieldBounds: field
        ))

        // non-finite width (NaN)
        #expect(!adapter.geometryTrusted(
            rect: CGRect(x: 50, y: 10, width: CGFloat.nan, height: 14),
            fieldBounds: field
        ))

        // non-finite field bounds
        #expect(!adapter.geometryTrusted(
            rect: CGRect(x: 50, y: 10, width: 2, height: 14),
            fieldBounds: CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 200)
        ))

        // out-of-bounds (caret anchor outside tolerated field)
        #expect(!adapter.geometryTrusted(
            rect: CGRect(x: 500, y: 300, width: 2, height: 14),
            fieldBounds: field
        ))
    }

    @Test("registry prefers chrome adapter for Chrome bundle id")
    func registryChrome() {
        let registry = AdapterRegistry()
        let app = RunningAppInfo(
            bundleID: "com.google.Chrome",
            localizedName: "Chrome"
        )
        let adapter = registry.adapter(for: app, role: "AXTextField")
        #expect(adapter is ChromeElectronAdapter)
    }

    @Test("registry selects Ghostty and falls back to native")
    func registryOrder() {
        let registry = AdapterRegistry()
        let ghostty = RunningAppInfo(
            bundleID: "com.mitchellh.ghostty",
            localizedName: "Ghostty"
        )
        let notes = RunningAppInfo(
            bundleID: "com.apple.Notes",
            localizedName: "Notes"
        )

        let terminal = registry.adapter(for: ghostty, role: "AXTextArea")
        #expect(terminal is TerminalAdapter)
        #expect(!terminal.shouldOfferTabAccept())
        #expect(registry.adapter(for: notes, role: "AXTextArea") is NativeAdapter)
    }

    @Test("Chrome and supported Electron bundle ids use the dedicated adapter")
    func chromeElectronBundleIDs() {
        let adapter = ChromeElectronAdapter()
        let bundleIDs = [
            "com.google.Chrome",
            "com.google.Chrome.canary",
            SupportedAppPolicy.obsidianBundleID,
            "com.todesktop.230313mzl4w4u92",
            "com.microsoft.VSCode",
        ]

        for bundleID in bundleIDs {
            let app = RunningAppInfo(bundleID: bundleID, localizedName: bundleID)
            #expect(adapter.canHandle(app: app, role: "AXTextField"))
        }
        #expect(adapter.shouldOfferTabAccept())
        #expect(!adapter.geometryTrusted(rect: .zero, fieldBounds: .zero))
    }
}
