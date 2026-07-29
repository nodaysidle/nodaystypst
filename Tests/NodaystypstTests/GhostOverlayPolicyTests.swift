import AppKit
import CoreGraphics
import Testing
@testable import Nodaystypst

@Suite("GhostOverlay policy")
struct GhostOverlayPolicyTests {
    @Test("show requires non-empty text and trusted geometry")
    func requiresTextAndTrustedGeometry() {
        #expect(!GhostOverlay.shouldPresent(text: "", geometryTrusted: true))
        #expect(!GhostOverlay.shouldPresent(text: "hello", geometryTrusted: false))
        #expect(GhostOverlay.shouldPresent(text: "hello", geometryTrusted: true))
    }

    @Test("cross-app ghost uses a level above ordinary floating windows")
    func crossAppPresentationLevel() {
        #expect(GhostOverlay.presentationWindowLevel.rawValue > NSWindow.Level.floating.rawValue)
    }

    // MARK: - AX-to-AppKit coordinate conversion (pure, deterministic)

    /// Integer-aligned test helper to avoid floating-point inequality from
    /// different CGFloat/Double computation paths.
    private func assertOrigin(
        _ origin: CGPoint?,
        expectedX: Double,
        expectedY: Double,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(origin != nil, sourceLocation: sourceLocation)
        guard let origin else { return }
        #expect(abs(origin.x - expectedX) < 1e-6, sourceLocation: sourceLocation)
        #expect(abs(origin.y - expectedY) < 1e-6, sourceLocation: sourceLocation)
    }

    @Test("primary display — CG top-left caret maps to AppKit bottom-left origin")
    func primaryDisplayConversion() {
        // 2560×1440 primary display: CG and AppKit both at (0,0)
        let displays = [(cgBounds: CGRect(x: 0, y: 0, width: 2560, height: 1440),
                         nsFrame:  CGRect(x: 0, y: 0, width: 2560, height: 1440))]
        // Live defect repro: AX caret at CG (1692, 63), height 13, panel height 16
        let axRect = CGRect(x: 1692, y: 63, width: 0, height: 13)
        let panelSize = CGSize(width: 200, height: 16)

        let origin = GhostOverlay.convertAXCaretToAppKitOrigin(
            axRect: axRect, panelSize: panelSize, displays: displays
        )

        assertOrigin(origin, expectedX: 1692, expectedY: 1440 - 63 - 16)
    }

    @Test("field banner prefers above-field placement and clamps horizontally")
    func fieldBannerAboveField() {
        let displays = [(
            cgBounds: CGRect(x: 0, y: 0, width: 1_000, height: 800),
            nsFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800)
        )]
        let field = CGRect(x: 930, y: 700, width: 60, height: 44)
        let panel = CGSize(width: 160, height: 24)

        let origin = GhostOverlay.convertAXFieldToAppKitBannerOrigin(
            fieldRect: field,
            panelSize: panel,
            displays: displays
        )

        assertOrigin(
            origin,
            expectedX: 840,
            expectedY: 800 - (700 - 6 - 24) - 24
        )
    }

    @Test("field banner falls below a field near the display top")
    func fieldBannerBelowField() {
        let displays = [(
            cgBounds: CGRect(x: 0, y: 0, width: 1_000, height: 800),
            nsFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800)
        )]
        let field = CGRect(x: 100, y: 4, width: 500, height: 44)
        let panel = CGSize(width: 160, height: 24)

        let origin = GhostOverlay.convertAXFieldToAppKitBannerOrigin(
            fieldRect: field,
            panelSize: panel,
            displays: displays
        )

        assertOrigin(
            origin,
            expectedX: 100,
            expectedY: 800 - (48 + 6) - 24
        )
    }

    @Test("offset secondary display — caret on right-hand monitor maps correctly")
    func offsetSecondaryDisplayConversion() {
        // Primary: (0,0,2560,1440). Secondary right: CG (2560,0,1920,1080), NS (2560,0,1920,1080)
        let displays = [
            (cgBounds: CGRect(x: 0,     y: 0, width: 2560, height: 1440),
             nsFrame:  CGRect(x: 0,     y: 0, width: 2560, height: 1440)),
            (cgBounds: CGRect(x: 2560,  y: 0, width: 1920, height: 1080),
             nsFrame:  CGRect(x: 2560,  y: 0, width: 1920, height: 1080)),
        ]
        // Caret on secondary at CG (3000, 200), panel height 14
        let axRect = CGRect(x: 3000, y: 200, width: 0, height: 12)
        let panelSize = CGSize(width: 180, height: 14)

        let origin = GhostOverlay.convertAXCaretToAppKitOrigin(
            axRect: axRect, panelSize: panelSize, displays: displays
        )

        assertOrigin(origin, expectedX: 3000, expectedY: 1080 - 200 - 14)
    }

    @Test("above-below display arrangement — caret on upper monitor maps correctly")
    func aboveBelowDisplayArrangement() {
        // Primary bottom: AppKit (0,0,2560,1440), CG (0,1440,2560,1440) — y-flipped
        // Secondary top:  AppKit (0,1440,2560,1200), CG (0,0,2560,1200)
        let displays = [
            (cgBounds: CGRect(x: 0, y: 1440, width: 2560, height: 1440),
             nsFrame:  CGRect(x: 0, y: 0,    width: 2560, height: 1440)),
            (cgBounds: CGRect(x: 0, y: 0,    width: 2560, height: 1200),
             nsFrame:  CGRect(x: 0, y: 1440, width: 2560, height: 1200)),
        ]
        // Caret on top (secondary) display at CG (800, 100)
        let axRect = CGRect(x: 800, y: 100, width: 0, height: 11)
        let panelSize = CGSize(width: 150, height: 13)

        let origin = GhostOverlay.convertAXCaretToAppKitOrigin(
            axRect: axRect, panelSize: panelSize, displays: displays
        )

        assertOrigin(origin, expectedX: 800, expectedY: 2640 - 100 - 13)
    }

    @Test("NaN in axRect origin returns nil")
    func nanAxRectReturnsNil() {
        let displays = [(cgBounds: CGRect(x: 0, y: 0, width: 2560, height: 1440),
                         nsFrame:  CGRect(x: 0, y: 0, width: 2560, height: 1440))]
        let axRect = CGRect(x: Double.nan, y: 63, width: 0, height: 13)
        let panelSize = CGSize(width: 200, height: 16)

        let origin = GhostOverlay.convertAXCaretToAppKitOrigin(
            axRect: axRect, panelSize: panelSize, displays: displays
        )
        #expect(origin == nil)
    }

    @Test("infinite panelSize returns nil")
    func infinitePanelSizeReturnsNil() {
        let displays = [(cgBounds: CGRect(x: 0, y: 0, width: 2560, height: 1440),
                         nsFrame:  CGRect(x: 0, y: 0, width: 2560, height: 1440))]
        let axRect = CGRect(x: 100, y: 200, width: 0, height: 13)
        let panelSize = CGSize(width: Double.infinity, height: 16)

        let origin = GhostOverlay.convertAXCaretToAppKitOrigin(
            axRect: axRect, panelSize: panelSize, displays: displays
        )
        #expect(origin == nil)
    }

    @Test("caret outside all displays returns nil")
    func caretOutsideAllDisplaysReturnsNil() {
        let displays = [(cgBounds: CGRect(x: 0, y: 0, width: 2560, height: 1440),
                         nsFrame:  CGRect(x: 0, y: 0, width: 2560, height: 1440))]
        // Point at x = -1 is left of the display
        let axRect = CGRect(x: -1, y: 300, width: 0, height: 13)
        let panelSize = CGSize(width: 200, height: 16)

        let origin = GhostOverlay.convertAXCaretToAppKitOrigin(
            axRect: axRect, panelSize: panelSize, displays: displays
        )
        #expect(origin == nil)
    }

    @Test("empty displays list returns nil")
    func emptyDisplaysReturnsNil() {
        let axRect = CGRect(x: 100, y: 200, width: 0, height: 13)
        let panelSize = CGSize(width: 200, height: 16)

        let origin = GhostOverlay.convertAXCaretToAppKitOrigin(
            axRect: axRect, panelSize: panelSize, displays: []
        )
        #expect(origin == nil)
    }

    @Test("zero-width zero-height axRect on primary display still maps")
    func zeroWidthZeroHeightAxRect() {
        // AX caret rects are often zero-width with only a height
        let displays = [(cgBounds: CGRect(x: 0, y: 0, width: 2560, height: 1440),
                         nsFrame:  CGRect(x: 0, y: 0, width: 2560, height: 1440))]
        let axRect = CGRect(x: 500, y: 800, width: 0, height: 0)
        let panelSize = CGSize(width: 120, height: 15)

        let origin = GhostOverlay.convertAXCaretToAppKitOrigin(
            axRect: axRect, panelSize: panelSize, displays: displays
        )

        assertOrigin(origin, expectedX: 500, expectedY: 1440 - 800 - 15)
    }

    @Test("caret exactly on display boundary minX/minY maps to that display")
    func caretOnDisplayBoundaryMapsCorrectly() {
        let displays = [
            (cgBounds: CGRect(x: 0,     y: 0, width: 2560, height: 1440),
             nsFrame:  CGRect(x: 0,     y: 0, width: 2560, height: 1440)),
            (cgBounds: CGRect(x: 2560,  y: 0, width: 1920, height: 1080),
             nsFrame:  CGRect(x: 2560,  y: 0, width: 1920, height: 1080)),
        ]
        // Exactly at secondary display origin (maxX boundary of first, minX of second)
        let axRect = CGRect(x: 2560, y: 0, width: 1, height: 14)
        let panelSize = CGSize(width: 100, height: 14)

        let origin = GhostOverlay.convertAXCaretToAppKitOrigin(
            axRect: axRect, panelSize: panelSize, displays: displays
        )

        assertOrigin(origin, expectedX: 2560, expectedY: 1080 - 0 - 14)
    }
}
