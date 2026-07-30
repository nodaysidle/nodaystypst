import AppKit

@MainActor
final class DesktopSettingsViewController: NSViewController, NSTextFieldDelegate {
    private let services: AppServices
    private let showsQADiagnostics: Bool
    private let learningTargets = SupportedAppPolicy.targets

    private let keyField = NSSecureTextField()
    private let keyStatusLabel = NSTextField(labelWithString: "Checking Keychain…")
    private let learningStatusLabel = NSTextField(labelWithString: "")
    private let accessibilityStatusLabel = NSTextField(labelWithString: "")
    private let accessibilityDetailLabel = NSTextField(wrappingLabelWithString: "")
    private weak var initialFocusView: NSView?
    private lazy var saveKeyButton = makeButton(
        "Save",
        action: #selector(saveAPIKey)
    )

    init(services: AppServices, showsQADiagnostics: Bool) {
        self.services = services
        self.showsQADiagnostics = showsQADiagnostics
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: 520, height: 760)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        let documentView = FlippedView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        let contentStack = NSStackView()
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 18
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        documentView.addSubview(contentStack)
        scrollView.documentView = documentView
        NSLayoutConstraint.activate([
            documentView.widthAnchor.constraint(
                equalTo: scrollView.contentView.widthAnchor
            ),
            contentStack.topAnchor.constraint(
                equalTo: documentView.topAnchor,
                constant: 22
            ),
            contentStack.leadingAnchor.constraint(
                equalTo: documentView.leadingAnchor,
                constant: 24
            ),
            contentStack.trailingAnchor.constraint(
                equalTo: documentView.trailingAnchor,
                constant: -24
            ),
            contentStack.bottomAnchor.constraint(
                equalTo: documentView.bottomAnchor,
                constant: -24
            ),
        ])

        contentStack.addArrangedSubview(makePredictionsSection())
        contentStack.addArrangedSubview(makeOpenRouterSection())
        contentStack.addArrangedSubview(makeLearningSection())
        if showsQADiagnostics {
            contentStack.addArrangedSubview(makeDiagnosticsSection())
        }
        contentStack.addArrangedSubview(makeCompatibilitySection())
        contentStack.addArrangedSubview(makeAccessibilitySection())

        let footer = makeSecondaryText(
            "Closing this window keeps nodaystypst running. Click its Dock icon to reopen Settings."
        )
        contentStack.addArrangedSubview(footer)

        for arrangedView in contentStack.arrangedSubviews {
            arrangedView.widthAnchor.constraint(
                equalTo: contentStack.widthAnchor
            ).isActive = true
        }

        view = scrollView
        refreshKeyStatus()
        refreshAccessibilityStatus()
    }

    func refresh() {
        refreshKeyStatus()
        refreshAccessibilityStatus()
    }

    var preferredInitialFirstResponder: NSView? {
        _ = view
        return initialFocusView
    }

    func controlTextDidChange(_ notification: Notification) {
        saveKeyButton.isEnabled = !keyField.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }

    private func makePredictionsSection() -> NSView {
        let pauseToggle = makeCheckbox(
            "Pause predictions",
            isOn: services.preferences.isPaused,
            action: #selector(togglePause)
        )
        initialFocusView = pauseToggle
        return makeSection(
            title: "Predictions",
            views: [
                pauseToggle,
                makeSecondaryText(
                    "When a completion appears, one Tab inserts the whole shown phrase. Continuing to type dismisses it."
                ),
            ]
        )
    }

    private func makeOpenRouterSection() -> NSView {
        keyField.placeholderString = "OpenRouter API key"
        keyField.delegate = self
        keyField.usesSingleLineMode = true
        keyField.setAccessibilityLabel("API key")
        saveKeyButton.isEnabled = false
        keyStatusLabel.textColor = .secondaryLabelColor

        let saveRow = makeHorizontalStack([saveKeyButton, keyStatusLabel])
        return makeSection(
            title: "OpenRouter",
            views: [
                makeSecondaryText(
                    "Model: \(services.preferences.modelId)"
                ),
                keyField,
                saveRow,
            ]
        )
    }

    private func makeLearningSection() -> NSView {
        var views: [NSView] = [
            makeCheckbox(
                "Personalize predictions",
                isOn: services.preferences.learningEnabled,
                action: #selector(toggleGlobalLearning)
            ),
            makeSecondaryText(
                "Stores encrypted, bounded word and style statistics—not documents or typing history. Secure fields and AI-inserted text never contribute."
            ),
        ]

        for (index, target) in learningTargets.enumerated() {
            let toggle = makeCheckbox(
                target.name,
                isOn: !services.preferences.disabledLearningBundleIds.contains(
                    target.bundleID
                ),
                action: #selector(toggleAppLearning(_:))
            )
            toggle.tag = index

            let resetButton = makeButton(
                "Reset",
                action: #selector(resetAppLearning(_:))
            )
            resetButton.tag = index
            resetButton.bezelStyle = .inline

            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            views.append(makeHorizontalStack([toggle, spacer, resetButton]))
        }

        let clearButton = makeButton(
            "Clear All Learned Data",
            action: #selector(confirmResetAllLearning)
        )
        clearButton.contentTintColor = .systemRed
        learningStatusLabel.textColor = .secondaryLabelColor
        learningStatusLabel.isHidden = true
        views.append(clearButton)
        views.append(learningStatusLabel)
        return makeSection(title: "Learns Your Writing", views: views)
    }

    private func makeDiagnosticsSection() -> NSView {
        let diagnostics = services.accessibilityObserver.lastDiagnostics
        let coordinator = services.completionCoordinator
        return makeSection(
            title: "QA Diagnostics",
            views: [
                makeValueRow(
                    "Prediction loop",
                    coordinator.isRunningForDiagnostics ? "Running" : "Stopped"
                ),
                makeValueRow(
                    "Focused host",
                    diagnostics?.bundleID ?? "No verified field yet"
                ),
                makeValueRow("Adapter", diagnostics?.adapterKind ?? "None"),
                makeValueRow(
                    "Secure field",
                    diagnostics?.isSecure == true ? "Blocked" : "No"
                ),
                makeValueRow(
                    "Caret geometry",
                    diagnostics?.geometryTrusted == true ? "Trusted" : "Hidden"
                ),
                makeValueRow(
                    "Ghost overlay",
                    coordinator.isOverlayVisibleForDiagnostics
                        ? "Visible"
                        : "Hidden"
                ),
                makeSecondaryText(
                    "Diagnostics never display field text or API-key contents."
                ),
            ]
        )
    }

    private func makeCompatibilitySection() -> NSView {
        makeSection(
            title: "Compatibility",
            views: [
                makeValueRow(
                    "Tab completion",
                    SupportedAppPolicy.tabAcceptTargets
                        .map(\.name)
                        .joined(separator: ", ")
                ),
                makeValueRow(
                    "Display only",
                    SupportedAppPolicy.displayOnlyTargets
                        .map(\.name)
                        .joined(separator: ", ")
                ),
                makeValueRow(
                    "Safe-rejected",
                    SupportedAppPolicy.safeRejectedTargets
                        .map(\.name)
                        .joined(separator: ", ")
                ),
                makeSecondaryText(
                    "Secure fields, browser address/search bars, code editors, and hosts without trusted caret geometry remain content-blind. Ghostty keeps Tab for shell completion."
                ),
            ]
        )
    }

    private func makeAccessibilitySection() -> NSView {
        accessibilityStatusLabel.font = .systemFont(
            ofSize: NSFont.systemFontSize,
            weight: .semibold
        )
        accessibilityDetailLabel.textColor = .secondaryLabelColor

        let requestButton = makeButton(
            "Request Access",
            action: #selector(requestAccessibility)
        )
        let settingsButton = makeButton(
            "Open System Settings",
            action: #selector(openAccessibilitySettings)
        )
        let refreshButton = makeButton(
            "Refresh Status",
            action: #selector(refreshAccessibility)
        )
        return makeSection(
            title: "Accessibility",
            views: [
                accessibilityStatusLabel,
                accessibilityDetailLabel,
                makeHorizontalStack([
                    requestButton,
                    settingsButton,
                    refreshButton,
                ]),
            ]
        )
    }

    @objc private func togglePause(_ sender: NSButton) {
        services.preferences.isPaused = sender.state == .on
    }

    @objc private func toggleGlobalLearning(_ sender: NSButton) {
        services.preferences.learningEnabled = sender.state == .on
    }

    @objc private func toggleAppLearning(_ sender: NSButton) {
        guard learningTargets.indices.contains(sender.tag) else { return }
        services.preferences.setLearningEnabled(
            sender.state == .on,
            for: learningTargets[sender.tag].bundleID
        )
    }

    @objc private func resetAppLearning(_ sender: NSButton) {
        guard learningTargets.indices.contains(sender.tag) else { return }
        let target = learningTargets[sender.tag]
        Task {
            let succeeded = await services.resetLearning(
                bundleID: target.bundleID
            )
            showLearningStatus(
                succeeded
                    ? "Cleared learned data for \(target.name)."
                    : "Could not clear learned data for \(target.name)."
            )
        }
    }

    @objc private func confirmResetAllLearning() {
        let alert = NSAlert()
        alert.messageText = "Clear all learned data?"
        alert.informativeText = "This permanently removes the encrypted aggregate writing profile. Documents and raw typing are not stored."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear Learned Data")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        Task {
            let succeeded = await services.resetAllLearning()
            showLearningStatus(
                succeeded
                    ? "Cleared all learned data."
                    : "Could not clear learned data."
            )
        }
    }

    @objc private func saveAPIKey() {
        let key = keyField.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }

        saveKeyButton.isEnabled = false
        keyStatusLabel.stringValue = "Saving…"
        let store = services.keychainStore
        Task {
            let succeeded = await Task.detached(priority: .userInitiated) {
                do {
                    try store.saveAPIKey(key)
                    return true
                } catch {
                    return false
                }
            }.value

            if succeeded {
                keyField.stringValue = ""
                keyStatusLabel.stringValue = "API key saved."
                services.preferences.lastError = nil
            } else {
                keyStatusLabel.stringValue = "Could not save API key."
                services.preferences.lastError = "Could not save API key."
            }
            controlTextDidChange(
                Notification(name: NSControl.textDidChangeNotification)
            )
            view.window?.makeFirstResponder(preferredInitialFirstResponder)
        }
    }

    private func refreshKeyStatus() {
        keyStatusLabel.stringValue = "Checking Keychain…"
        let store = services.keychainStore
        Task {
            let status = await Task.detached(priority: .userInitiated) {
                do {
                    return try store.loadAPIKey() == nil
                        ? "No API key saved."
                        : "API key saved."
                } catch {
                    return "Could not read API key."
                }
            }.value
            keyStatusLabel.stringValue = status
            if status == "Could not read API key." {
                services.preferences.lastError = status
            }
        }
    }

    @objc private func requestAccessibility() {
        AccessibilityPermission.promptIfNeeded()
        refreshAccessibilityStatus()
    }

    @objc private func openAccessibilitySettings() {
        AccessibilityPermission.openSystemSettings()
    }

    @objc private func refreshAccessibility() {
        refreshAccessibilityStatus()
    }

    private func refreshAccessibilityStatus() {
        services.refreshAccessibilityStatus()
        accessibilityStatusLabel.stringValue = services.accessibilityTrusted
            ? "Accessibility granted"
            : "Accessibility required"
        accessibilityDetailLabel.stringValue = services.accessibilityTrusted
            ? "nodaystypst can access supported text fields."
            : "Predictions stay disabled until Accessibility access is granted."
    }

    private func showLearningStatus(_ message: String) {
        learningStatusLabel.stringValue = message
        learningStatusLabel.isHidden = false
    }

    private func makeSection(title: String, views: [NSView]) -> NSView {
        let box = NSBox()
        box.title = title
        box.titlePosition = .atTop
        box.boxType = .primary
        box.contentViewMargins = NSSize(width: 14, height: 14)

        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        guard let contentView = box.contentView else { return box }
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
        for view in views {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return box
    }

    private func makeHorizontalStack(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        return stack
    }

    private func makeValueRow(_ label: String, _ value: String) -> NSView {
        let nameLabel = NSTextField(labelWithString: label)
        nameLabel.font = .systemFont(
            ofSize: NSFont.systemFontSize,
            weight: .medium
        )
        let valueLabel = NSTextField(wrappingLabelWithString: value)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.alignment = .right
        valueLabel.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return makeHorizontalStack([nameLabel, spacer, valueLabel])
    }

    private func makeSecondaryText(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func makeCheckbox(
        _ title: String,
        isOn: Bool,
        action: Selector
    ) -> NSButton {
        let button = NSButton(
            checkboxWithTitle: title,
            target: self,
            action: action
        )
        button.state = isOn ? .on : .off
        return button
    }

    private func makeButton(_ title: String, action: Selector) -> NSButton {
        NSButton(title: title, target: self, action: action)
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
