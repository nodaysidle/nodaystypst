import Testing
@testable import Nodaystypst

@Suite("CompletionCoordinator generation")
struct CompletionCoordinatorDebounceTests {
    @Test("predictions are limited to Orion and Antinote")
    func supportedApps() {
        #expect(SupportedAppPolicy.allowsPredictions(
            bundleID: "com.kagi.kagimacOS"
        ))
        #expect(SupportedAppPolicy.allowsPredictions(
            bundleID: "com.chabomakers.Antinote"
        ))
        #expect(!SupportedAppPolicy.allowsPredictions(
            bundleID: "com.openai.codex"
        ))
        #expect(!SupportedAppPolicy.allowsPredictions(
            bundleID: "com.apple.TextEdit"
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
}
