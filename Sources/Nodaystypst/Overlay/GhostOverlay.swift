import AppKit

/// Non-activating, click-through ghost overlay panel.
///
/// GhostOverlay renders prediction text as a muted floating panel near the
/// caret without stealing focus or accepting mouse events. The panel is an
/// NSPanel styled `.nonactivatingPanel` with `ignoresMouseEvents = true`
/// and a status-window level, so clicks pass straight through to the host
/// application.
///
/// ## Trust Model
/// Callers that have verified caret geometry pass `geometryTrusted: true`.
/// The required 3-argument `show(text:screenRect:font:)` always forwards
/// with `geometryTrusted: true` because it is the caller's responsibility
/// to supply a trusted screen-space rect. Untrusted or empty text
/// immediately hides the overlay.
@MainActor
final class GhostOverlay {

    enum Placement: Equatable {
        case inline
        case fieldBanner
    }

    private final class OverlayPanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    // MARK: - Policy

    /// Returns `true` when text is non-empty and geometry has been
    /// verified by an adapter. Used by callers that want to gate
    /// presentation before allocating an NSPanel.
    nonisolated static func shouldPresent(text: String, geometryTrusted: Bool) -> Bool {
        !text.isEmpty && geometryTrusted
    }

    /// A normal floating window is constrained behind the active app's
    /// windows. Status level keeps the non-activating ghost above the host.
    nonisolated static let presentationWindowLevel: NSWindow.Level = .statusBar

    // MARK: - Public state

    private(set) var isVisible = false
    private(set) var currentText: String?

    // MARK: - Private state

    private var panel: NSPanel?
    private var textField: NSTextField?

    // MARK: - Show / hide

    /// Required 3-argument show per Phase A plan.
    ///
    /// Forwards to the trust-aware overload with `geometryTrusted: true`.
    /// Callers must supply a trusted screen-space `CGRect`.
    func show(text: String, screenRect: CGRect, font: NSFont? = nil) {
        show(
            text: text,
            screenRect: screenRect,
            font: font,
            geometryTrusted: true,
            placement: .inline
        )
    }

    /// Safe overload that gates display on geometry trust.
    ///
    /// Empty text or untrusted geometry immediately calls `hide()`.
    /// Otherwise the panel is created (once), positioned, and brought
    /// front without changing the key or main window.
    func show(
        text: String,
        screenRect: CGRect,
        font: NSFont?,
        geometryTrusted: Bool,
        placement: Placement = .inline
    ) {
        guard GhostOverlay.shouldPresent(text: text, geometryTrusted: geometryTrusted) else {
            hide()
            return
        }

        if panel == nil {
            createPanel()
        }

        guard let panel, let textField else { return }

        let panelSize = configureTextField(
            textField,
            in: panel,
            text: text,
            font: font,
            placement: placement
        )
        guard positionPanel(
            panel,
            panelSize: panelSize,
            at: screenRect,
            placement: placement
        ) else {
            hide()
            return
        }

        panel.orderFrontRegardless()
        currentText = text
        isVisible = panel.isVisible
    }

    /// Hides the panel and clears visible state.
    func hide() {
        panel?.orderOut(nil)
        isVisible = false
        currentText = nil
    }

    // MARK: - Panel setup (one-shot)

    private func createPanel() {
        let p = OverlayPanel(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.becomesKeyOnlyIfNeeded = false
        p.ignoresMouseEvents = true
        p.level = Self.presentationWindowLevel
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        p.isOpaque = false
        p.hasShadow = false
        p.backgroundColor = .clear
        p.isReleasedWhenClosed = false

        let tf = NSTextField(labelWithAttributedString: NSAttributedString())
        // A fixed mid-grey remains legible over both light and dark host
        // fields; semantic label colors resolve against this app's appearance,
        // which may be the opposite of the frontmost app's appearance.
        tf.textColor = NSColor(calibratedWhite: 0.45, alpha: 1.0)
        tf.alignment = .left
        tf.lineBreakMode = .byWordWrapping
        tf.maximumNumberOfLines = 0
        tf.cell?.wraps = true

        p.contentView?.addSubview(tf)
        textField = tf
        panel = p
    }

    // MARK: - Content & position

    private func configureTextField(
        _ tf: NSTextField,
        in panel: NSPanel,
        text: String,
        font: NSFont?,
        placement: Placement
    ) -> CGSize {
        let isBanner = placement == .fieldBanner
        let renderedText = isBanner ? "Tab  \(text)" : text
        let attrString = NSAttributedString(
            string: renderedText,
            attributes: [
                .font: font ?? (isBanner
                    ? NSFont.systemFont(ofSize: 12, weight: .medium)
                    : NSFont.monospacedSystemFont(
                        ofSize: NSFont.systemFontSize,
                        weight: .regular
                    )),
            ]
        )
        tf.attributedStringValue = attrString
        tf.sizeToFit()

        let horizontalPadding: CGFloat = isBanner ? 9 : 0
        let verticalPadding: CGFloat = isBanner ? 5 : 0
        let panelSize = CGSize(
            width: tf.frame.width + horizontalPadding * 2,
            height: tf.frame.height + verticalPadding * 2
        )
        panel.setContentSize(panelSize)
        tf.frame.origin = CGPoint(x: horizontalPadding, y: verticalPadding)

        panel.contentView?.wantsLayer = isBanner
        panel.contentView?.layer?.backgroundColor = isBanner
            ? NSColor(calibratedWhite: 0.12, alpha: 0.90).cgColor
            : NSColor.clear.cgColor
        panel.contentView?.layer?.cornerRadius = isBanner ? 7 : 0
        return panelSize
    }

    // MARK: - AX-to-AppKit coordinate conversion

    /// Convert a Quartz/CG screen-space caret rectangle to an AppKit window
    /// origin point using explicit display mappings, for deterministic testing.
    ///
    /// Each tuple is `(cgBounds: CGDisplayBounds, nsFrame: NSScreen.frame)`.
    /// Returns `nil` when the caret does not fall within any mapped display
    /// or when any coordinate is non-finite.
    nonisolated static func convertAXCaretToAppKitOrigin(
        axRect: CGRect,
        panelSize: CGSize,
        displays: [(cgBounds: CGRect, nsFrame: CGRect)]
    ) -> CGPoint? {
        guard axRect.origin.x.isFinite,
              axRect.origin.y.isFinite,
              axRect.size.width.isFinite,
              axRect.size.height.isFinite,
              panelSize.width.isFinite,
              panelSize.height.isFinite
        else { return nil }

        let anchor = axRect.origin

        for (cgBounds, nsFrame) in displays {
            guard anchor.x >= cgBounds.minX,
                  anchor.x < cgBounds.maxX,
                  anchor.y >= cgBounds.minY,
                  anchor.y < cgBounds.maxY
            else { continue }

            let appKitX = nsFrame.minX + (anchor.x - cgBounds.minX)
            let appKitY = nsFrame.maxY - (anchor.y - cgBounds.minY) - panelSize.height
            return CGPoint(x: appKitX, y: appKitY)
        }

        return nil
    }

    /// Places a detached fallback immediately above a verified AX field, or
    /// below it when the field is too close to the display's top edge.
    /// The banner is clamped horizontally to the same display.
    nonisolated static func convertAXFieldToAppKitBannerOrigin(
        fieldRect: CGRect,
        panelSize: CGSize,
        displays: [(cgBounds: CGRect, nsFrame: CGRect)],
        gap: CGFloat = 6
    ) -> CGPoint? {
        guard fieldRect.origin.x.isFinite,
              fieldRect.origin.y.isFinite,
              fieldRect.width.isFinite,
              fieldRect.height.isFinite,
              fieldRect.width > 0,
              fieldRect.height > 0,
              panelSize.width.isFinite,
              panelSize.height.isFinite,
              panelSize.width > 0,
              panelSize.height > 0 else {
            return nil
        }

        let fieldAnchor = CGPoint(x: fieldRect.midX, y: fieldRect.midY)
        for (cgBounds, nsFrame) in displays where cgBounds.contains(fieldAnchor) {
            guard panelSize.width <= cgBounds.width,
                  panelSize.height <= cgBounds.height else {
                return nil
            }

            let preferredY = fieldRect.minY - gap - panelSize.height
            let fallbackY = fieldRect.maxY + gap
            let cgY: CGFloat
            if preferredY >= cgBounds.minY {
                cgY = preferredY
            } else if fallbackY + panelSize.height <= cgBounds.maxY {
                cgY = fallbackY
            } else {
                return nil
            }

            let cgX = min(
                max(fieldRect.minX, cgBounds.minX),
                cgBounds.maxX - panelSize.width
            )
            return CGPoint(
                x: nsFrame.minX + (cgX - cgBounds.minX),
                y: nsFrame.maxY - (cgY - cgBounds.minY) - panelSize.height
            )
        }
        return nil
    }

    /// Live-display convenience: enumerates `NSScreen.screens` and maps each to
    /// its `CGDirectDisplayID` via `NSDeviceDescriptionKey("NSScreenNumber")`.
    nonisolated static func convertAXCaretToAppKitOrigin(
        axRect: CGRect,
        panelSize: CGSize
    ) -> CGPoint? {
        let displays = NSScreen.screens.compactMap { screen -> (CGRect, CGRect)? in
            guard let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { return nil }
            return (CGDisplayBounds(num.uint32Value), screen.frame)
        }
        return convertAXCaretToAppKitOrigin(axRect: axRect, panelSize: panelSize, displays: displays)
    }

    /// Position the panel at the trusted screen-space anchor supplied by
    /// the active field adapter, converting from Quartz/CG coordinates
    /// (top-left origin) to AppKit frame coordinates (bottom-left origin).
    ///
    /// When the display cannot be mapped or the caret anchor falls outside
    /// every known display, the panel is hidden rather than misdrawn.
    @discardableResult
    private func positionPanel(
        _ panel: NSPanel,
        panelSize: CGSize,
        at screenRect: CGRect,
        placement: Placement
    ) -> Bool {
        let origin: CGPoint?
        switch placement {
        case .inline:
            origin = GhostOverlay.convertAXCaretToAppKitOrigin(
                axRect: screenRect,
                panelSize: panelSize
            )
        case .fieldBanner:
            let displays = NSScreen.screens.compactMap { screen -> (CGRect, CGRect)? in
                guard let number = screen.deviceDescription[
                    NSDeviceDescriptionKey("NSScreenNumber")
                ] as? NSNumber else { return nil }
                return (CGDisplayBounds(number.uint32Value), screen.frame)
            }
            origin = GhostOverlay.convertAXFieldToAppKitBannerOrigin(
                fieldRect: screenRect,
                panelSize: panelSize,
                displays: displays
            )
        }
        guard let origin else {
            return false
        }

        let panelFrame = NSRect(
            x: origin.x,
            y: origin.y,
            width: panelSize.width,
            height: panelSize.height
        )
        panel.setFrame(panelFrame, display: false)
        return true
    }
}
