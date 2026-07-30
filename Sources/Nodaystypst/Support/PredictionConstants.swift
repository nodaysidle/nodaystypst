import Foundation

enum PredictionConstants {
    static let debounceNanoseconds: UInt64 = 80_000_000
    static let requestTimeout: TimeInterval = 6.0
    static let maxContextCharacters = 800
    static let maxPrefixCharacters = 800
    static let maxSuffixCharacters = 160
    static let hardMaxPrefixCharacters = 1000
    static let maxCompletionTokens = 12
    static let minimumCompletionWords = 2
    static let maxCompletionWords = 4
    static let defaultModelId = "google/gemma-4-26b-a4b-it"
    static let retiredDefaultModelIds: Set<String> = [
        "mistralai/ministral-3b-2512",
        "mistralai/mistral-nemo",
    ]
}
