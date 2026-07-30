import Foundation
import Testing
@testable import Nodaystypst

@Suite("Writing style personalization")
struct WritingStyleProfileTests {
    @Test("one-off terms stay out while repeated terms shape the prompt")
    func repeatThreshold() {
        var profile = WritingStyleProfile()
        profile.record(word: "rareonce", previousWord: nil, bundleID: "app")
        for _ in 0..<2 {
            profile.record(word: "write", previousWord: nil, bundleID: "app")
            profile.record(word: "clearly", previousWord: "write", bundleID: "app")
            profile.record(punctuation: ".", bundleID: "app")
        }

        let summary = profile.promptSummary(bundleID: "app")
        #expect(summary.contains("write"))
        #expect(summary.contains("clearly"))
        #expect(summary.contains("write clearly"))
        #expect(!summary.contains("rareonce"))
    }

    @Test("profile is bounded and per-app reset removes its global contribution")
    func boundsAndReset() {
        var profile = WritingStyleProfile()
        for index in 0..<(WritingStyleProfile.maximumTerms + 40) {
            profile.record(
                word: "term\(index)",
                previousWord: nil,
                bundleID: "app.one"
            )
        }
        #expect(profile.global.words.count <= WritingStyleProfile.maximumTerms)
        #expect(profile.apps["app.one"]?.words.count ?? 0 <= WritingStyleProfile.maximumTerms)

        profile.reset(bundleID: "app.one")
        #expect(profile.apps["app.one"] == nil)
        #expect(profile.global.words.isEmpty)
    }

    @Test("typed observations persist encrypted and AI baselines are not learned")
    func encryptedStoreAndAIBaseline() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nodaystypst-style-\(UUID().uuidString)")
        let fileURL = directory.appendingPathComponent("profile.enc")
        let keychain = KeychainStore(
            service: "com.nodays.nodaystypst.tests.\(UUID().uuidString)",
            account: "style-key"
        )
        let store = WritingStyleStore(fileURL: fileURL, keychainStore: keychain)
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? keychain.deleteSecret()
        }

        let bundleID = "test.writer"
        var prefix = ""
        await store.observe(.init(
            fieldID: 7,
            bundleID: bundleID,
            role: "AXTextArea",
            prefix: prefix
        ))
        for character in "write clearly. write clearly. " {
            prefix.append(character)
            await store.observe(.init(
                fieldID: 7,
                bundleID: bundleID,
                role: "AXTextArea",
                prefix: prefix
            ))
        }

        await store.flushPending()

        let summary = await store.promptSummary(bundleID: bundleID)
        #expect(summary.contains("write clearly"))
        let encrypted = try Data(contentsOf: fileURL)
        #expect(String(data: encrypted, encoding: .utf8)?.contains("clearly") != true)

        prefix += "modelword"
        await store.advanceBaseline(.init(
            fieldID: 7,
            bundleID: bundleID,
            role: "AXTextArea",
            prefix: prefix
        ))
        prefix += " "
        await store.observe(.init(
            fieldID: 7,
            bundleID: bundleID,
            role: "AXTextArea",
            prefix: prefix
        ))
        let profile = await store.snapshotForTesting()
        #expect(profile.global.words["modelword"] == nil)
    }

    @Test("observe debounces persistence and flushPending commits the latest profile")
    func debouncedPersistence() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nodaystypst-style-\(UUID().uuidString)")
        let fileURL = directory.appendingPathComponent("profile.enc")
        let keychain = KeychainStore(
            service: "com.nodays.nodaystypst.tests.\(UUID().uuidString)",
            account: "style-key"
        )
        let store = WritingStyleStore(
            fileURL: fileURL,
            keychainStore: keychain,
            flushDebounce: 50_000_000
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? keychain.deleteSecret()
        }

        var prefix = ""
        await store.observe(.init(
            fieldID: 11,
            bundleID: "test.writer",
            role: "AXTextArea",
            prefix: prefix
        ))
        for character in "hello " {
            prefix.append(character)
            await store.observe(.init(
                fieldID: 11,
                bundleID: "test.writer",
                role: "AXTextArea",
                prefix: prefix
            ))
        }

        #expect(!FileManager.default.fileExists(atPath: fileURL.path))

        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(FileManager.default.fileExists(atPath: fileURL.path))

        await store.flushPending()
    }

    @Test("rapid observes share a single flush window")
    func rapidObservesShareFlush() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nodaystypst-style-\(UUID().uuidString)")
        let fileURL = directory.appendingPathComponent("profile.enc")
        let keychain = KeychainStore(
            service: "com.nodays.nodaystypst.tests.\(UUID().uuidString)",
            account: "style-key"
        )
        let store = WritingStyleStore(
            fileURL: fileURL,
            keychainStore: keychain,
            flushDebounce: 100_000_000
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? keychain.deleteSecret()
        }

        var prefix = ""
        for character in "alpha beta gamma delta" {
            prefix.append(character)
            await store.observe(.init(
                fieldID: 13,
                bundleID: "test.writer",
                role: "AXTextArea",
                prefix: prefix
            ))
        }

        #expect(!FileManager.default.fileExists(atPath: fileURL.path))

        try await Task.sleep(nanoseconds: 250_000_000)

        #expect(FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test("reset all removes the encrypted profile and learned summary")
    func resetAll() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nodaystypst-style-\(UUID().uuidString)")
        let fileURL = directory.appendingPathComponent("profile.enc")
        let keychain = KeychainStore(
            service: "com.nodays.nodaystypst.tests.\(UUID().uuidString)",
            account: "style-key"
        )
        let store = WritingStyleStore(
            fileURL: fileURL,
            keychainStore: keychain
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? keychain.deleteSecret()
        }

        var prefix = ""
        await store.observe(.init(
            fieldID: 17,
            bundleID: "test.writer",
            role: "AXTextArea",
            prefix: prefix
        ))
        for character in "write clearly. write clearly. " {
            prefix.append(character)
            await store.observe(.init(
                fieldID: 17,
                bundleID: "test.writer",
                role: "AXTextArea",
                prefix: prefix
            ))
        }
        await store.flushPending()
        let learnedSummary = await store.promptSummary(bundleID: "test.writer")
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
        #expect(!learnedSummary.isEmpty)

        try await store.resetAll()

        let resetSummary = await store.promptSummary(bundleID: "test.writer")
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        #expect(resetSummary.isEmpty)
    }
}
