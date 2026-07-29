import Foundation
import Testing
@testable import Nodaystypst

@Suite("PredictClient generation")
struct PredictClientGenerationTests {
    @Test("OpenRouter request locks latency routing, privacy, and no reasoning")
    func requestPolicy() throws {
        let request = OpenRouterChatRequest(
            model: PredictionConstants.defaultModelId,
            messages: [.init(role: "user", content: "hello")],
            maxTokens: PredictionConstants.maxCompletionTokens,
            temperature: 0.2,
            provider: .init(
                sort: "latency",
                allowFallbacks: true,
                dataCollection: "deny"
            ),
            reasoning: .init(effort: "none")
        )
        let data = try JSONEncoder().encode(request)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let provider = try #require(object["provider"] as? [String: Any])
        let reasoning = try #require(object["reasoning"] as? [String: Any])
        #expect(provider["sort"] as? String == "latency")
        #expect(provider["data_collection"] as? String == "deny")
        #expect(provider["allow_fallbacks"] as? Bool == true)
        #expect(reasoning["effort"] as? String == "none")
        #expect(object["temperature"] as? Double == 0.2)
    }

    @Test("request labels before and after-caret context and requires 2–4 words")
    func contextualRequestMessages() {
        let messages = PredictClient.requestMessages(
            prefix: "The release should",
            suffix: "after testing.",
            styleSummary: "frequent terms: release"
        )

        #expect(messages.count == 2)
        #expect(messages[0].role == "system")
        #expect(messages[0].content.contains("exact next 2 to 4 words"))
        #expect(messages[0].content.contains("frequent terms: release"))
        #expect(messages[1].content.contains("<TEXT_BEFORE_CURSOR>\nThe release should"))
        #expect(messages[1].content.contains("<TEXT_AFTER_CURSOR>\nafter testing."))
    }

    @Test("trimContinuation strips fences and whitespace")
    func trim() {
        #expect(PredictClient.trimContinuation("```\nhello\n```", prefix: "Say ") == "hello")
        #expect(PredictClient.trimContinuation("  world  ", prefix: "hello ") == "world")
        #expect(PredictClient.trimContinuation("hello", prefix: "hello") == nil)
        #expect(PredictClient.trimContinuation("", prefix: "x") == nil)
    }

    @Test("capWords truncates >4 words to exactly 4")
    func capTruncate() {
        #expect(PredictClient.capWords("one two three four five six") == "one two three four")
    }

    @Test("capWords leaves exactly 4 words unchanged")
    func capFourUnchanged() {
        #expect(PredictClient.capWords("one two three four") == "one two three four")
    }

    @Test("capWords leaves fewer words unchanged with no padding")
    func capFewerUnchanged() {
        #expect(PredictClient.capWords("just two") == "just two")
        #expect(PredictClient.capWords("hello") == "hello")
        #expect(PredictClient.capWords("") == "")
    }

    @Test("validated continuations contain 2–4 words")
    func validatedWordRange() {
        #expect(PredictClient.validatedContinuation(
            "be thoroughly tested today please",
            prefix: "The release should",
            suffix: ""
        ) == "be thoroughly tested today")
        #expect(PredictClient.validatedContinuation(
            "be tested",
            prefix: "The release should",
            suffix: ""
        ) == "be tested")
        #expect(PredictClient.validatedContinuation(
            "finish",
            prefix: "We should",
            suffix: ""
        ) == nil)
    }

    @Test("validated continuations reject repeated caret boundaries")
    func rejectsBoundaryDuplication() {
        #expect(PredictClient.validatedContinuation(
            "should work well",
            prefix: "The final build should",
            suffix: ""
        ) == nil)
        #expect(PredictClient.validatedContinuation(
            "complete the",
            prefix: "Make it",
            suffix: "the release today"
        ) == nil)
    }

    @Test("capWords normalizes multi-whitespace and newlines to single spaces")
    func capWhitespaceNormalization() {
        #expect(PredictClient.capWords("hello   world\ntest") == "hello world test")
        #expect(PredictClient.capWords("\n\none two\nthree  four   five") == "one two three four")
        #expect(PredictClient.capWords("a\tb") == "a b")
        #expect(PredictClient.capWords("one\r\ntwo\u{2028}three\tfour five") == "one two three four")
    }

    @Test("capWords handles fenced long result via trim + cap")
    func fencedLongResult() {
        // trimContinuation removes fences, capWords chops to 4
        if let trimmed = PredictClient.trimContinuation(
            "```\napple banana carrot date eggplant fig\n```",
            prefix: "Say "
        ) {
            #expect(PredictClient.capWords(trimmed) == "apple banana carrot date")
        } else {
            Issue.record("trimContinuation should not return nil for valid fenced content")
        }
    }

    @Test("empty or same-as-prefix still rejected by trimContinuation")
    func emptyOrSamePrefix() {
        #expect(PredictClient.trimContinuation("hello", prefix: "hello") == nil)
        #expect(PredictClient.trimContinuation("", prefix: "x") == nil)
        #expect(PredictClient.trimContinuation("  \n ", prefix: "x") == nil)
    }

    // MARK: - Boundary spacing

    @Test("letter after non-whitespace prefix adds one ASCII space")
    func boundaryLetterAddsSpace() {
        #expect(PredictClient.addBoundarySpace(
            prefix: "should", continuation: "be"
        ) == " be")
        #expect(PredictClient.addBoundarySpace(
            prefix: "say", continuation: "život"
        ) == " život")
    }

    @Test("digit-started continuation after nonspace prefix adds space")
    func boundaryDigitAddsSpace() {
        #expect(PredictClient.addBoundarySpace(
            prefix: "count", continuation: "42items"
        ) == " 42items")
    }

    @Test("underscore-started continuation after nonspace prefix adds space")
    func boundaryUnderscoreAddsSpace() {
        #expect(PredictClient.addBoundarySpace(
            prefix: "my", continuation: "_private"
        ) == " _private")
    }

    @Test("punctuation comma does not prepend space")
    func boundaryCommaNoSpace() {
        #expect(PredictClient.addBoundarySpace(
            prefix: "hello", continuation: ", world"
        ) == ", world")
    }

    @Test("punctuation period does not prepend space")
    func boundaryPeriodNoSpace() {
        #expect(PredictClient.addBoundarySpace(
            prefix: "hello", continuation: ". And"
        ) == ". And")
    }

    @Test("prefix ends with ASCII space, no duplicate space")
    func boundaryPrefixEndsWithSpace() {
        #expect(PredictClient.addBoundarySpace(
            prefix: "hello ", continuation: "world"
        ) == "world")
    }

    @Test("prefix ends with tab, no duplicate space")
    func boundaryPrefixEndsWithTab() {
        #expect(PredictClient.addBoundarySpace(
            prefix: "hello\t", continuation: "world"
        ) == "world")
    }

    @Test("prefix ends with newline, no duplicate space")
    func boundaryPrefixEndsWithNewline() {
        #expect(PredictClient.addBoundarySpace(
            prefix: "hello\n", continuation: "world"
        ) == "world")
        #expect(PredictClient.addBoundarySpace(
            prefix: "hello\u{00A0}", continuation: "world"
        ) == "world")
    }

    @Test("empty prefix, continuation unchanged")
    func boundaryEmptyPrefix() {
        #expect(PredictClient.addBoundarySpace(
            prefix: "", continuation: "world"
        ) == "world")
    }

    @Test("empty continuation unchanged")
    func boundaryEmptyContinuation() {
        #expect(PredictClient.addBoundarySpace(
            prefix: "hello", continuation: ""
        ) == "")
    }

    @Test("both empty unchanged")
    func boundaryBothEmpty() {
        #expect(PredictClient.addBoundarySpace(
            prefix: "", continuation: ""
        ) == "")
    }

    @Test("integration trim → cap → spacing for shouldbe regression")
    func integrationTrimCapSpaceShouldbe() {
        // Simulates the reported bug: prefix "The release candidate should"
        // + model response, after trim + cap + spacing should yield
        // " be thoroughly tested."
        let responseText = "be thoroughly tested."
        let prefix = "The release candidate should"

        guard let trimmed = PredictClient.trimContinuation(responseText, prefix: prefix) else {
            Issue.record("trimContinuation should not return nil")
            return
        }
        #expect(trimmed == "be thoroughly tested.")

        let capped = PredictClient.capWords(trimmed)
        #expect(capped == "be thoroughly tested.")

        let spaced = PredictClient.addBoundarySpace(prefix: prefix, continuation: capped)
        #expect(spaced == " be thoroughly tested.")

        // Verify word count remains ≤4 (leading space does not count)
        let words = spaced.split(whereSeparator: { $0.isWhitespace })
        #expect(words.count <= 4)
        #expect(words.count == 3)
    }
}
