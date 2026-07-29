import Foundation

struct FieldContext: Equatable, Sendable {
    struct PredictionText: Equatable, Sendable {
        let prefix: String
        let suffix: String
    }

    var prefix: String
    var suffix: String
    var bundleID: String
    var elementRole: String

    static func boundedPrefix(
        _ raw: String,
        max: Int = PredictionConstants.maxPrefixCharacters
    ) -> String {
        let limit = min(max, PredictionConstants.hardMaxPrefixCharacters)
        guard raw.count > limit else {
            return raw
        }
        return String(raw.suffix(limit))
    }

    /// Builds the only raw text window allowed onto the prediction wire.
    /// A short suffix is reserved first so mid-sentence edits remain coherent;
    /// the rest of the total budget is spent on the most recent prefix.
    static func boundedPredictionText(
        prefix rawPrefix: String,
        suffix rawSuffix: String,
        maxTotal: Int = PredictionConstants.maxContextCharacters,
        maxSuffix: Int = PredictionConstants.maxSuffixCharacters
    ) -> PredictionText {
        let totalLimit = max(
            0,
            min(maxTotal, PredictionConstants.hardMaxPrefixCharacters)
        )
        let suffixLimit = max(0, min(maxSuffix, totalLimit))
        let suffix = rawSuffix.count > suffixLimit
            ? String(rawSuffix.prefix(suffixLimit))
            : rawSuffix
        let prefixLimit = max(0, totalLimit - suffix.count)
        let prefix = rawPrefix.count > prefixLimit
            ? String(rawPrefix.suffix(prefixLimit))
            : rawPrefix
        return PredictionText(prefix: prefix, suffix: suffix)
    }
}
