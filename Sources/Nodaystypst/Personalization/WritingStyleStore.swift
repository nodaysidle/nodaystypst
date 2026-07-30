import CryptoKit
import Foundation
import Security

actor WritingStyleStore {
    private struct SessionState: Sendable {
        var lastPrefix: String
        var pendingWord: String
        var previousWord: String?
        var bundleID: String
        var role: String
    }

    private let fileURL: URL
    private let keychainStore: KeychainStore
    private let flushDebounce: UInt64
    private var profile: WritingStyleProfile?
    private var sessions: [UInt: SessionState] = [:]
    private var flushTask: Task<Void, Never>?

    init(
        fileURL: URL = WritingStyleStore.defaultFileURL(),
        keychainStore: KeychainStore = KeychainStore(
            account: "writing-style-encryption-key-v1"
        ),
        flushDebounce: UInt64 = 2_000_000_000
    ) {
        self.fileURL = fileURL
        self.keychainStore = keychainStore
        self.flushDebounce = flushDebounce
    }

    func observe(_ observation: WritingObservation) {
        do {
            var loaded = try loadProfile()
            loaded.ageIfNeeded()

            guard var session = sessions[observation.fieldID],
                  session.bundleID == observation.bundleID,
                  session.role == observation.role else {
                sessions[observation.fieldID] = SessionState(
                    lastPrefix: observation.prefix,
                    pendingWord: "",
                    previousWord: nil,
                    bundleID: observation.bundleID,
                    role: observation.role
                )
                profile = loaded
                return
            }

            guard observation.prefix.hasPrefix(session.lastPrefix) else {
                session.lastPrefix = observation.prefix
                session.pendingWord = ""
                session.previousWord = nil
                sessions[observation.fieldID] = session
                profile = loaded
                return
            }

            let delta = String(observation.prefix.dropFirst(session.lastPrefix.count))
            session.lastPrefix = observation.prefix

            // Large changes are pastes or field replacements. They establish a
            // new baseline but are never treated as typed personalization data.
            guard delta.count <= 64 else {
                session.pendingWord = ""
                session.previousWord = nil
                sessions[observation.fieldID] = session
                profile = loaded
                return
            }

            var changed = false
            for character in delta {
                if Self.isWordCharacter(character) {
                    session.pendingWord.append(character)
                    continue
                }

                if !session.pendingWord.isEmpty {
                    let word = session.pendingWord
                    loaded.record(
                        word: word,
                        previousWord: session.previousWord,
                        bundleID: observation.bundleID
                    )
                    session.previousWord = word
                    session.pendingWord = ""
                    changed = true
                }

                if Self.isStylePunctuation(character) {
                    loaded.record(
                        punctuation: character,
                        bundleID: observation.bundleID
                    )
                    if ".!?".contains(character) {
                        session.previousWord = nil
                    }
                    changed = true
                }
            }

            sessions[observation.fieldID] = session
            profile = loaded
            if changed {
                scheduleFlush()
            }
        } catch {
            // Personalization failure must never interrupt typing or prediction.
        }
    }

    /// Moves a field baseline after an AI insertion without learning the
    /// inserted text, preventing model suggestions from training themselves.
    func advanceBaseline(_ observation: WritingObservation) {
        sessions[observation.fieldID] = SessionState(
            lastPrefix: observation.prefix,
            pendingWord: "",
            previousWord: nil,
            bundleID: observation.bundleID,
            role: observation.role
        )
    }

    func promptSummary(bundleID: String) -> String {
        do {
            var loaded = try loadProfile()
            loaded.ageIfNeeded()
            profile = loaded
            return loaded.promptSummary(bundleID: bundleID)
        } catch {
            return ""
        }
    }

    func reset(bundleID: String) throws {
        var loaded = try loadProfile()
        loaded.reset(bundleID: bundleID)
        profile = loaded
        sessions = sessions.filter { $0.value.bundleID != bundleID }
        try persist(loaded)
    }

    func resetAll() throws {
        profile = WritingStyleProfile()
        sessions.removeAll()
        flushTask?.cancel()
        flushTask = nil
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }

    func scheduleFlush() {
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            guard let self else { return }
            let delay = self.flushDebounce
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            await self.flushPending()
        }
    }

    func flushPending() {
        flushTask = nil
        guard let profile else { return }
        do {
            try persist(profile)
        } catch {
            // Personalization failure must never interrupt typing or prediction.
        }
    }

    func snapshotForTesting() -> WritingStyleProfile {
        (try? loadProfile()) ?? WritingStyleProfile()
    }

    nonisolated static func defaultFileURL() -> URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return applicationSupport
            .appendingPathComponent("nodaystypst", isDirectory: true)
            .appendingPathComponent("writing-style-profile.enc")
    }

    nonisolated static func isWordCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0)
                || $0 == "'"
                || $0 == "’"
                || $0 == "-"
                || $0 == "_"
        }
    }

    nonisolated static func isStylePunctuation(_ character: Character) -> Bool {
        ".,!?;:".contains(character)
    }

    private func loadProfile() throws -> WritingStyleProfile {
        if let profile { return profile }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            let fresh = WritingStyleProfile()
            profile = fresh
            return fresh
        }

        let encrypted = try Data(contentsOf: fileURL)
        let key = try encryptionKey()
        let sealed = try AES.GCM.SealedBox(combined: encrypted)
        let plaintext = try AES.GCM.open(sealed, using: key)
        let decoded = try JSONDecoder().decode(WritingStyleProfile.self, from: plaintext)
        profile = decoded
        return decoded
    }

    private func persist(_ profile: WritingStyleProfile) throws {
        let plaintext = try JSONEncoder().encode(profile)
        let sealed = try AES.GCM.seal(plaintext, using: encryptionKey())
        guard let encrypted = sealed.combined else {
            throw WritingStyleStoreError.encryptionFailed
        }

        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encrypted.write(to: fileURL, options: [.atomic, .completeFileProtection])
    }

    private func encryptionKey() throws -> SymmetricKey {
        if let stored = try keychainStore.loadSecretData(), stored.count == 32 {
            return SymmetricKey(data: stored)
        }

        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw WritingStyleStoreError.randomKeyFailed
        }
        let data = Data(bytes)
        try keychainStore.saveSecretData(data)
        return SymmetricKey(data: data)
    }
}

enum WritingStyleStoreError: Error {
    case encryptionFailed
    case randomKeyFailed
}
