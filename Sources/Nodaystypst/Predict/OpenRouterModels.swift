import Foundation

// MARK: - Request

struct OpenRouterChatRequest: Encodable, Sendable {
    let model: String
    let messages: [OpenRouterMessage]
    let maxTokens: Int
    let temperature: Double
    let provider: OpenRouterProviderPreferences
    let reasoning: OpenRouterReasoningPreferences

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case maxTokens = "max_tokens"
        case temperature
        case provider
        case reasoning
    }
}

struct OpenRouterProviderPreferences: Encodable, Sendable {
    let sort: String
    let allowFallbacks: Bool
    let dataCollection: String

    enum CodingKeys: String, CodingKey {
        case sort
        case allowFallbacks = "allow_fallbacks"
        case dataCollection = "data_collection"
    }
}

struct OpenRouterReasoningPreferences: Encodable, Sendable {
    let effort: String
}

struct OpenRouterMessage: Codable, Sendable {
    let role: String
    let content: String
}

// MARK: - Response

struct OpenRouterChatResponse: Decodable, Sendable {
    let choices: [OpenRouterChoice]
}

struct OpenRouterChoice: Decodable, Sendable {
    let message: OpenRouterResponseMessage
}

struct OpenRouterResponseMessage: Decodable, Sendable {
    let content: String?
}
