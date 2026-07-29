import SwiftUI

struct SettingsView: View {
    let services: AppServices
    @Environment(\.scenePhase) private var scenePhase
    @State private var apiKey = ""
    @State private var keyStatus: String?
    @State private var learningStatus: String?

    private let learningTargets: [(name: String, bundleID: String)] = [
        ("Orion", SupportedAppPolicy.orionBundleID),
        ("Antinote", SupportedAppPolicy.antinoteBundleID),
    ]

    var body: some View {
        Form {
            Section("Predictions") {
                Toggle(
                    "Pause predictions",
                    isOn: Binding(
                        get: { services.preferences.isPaused },
                        set: { services.preferences.isPaused = $0 }
                    )
                )
            }

            Section("OpenRouter") {
                Text("Model: Gemma 4 26B A4B")
                    .foregroundStyle(.secondary)

                SecureField("API key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Button("Save") {
                        saveAPIKey()
                    }
                    .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if let keyStatus {
                        Text(keyStatus)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Learns Your Writing") {
                Toggle(
                    "Personalize predictions",
                    isOn: Binding(
                        get: { services.preferences.learningEnabled },
                        set: { services.preferences.learningEnabled = $0 }
                    )
                )

                Text(
                    "Stores encrypted, bounded word and style statistics—not documents or typing history. Repeated signals may be included in the compact profile sent with an OpenRouter request. Secure fields never contribute."
                )
                .foregroundStyle(.secondary)

                ForEach(learningTargets, id: \.bundleID) { target in
                    HStack {
                        Toggle(
                            target.name,
                            isOn: Binding(
                                get: {
                                    !services.preferences.disabledLearningBundleIds.contains(
                                        target.bundleID
                                    )
                                },
                                set: {
                                    services.preferences.setLearningEnabled(
                                        $0,
                                        for: target.bundleID
                                    )
                                }
                            )
                        )

                        Button("Reset") {
                            resetLearning(bundleID: target.bundleID, name: target.name)
                        }
                        .buttonStyle(.borderless)
                    }
                }

                Button("Clear All Learned Data", role: .destructive) {
                    resetAllLearning()
                }

                if let learningStatus {
                    Text(learningStatus)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Accessibility") {
                Label(
                    services.accessibilityTrusted ? "Accessibility granted" : "Accessibility required",
                    systemImage: services.accessibilityTrusted ? "checkmark.shield" : "exclamationmark.shield"
                )

                Text(
                    services.accessibilityTrusted
                        ? "nodaystypst can access supported text fields."
                        : "Predictions stay disabled until Accessibility access is granted."
                )
                .foregroundStyle(.secondary)

                HStack {
                    if !services.accessibilityTrusted {
                        Button("Request Access") {
                            AccessibilityPermission.promptIfNeeded()
                            services.refreshAccessibilityStatus()
                        }

                        Button("Open System Settings") {
                            AccessibilityPermission.openSystemSettings()
                        }
                    }

                    Button("Refresh Status") {
                        services.refreshAccessibilityStatus()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .padding()
        .onAppear {
            refreshKeyStatus()
            services.refreshAccessibilityStatus()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                services.refreshAccessibilityStatus()
            }
        }
    }

    private func saveAPIKey() {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            return
        }

        do {
            try services.keychainStore.saveAPIKey(key)
            apiKey = ""
            keyStatus = "API key saved."
            services.preferences.lastError = nil
        } catch {
            keyStatus = "Could not save API key."
            services.preferences.lastError = "Could not save API key."
        }
    }

    private func refreshKeyStatus() {
        do {
            keyStatus = try services.keychainStore.loadAPIKey() == nil
                ? "No API key saved."
                : "API key saved."
        } catch {
            keyStatus = "Could not read API key."
            services.preferences.lastError = "Could not read API key."
        }
    }

    private func resetLearning(bundleID: String, name: String) {
        Task {
            let succeeded = await services.resetLearning(bundleID: bundleID)
            learningStatus = succeeded
                ? "Cleared learned data for \(name)."
                : "Could not clear learned data for \(name)."
        }
    }

    private func resetAllLearning() {
        Task {
            let succeeded = await services.resetAllLearning()
            learningStatus = succeeded
                ? "Cleared all learned data."
                : "Could not clear learned data."
        }
    }
}
