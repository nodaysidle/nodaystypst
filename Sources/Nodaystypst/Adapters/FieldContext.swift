import Foundation

struct FieldContext: Equatable, Sendable {
    struct PredictionText: Equatable, Sendable {
        let prefix: String
        let suffix: String
    }

    struct UTF16ContextWindow: Equatable, Sendable {
        let prefixLocation: Int
        let prefixLength: Int
        let suffixLocation: Int
        let suffixLength: Int

        var localCaretIndex: Int { prefixLength }
    }

    struct BoundedValue: Equatable, Sendable {
        let text: String
        let caretIndex: Int
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

    /// Returns the small UTF-16 ranges needed around an AX caret. Accessibility
    /// offsets are UTF-16 based, so this is also used when revalidating a live
    /// field immediately before insertion.
    static func utf16ContextWindow(
        caretIndex: Int,
        totalLength: Int
    ) -> UTF16ContextWindow {
        let safeTotal = max(0, totalLength)
        let safeCaret = min(max(0, caretIndex), safeTotal)
        let prefixLength = min(
            safeCaret,
            PredictionConstants.maxPrefixCharacters
        )
        let suffixLength = min(
            safeTotal - safeCaret,
            PredictionConstants.maxSuffixCharacters
        )
        return UTF16ContextWindow(
            prefixLocation: safeCaret - prefixLength,
            prefixLength: prefixLength,
            suffixLocation: safeCaret,
            suffixLength: suffixLength
        )
    }

    static func boundedValue(
        _ fullValue: String,
        caretIndex: Int
    ) -> BoundedValue {
        let ranges = utf16ContextWindow(
            caretIndex: caretIndex,
            totalLength: fullValue.utf16.count
        )
        let prefixStart = String.Index(
            utf16Offset: ranges.prefixLocation,
            in: fullValue
        )
        let caret = String.Index(
            utf16Offset: ranges.suffixLocation,
            in: fullValue
        )
        let suffixEnd = String.Index(
            utf16Offset: ranges.suffixLocation + ranges.suffixLength,
            in: fullValue
        )
        return BoundedValue(
            text: String(fullValue[prefixStart..<caret])
                + String(fullValue[caret..<suffixEnd]),
            caretIndex: ranges.localCaretIndex
        )
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
