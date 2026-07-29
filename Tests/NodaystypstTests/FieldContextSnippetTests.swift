import Testing
@testable import Nodaystypst

@Suite("FieldContext snippets")
struct FieldContextSnippetTests {
    @Test("prefix keeps only the trailing window")
    func boundsPrefix() {
        let raw = String(repeating: "a", count: 800)
        let bounded = FieldContext.boundedPrefix(raw)
        #expect(bounded.count == PredictionConstants.maxPrefixCharacters)
        #expect(bounded == String(raw.suffix(PredictionConstants.maxPrefixCharacters)))
    }

    @Test("never exceeds hard cap even if asked")
    func hardCap() {
        let raw = String(repeating: "b", count: 2_000)
        let bounded = FieldContext.boundedPrefix(raw, max: 5_000)
        #expect(bounded.count <= PredictionConstants.hardMaxPrefixCharacters)
    }

    @Test("prediction context reserves a short suffix within one total budget")
    func predictionContextBudget() {
        let prefix = String(repeating: "p", count: 900)
        let suffix = String(repeating: "s", count: 300)
        let context = FieldContext.boundedPredictionText(
            prefix: prefix,
            suffix: suffix
        )

        #expect(context.prefix.count == 640)
        #expect(context.suffix.count == 160)
        #expect(context.prefix.count + context.suffix.count == 800)
        #expect(context.prefix == String(prefix.suffix(640)))
        #expect(context.suffix == String(suffix.prefix(160)))
    }

    @Test("empty suffix gives the whole context budget to the recent prefix")
    func predictionContextWithoutSuffix() {
        let prefix = String(repeating: "x", count: 900)
        let context = FieldContext.boundedPredictionText(prefix: prefix, suffix: "")
        #expect(context.prefix.count == 800)
        #expect(context.suffix.isEmpty)
    }
}
