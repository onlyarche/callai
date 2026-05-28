import Foundation

protocol LLMClient: Sendable {
    func send(_ request: ChatRequest) -> AsyncThrowingStream<ResponseChunk, Error>
    func listModels() async throws -> [String]
    func capabilities(of model: String) async throws -> [String]
}

extension LLMClient {
    func capabilities(of model: String) async throws -> [String] {
        throw LLMClientError.unsupported
    }
}

enum LLMClientError: Error, Equatable, Sendable {
    case http(status: Int)
    case server(message: String)
    case transport(message: String)
    case decoding(String)
    case cancelled
    case modelNotFound(String)
    case unsupported
}
