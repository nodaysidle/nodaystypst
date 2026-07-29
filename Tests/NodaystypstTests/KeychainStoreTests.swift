import Testing
@testable import Nodaystypst

@Suite("KeychainStore")
struct KeychainStoreTests {
    @Test("round-trips API key")
    func roundTrip() throws {
        let store = KeychainStore(
            service: "com.nodays.nodaystypst.tests",
            account: "openrouter-api-key"
        )
        try? store.deleteAPIKey()
        defer { try? store.deleteAPIKey() }

        try store.saveAPIKey("sk-test-key")
        #expect(try store.loadAPIKey() == "sk-test-key")

        try store.deleteAPIKey()
        #expect(try store.loadAPIKey() == nil)
    }
}
