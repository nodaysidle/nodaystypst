import Testing
@testable import Nodaystypst

@Suite("AcceptInsert policy")
struct AcceptInsertPolicyTests {
    @Test("Tab accepts one word and preserves the remainder")
    func nextWord() {
        #expect(
            AcceptInsert.nextWord(in: " quick brown fox")
                == .init(accepted: " quick", remaining: " brown fox")
        )
        #expect(
            AcceptInsert.nextWord(in: " tested.")
                == .init(accepted: " tested.", remaining: "")
        )
    }

    @Test("Codex accepts its full bounded banner while native apps accept one word")
    func appSpecificAcceptance() {
        #expect(
            AcceptInsert.acceptance(
                in: " be a reliable feature.",
                bundleID: "com.openai.codex"
            ) == .init(accepted: " be a reliable feature.", remaining: "")
        )
        #expect(
            AcceptInsert.acceptance(
                in: " be a reliable feature.",
                bundleID: "com.kagi.kagimacOS"
            ) == .init(accepted: " be", remaining: " a reliable feature.")
        )
    }

    @Test("word acceptance is Unicode and punctuation safe")
    func unicodeAndPunctuation() {
        #expect(
            AcceptInsert.nextWord(in: " život gre naprej")
                == .init(accepted: " život", remaining: " gre naprej")
        )
        #expect(
            AcceptInsert.nextWord(in: ". Next sentence")
                == .init(accepted: ".", remaining: " Next sentence")
        )
        #expect(
            AcceptInsert.nextWord(in: "\tcan't wait")
                == .init(accepted: "\tcan't", remaining: " wait")
        )
        #expect(AcceptInsert.nextWord(in: "") == nil)
    }

    @Test("tab is accept when allowed and visible")
    func tabPolicy() {
        #expect(AcceptInsert.shouldAcceptTab(ghostVisible: true, adapterAllows: true))
        #expect(!AcceptInsert.shouldAcceptTab(ghostVisible: false, adapterAllows: true))
        #expect(!AcceptInsert.shouldAcceptTab(ghostVisible: true, adapterAllows: false))
    }

    @Test("only Codex uses caret-preserving synthetic text insertion")
    func codexInsertionRoute() {
        #expect(AcceptInsert.usesSyntheticTextInsertion(
            bundleID: "com.openai.codex"
        ))
        #expect(!AcceptInsert.usesSyntheticTextInsertion(
            bundleID: "com.kagi.kagimacOS"
        ))
        #expect(AcceptInsert.requiresDeferredTabAcceptance(
            adapterKind: "codex"
        ))
        #expect(!AcceptInsert.requiresDeferredTabAcceptance(
            adapterKind: "native"
        ))
    }

    @Test("Caret resolution safely falls back to the secure-gated suffix")
    func caretResolution() {
        #expect(
            AcceptInsert.caretIndex(
                valueUTF16Count: 12,
                selectedLocation: 4,
                selectedLength: 2,
                expectedSuffixUTF16Count: 3
            ) == 6
        )
        #expect(
            AcceptInsert.caretIndex(
                valueUTF16Count: 12,
                selectedLocation: nil,
                selectedLength: nil,
                expectedSuffixUTF16Count: 3
            ) == 9
        )
        #expect(
            AcceptInsert.caretIndex(
                valueUTF16Count: 4,
                selectedLocation: 5,
                selectedLength: 0,
                expectedSuffixUTF16Count: 1
            ) == 3
        )
        #expect(
            AcceptInsert.caretIndex(
                valueUTF16Count: 4,
                selectedLocation: nil,
                selectedLength: nil,
                expectedSuffixUTF16Count: 5
            ) == nil
        )
    }
}
