import Foundation
import Testing
@testable import Nodaystypst

@Suite("App preferences")
@MainActor
struct AppPreferencesTests {
    @Test("retired default migrates to Gemma while custom choice remains")
    func modelMigration() {
        let suiteName = "nodaystypst-preferences-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("mistralai/ministral-3b-2512", forKey: "modelId")
        var preferences = AppPreferences(defaults: defaults)
        #expect(preferences.modelId == "google/gemma-4-26b-a4b-it")

        defaults.set("custom/model", forKey: "modelId")
        preferences = AppPreferences(defaults: defaults)
        #expect(preferences.modelId == "custom/model")
    }

    @Test("learning is enabled by default and can be disabled per app")
    func learningControls() {
        let suiteName = "nodaystypst-learning-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = AppPreferences(defaults: defaults)
        #expect(preferences.isLearningEnabled(for: "app"))
        preferences.setLearningEnabled(false, for: "app")
        #expect(!preferences.isLearningEnabled(for: "app"))
        preferences.setLearningEnabled(true, for: "app")
        #expect(preferences.isLearningEnabled(for: "app"))
    }
}
