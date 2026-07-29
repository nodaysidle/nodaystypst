import Testing
@testable import Nodaystypst

@Suite("PredictionConstants")
struct PredictionConstantsTests {
    @Test("debounce uses the 80ms latency floor")
    func debounceLatencyFloor() {
        let ms = PredictionConstants.debounceNanoseconds / 1_000_000
        #expect(ms == 80)
    }

    @Test("context window is 800 characters with a 1000-character hard cap")
    func snippetCaps() {
        #expect(PredictionConstants.maxContextCharacters == 800)
        #expect(PredictionConstants.maxPrefixCharacters == 800)
        #expect(PredictionConstants.maxSuffixCharacters == 160)
        #expect(PredictionConstants.hardMaxPrefixCharacters <= 1000)
        #expect(PredictionConstants.maxPrefixCharacters <= PredictionConstants.hardMaxPrefixCharacters)
    }

    @Test("Gemma 4 timeout is four seconds")
    func gemmaTimeout() {
        #expect(PredictionConstants.requestTimeout == 4.0)
    }

    @Test("default model is Gemma 4 26B A4B")
    func defaultModelId() {
        #expect(PredictionConstants.defaultModelId == "google/gemma-4-26b-a4b-it")
        #expect(PredictionConstants.retiredDefaultModelIds.contains("mistralai/ministral-3b-2512"))
    }

    @Test("maxCompletionWords is exactly 4")
    func maxCompletionWords() {
        #expect(PredictionConstants.minimumCompletionWords == 2)
        #expect(PredictionConstants.maxCompletionWords == 4)
    }

    @Test("maxCompletionTokens is exactly 12")
    func maxCompletionTokens() {
        #expect(PredictionConstants.maxCompletionTokens == 12)
    }
}
