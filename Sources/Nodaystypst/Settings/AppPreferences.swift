import Foundation
import Observation

@MainActor
@Observable
final class AppPreferences {
    private enum Keys {
        static let isPaused = "isPaused"
        static let modelId = "modelId"
        static let learningEnabled = "learningEnabled"
        static let disabledLearningBundleIds = "disabledLearningBundleIds"
    }

    private let defaults: UserDefaults

    var isPaused: Bool {
        didSet {
            defaults.set(isPaused, forKey: Keys.isPaused)
        }
    }

    var lastError: String?

    var modelId: String {
        didSet {
            defaults.set(modelId, forKey: Keys.modelId)
        }
    }

    var learningEnabled: Bool {
        didSet {
            defaults.set(learningEnabled, forKey: Keys.learningEnabled)
        }
    }

    private(set) var disabledLearningBundleIds: Set<String> {
        didSet {
            defaults.set(
                Array(disabledLearningBundleIds).sorted(),
                forKey: Keys.disabledLearningBundleIds
            )
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.isPaused = defaults.bool(forKey: Keys.isPaused)
        self.lastError = nil
        self.learningEnabled = defaults.object(forKey: Keys.learningEnabled) as? Bool ?? true
        self.disabledLearningBundleIds = Set(
            defaults.stringArray(forKey: Keys.disabledLearningBundleIds) ?? []
        )
        let storedModelId = defaults.string(forKey: Keys.modelId)
        if let storedModelId,
           !PredictionConstants.retiredDefaultModelIds.contains(storedModelId) {
            self.modelId = storedModelId
        } else {
            self.modelId = PredictionConstants.defaultModelId
            defaults.set(PredictionConstants.defaultModelId, forKey: Keys.modelId)
        }
    }

    func isLearningEnabled(for bundleID: String) -> Bool {
        learningEnabled && !disabledLearningBundleIds.contains(bundleID)
    }

    func setLearningEnabled(_ enabled: Bool, for bundleID: String) {
        if enabled {
            disabledLearningBundleIds.remove(bundleID)
        } else {
            disabledLearningBundleIds.insert(bundleID)
        }
    }
}
