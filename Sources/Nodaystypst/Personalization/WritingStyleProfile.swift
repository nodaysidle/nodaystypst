import Foundation

struct WritingObservation: Equatable, Sendable {
    let fieldID: UInt
    let bundleID: String
    let role: String
    let prefix: String
}

struct WritingStyleProfile: Codable, Equatable, Sendable {
    static let maximumTerms = 128
    static let maximumPhrases = 96
    static let minimumPromptCount = 2

    var global = StyleBucket()
    var apps: [String: StyleBucket] = [:]
    var lastAgedAt = Date()

    mutating func record(
        word: String,
        previousWord: String?,
        bundleID: String
    ) {
        global.record(word: word, previousWord: previousWord)
        var app = apps[bundleID, default: StyleBucket()]
        app.record(word: word, previousWord: previousWord)
        apps[bundleID] = app
        prune()
    }

    mutating func record(punctuation: Character, bundleID: String) {
        global.record(punctuation: punctuation)
        var app = apps[bundleID, default: StyleBucket()]
        app.record(punctuation: punctuation)
        apps[bundleID] = app
    }

    mutating func ageIfNeeded(now: Date = Date()) {
        let days = Calendar.current.dateComponents(
            [.day],
            from: lastAgedAt,
            to: now
        ).day ?? 0
        guard days > 0 else { return }

        let factor = pow(0.92, Double(min(days, 30)))
        global.applyDecay(factor: factor)
        for bundleID in apps.keys {
            apps[bundleID]?.applyDecay(factor: factor)
        }
        apps = apps.filter { !$0.value.isEmpty }
        lastAgedAt = now
    }

    mutating func reset(bundleID: String) {
        if let app = apps.removeValue(forKey: bundleID) {
            global.subtract(app)
        }
    }

    func promptSummary(bundleID: String, maximumCharacters: Int = 420) -> String {
        var merged = global
        let app = apps[bundleID]
        if let app {
            merged.merge(app)
        }

        let terms = Self.topEntries(
            Self.repeatedEntries(
                merged: merged.words,
                global: global.words,
                app: app?.words
            ),
            limit: 8,
            minimumCount: 1
        )
        let phrases = Self.topEntries(
            Self.repeatedEntries(
                merged: merged.phrases,
                global: global.phrases,
                app: app?.phrases
            ),
            limit: 5,
            minimumCount: 1
        )

        var parts: [String] = []
        if !terms.isEmpty {
            parts.append("frequent terms: " + terms.joined(separator: ", "))
        }
        if !phrases.isEmpty {
            parts.append("recurring phrasing: " + phrases.joined(separator: ", "))
        }
        if let punctuation = Self.topEntries(
            Self.repeatedEntries(
                merged: merged.punctuation,
                global: global.punctuation,
                app: app?.punctuation
            ),
            limit: 3,
            minimumCount: 1
        ).first {
            parts.append("common punctuation: " + punctuation)
        }
        if merged.completedSentenceCount > 0 {
            let average = max(
                1,
                merged.completedSentenceWords / merged.completedSentenceCount
            )
            parts.append("typical sentence length: about \(average) words")
        }
        if merged.totalWords >= 8 {
            let ratio = Double(merged.capitalizedWords) / Double(merged.totalWords)
            parts.append(ratio > 0.35 ? "capitalization: frequent" : "capitalization: restrained")
        }

        let summary = parts.joined(separator: "; ")
        guard summary.count > maximumCharacters else { return summary }
        return String(summary.prefix(maximumCharacters))
    }

    private mutating func prune() {
        global.prune()
        for bundleID in apps.keys {
            apps[bundleID]?.prune()
        }
    }

    private static func topEntries(
        _ values: [String: Int],
        limit: Int,
        minimumCount: Int
    ) -> [String] {
        values
            .filter { $0.value >= minimumCount }
            .sorted {
                if $0.value == $1.value { return $0.key < $1.key }
                return $0.value > $1.value
            }
            .prefix(limit)
            .map(\.key)
    }

    private static func repeatedEntries(
        merged: [String: Int],
        global: [String: Int],
        app: [String: Int]?
    ) -> [String: Int] {
        merged.filter { key, _ in
            (global[key] ?? 0) >= minimumPromptCount
                || (app?[key] ?? 0) >= minimumPromptCount
        }
    }
}

struct StyleBucket: Codable, Equatable, Sendable {
    var words: [String: Int] = [:]
    var phrases: [String: Int] = [:]
    var punctuation: [String: Int] = [:]
    var totalWords = 0
    var capitalizedWords = 0
    var currentSentenceWords = 0
    var completedSentenceWords = 0
    var completedSentenceCount = 0

    var isEmpty: Bool {
        words.isEmpty && phrases.isEmpty && punctuation.isEmpty
    }

    mutating func record(word: String, previousWord: String?) {
        guard !word.isEmpty else { return }
        words[word, default: 0] += 1
        totalWords += 1
        currentSentenceWords += 1
        if word.first?.isUppercase == true {
            capitalizedWords += 1
        }
        if let previousWord, !previousWord.isEmpty {
            phrases[previousWord + " " + word, default: 0] += 1
        }
    }

    mutating func record(punctuation character: Character) {
        let value = String(character)
        punctuation[value, default: 0] += 1
        if ".!?".contains(character), currentSentenceWords > 0 {
            completedSentenceWords += currentSentenceWords
            completedSentenceCount += 1
            currentSentenceWords = 0
        }
    }

    mutating func merge(_ other: StyleBucket) {
        for (key, value) in other.words {
            words[key, default: 0] += value
        }
        for (key, value) in other.phrases {
            phrases[key, default: 0] += value
        }
        for (key, value) in other.punctuation {
            punctuation[key, default: 0] += value
        }
        totalWords += other.totalWords
        capitalizedWords += other.capitalizedWords
        completedSentenceWords += other.completedSentenceWords
        completedSentenceCount += other.completedSentenceCount
    }

    mutating func applyDecay(factor: Double) {
        words = decayed(words, factor: factor)
        phrases = decayed(phrases, factor: factor)
        punctuation = decayed(punctuation, factor: factor)
        totalWords = Int(Double(totalWords) * factor)
        capitalizedWords = Int(Double(capitalizedWords) * factor)
        currentSentenceWords = 0
        completedSentenceWords = Int(Double(completedSentenceWords) * factor)
        completedSentenceCount = Int(Double(completedSentenceCount) * factor)
        prune()
    }

    mutating func subtract(_ other: StyleBucket) {
        Self.subtractCounters(&words, other.words)
        Self.subtractCounters(&phrases, other.phrases)
        Self.subtractCounters(&punctuation, other.punctuation)
        totalWords = max(0, totalWords - other.totalWords)
        capitalizedWords = max(0, capitalizedWords - other.capitalizedWords)
        completedSentenceWords = max(
            0,
            completedSentenceWords - other.completedSentenceWords
        )
        completedSentenceCount = max(
            0,
            completedSentenceCount - other.completedSentenceCount
        )
    }

    mutating func prune() {
        words = bounded(words, maximum: WritingStyleProfile.maximumTerms)
        phrases = bounded(phrases, maximum: WritingStyleProfile.maximumPhrases)
        punctuation = bounded(punctuation, maximum: 12)
    }

    private func bounded(
        _ source: [String: Int],
        maximum: Int
    ) -> [String: Int] {
        guard source.count > maximum else { return source }
        return Dictionary(
            uniqueKeysWithValues: source
                .sorted {
                    if $0.value == $1.value { return $0.key < $1.key }
                    return $0.value > $1.value
                }
                .prefix(maximum)
                .map { ($0.key, $0.value) }
        )
    }

    private static func subtractCounters(
        _ target: inout [String: Int],
        _ source: [String: Int]
    ) {
        for (key, value) in source {
            let remainder = (target[key] ?? 0) - value
            if remainder > 0 {
                target[key] = remainder
            } else {
                target.removeValue(forKey: key)
            }
        }
    }

    private func decayed(
        _ source: [String: Int],
        factor: Double
    ) -> [String: Int] {
        source.reduce(into: [:]) { result, item in
            let value = Int(Double(item.value) * factor)
            if value > 0 {
                result[item.key] = value
            }
        }
    }
}
