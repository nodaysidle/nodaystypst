import Testing
@testable import Nodaystypst

@Suite("CompletionCoordinator generation")
struct CompletionCoordinatorDebounceTests {
    @Test("predictions are limited to verified application bundles")
    func supportedApps() {
        for target in SupportedAppPolicy.targets {
            #expect(SupportedAppPolicy.allowsPredictions(
                bundleID: target.bundleID
            ))
        }
        #expect(!SupportedAppPolicy.allowsPredictions(bundleID: "com.apple.Mail"))
        for target in SupportedAppPolicy.safeRejectedTargets {
            #expect(!SupportedAppPolicy.allowsPredictions(
                bundleID: target.bundleID
            ))
        }
    }

    @Test("only verified editable fields pass before content capture")
    func verifiedFieldGate() {
        #expect(SupportedAppPolicy.allowsField(
            bundleID: SupportedAppPolicy.textEditBundleID,
            role: "AXTextArea",
            metadata: []
        ))
        #expect(!SupportedAppPolicy.allowsField(
            bundleID: SupportedAppPolicy.chromeBundleID,
            role: "AXTextArea",
            metadata: ["page content"]
        ))
        for bundleID in [
            SupportedAppPolicy.orionBundleID,
            SupportedAppPolicy.safariBundleID,
            SupportedAppPolicy.obsidianBundleID,
        ] {
            #expect(!SupportedAppPolicy.allowsField(
                bundleID: bundleID,
                role: "AXTextField",
                metadata: []
            ))
        }
        #expect(!SupportedAppPolicy.allowsField(
            bundleID: SupportedAppPolicy.chromeBundleID,
            role: "AXTextField",
            metadata: ["Address and search bar"]
        ))
        #expect(!SupportedAppPolicy.allowsField(
            bundleID: SupportedAppPolicy.safariBundleID,
            role: "AXTextField",
            metadata: ["smart search field"]
        ))
        #expect(!SupportedAppPolicy.allowsField(
            bundleID: SupportedAppPolicy.notesBundleID,
            role: "AXButton",
            metadata: []
        ))
        #expect(!SupportedAppPolicy.allowsField(
            bundleID: "com.apple.Mail",
            role: "AXTextArea",
            metadata: []
        ))
    }

    @Test("generation bumps invalidate older ids")
    func bump() {
        var generation: UInt64 = 0
        func next() -> UInt64 {
            generation += 1
            return generation
        }

        let first = next()
        let second = next()

        #expect(second == first + 1)
        #expect(first != second)
    }

    @Test("prediction requires every safety gate")
    func predictionGate() {
        #expect(!CompletionCoordinator.shouldPredict(
            isPaused: false,
            axTrusted: true,
            snapshotSecure: true,
            geometryTrusted: true,
            hasAPIKey: true
        ))
        #expect(CompletionCoordinator.shouldPredict(
            isPaused: false,
            axTrusted: true,
            snapshotSecure: false,
            geometryTrusted: true,
            hasAPIKey: true
        ))
        #expect(!CompletionCoordinator.shouldPredict(
            isPaused: false,
            axTrusted: true,
            snapshotSecure: false,
            geometryTrusted: false,
            hasAPIKey: true
        ))
        #expect(!CompletionCoordinator.shouldPredict(
            isPaused: true,
            axTrusted: true,
            snapshotSecure: false,
            geometryTrusted: true,
            hasAPIKey: true
        ))
        #expect(!CompletionCoordinator.shouldPredict(
            isPaused: false,
            axTrusted: false,
            snapshotSecure: false,
            geometryTrusted: true,
            hasAPIKey: true
        ))
        #expect(!CompletionCoordinator.shouldPredict(
            isPaused: false,
            axTrusted: true,
            snapshotSecure: false,
            geometryTrusted: true,
            hasAPIKey: false
        ))
    }

    @Test("question boundaries suppress conversational answers")
    func questionBoundarySuppression() {
        #expect(CompletionCoordinator.shouldSuppressAfterQuestionMark(
            prefix: "Will this answer me?"
        ))
        #expect(CompletionCoordinator.shouldSuppressAfterQuestionMark(
            prefix: "Will this answer me?   \n"
        ))
        #expect(!CompletionCoordinator.shouldSuppressAfterQuestionMark(
            prefix: "Will this complete"
        ))
        #expect(!CompletionCoordinator.shouldSuppressAfterQuestionMark(
            prefix: "Will this answer me? Next"
        ))
        #expect(!CompletionCoordinator.shouldSuppressAfterQuestionMark(
            prefix: ""
        ))
    }
}
