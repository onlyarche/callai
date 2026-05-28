import Foundation

struct OllamaClient: LLMClient {
    private let baseURLProvider: @Sendable () -> URL
    private let session: URLSession

    // WHY: the base URL is read per-request from a provider closure so a
    // SettingsStore change (M8) takes effect on the next request with no client
    // re-creation. The default keeps the localhost fallback so existing
    // `OllamaClient()` callers and tests build unchanged; AppCoordinator injects a
    // SettingsStore-backed provider in Stage 8.3.
    init(baseURLProvider: @Sendable @escaping () -> URL = { URL(string: "http://localhost:11434")! },
         session: URLSession = .shared) {
        self.baseURLProvider = baseURLProvider
        self.session = session
    }

    func send(_ request: ChatRequest) -> AsyncThrowingStream<ResponseChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let urlRequest = try makeChatRequest(request)
                    let (bytes, response) = try await session.bytes(for: urlRequest)

                    guard let http = response as? HTTPURLResponse else {
                        throw LLMClientError.decoding("Non-HTTP response from /api/chat")
                    }
                    guard http.statusCode == 200 else {
                        throw mapStatus(http.statusCode, model: request.model)
                    }

                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard let data = line.data(using: .utf8), !data.isEmpty else { continue }

                        let chunk: OllamaChatChunk
                        do {
                            chunk = try JSONDecoder().decode(OllamaChatChunk.self, from: data)
                        } catch {
                            throw LLMClientError.decoding("Malformed NDJSON chat line: \(error)")
                        }

                        // 200-with-error pitfall: a single JSON line carrying only `error`.
                        if let message = chunk.error {
                            throw LLMClientError.server(message: message)
                        }
                        if let content = chunk.message?.content, !content.isEmpty {
                            continuation.yield(.text(content))
                        }
                        if chunk.done == true {
                            continuation.finish()
                            return
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.mapError(error))
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func listModels() async throws -> [String] {
        do {
            let url = baseURLProvider().appendingPathComponent("api/tags")
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse else {
                throw LLMClientError.decoding("Non-HTTP response from /api/tags")
            }
            guard http.statusCode == 200 else {
                throw LLMClientError.http(status: http.statusCode)
            }
            do {
                return try JSONDecoder().decode(OllamaTagsResponse.self, from: data)
                    .models.map(\.name)
            } catch {
                throw LLMClientError.decoding("Malformed /api/tags response: \(error)")
            }
        } catch {
            throw Self.mapError(error)
        }
    }

    func capabilities(of model: String) async throws -> [String] {
        do {
            let url = baseURLProvider().appendingPathComponent("api/show")
            var urlRequest = URLRequest(url: url)
            urlRequest.httpMethod = "POST"
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            do {
                urlRequest.httpBody = try JSONEncoder().encode(OllamaShowRequest(model: model))
            } catch {
                throw LLMClientError.decoding("Failed to encode /api/show request: \(error)")
            }

            let (data, response) = try await session.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse else {
                throw LLMClientError.decoding("Non-HTTP response from /api/show")
            }
            guard http.statusCode == 200 else {
                throw mapStatus(http.statusCode, model: model)
            }
            do {
                return try JSONDecoder().decode(OllamaShowResponse.self, from: data).capabilities ?? []
            } catch {
                throw LLMClientError.decoding("Malformed /api/show response: \(error)")
            }
        } catch {
            throw Self.mapError(error)
        }
    }

    private func makeChatRequest(_ request: ChatRequest) throws -> URLRequest {
        let url = baseURLProvider().appendingPathComponent("api/chat")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = OllamaChatRequest(
            model: request.model,
            messages: request.messages.map {
                OllamaMessage(role: $0.role.rawValue, content: $0.content, images: $0.images)
            },
            stream: true
        )
        do {
            urlRequest.httpBody = try JSONEncoder().encode(body)
        } catch {
            throw LLMClientError.decoding("Failed to encode /api/chat request: \(error)")
        }
        return urlRequest
    }

    private func mapStatus(_ status: Int, model: String) -> LLMClientError {
        status == 404 ? .modelNotFound(model) : .http(status: status)
    }

    // Guarantees OllamaClient never surfaces a non-LLMClientError: cancellation
    // stays `.cancelled`, transport-layer URLErrors become `.transport`, and any
    // other stray error degrades to `.decoding` rather than leaking a Foundation type.
    private static func mapError(_ error: Error) -> LLMClientError {
        switch error {
        case let error as LLMClientError:
            return error
        case is CancellationError:
            return .cancelled
        case let error as URLError where error.code == .cancelled:
            return .cancelled
        case let error as URLError:
            return .transport(message: error.localizedDescription)
        default:
            return .decoding("Unexpected error: \(error)")
        }
    }
}

// MARK: - Ollama wire DTOs (provider-specific, not part of the LLMClient surface)

private struct OllamaChatRequest: Encodable {
    let model: String
    let messages: [OllamaMessage]
    let stream: Bool
}

private struct OllamaMessage: Codable {
    let role: String
    let content: String
    let images: [String]?
}

private struct OllamaChatChunk: Decodable {
    let message: OllamaMessage?
    let done: Bool?
    let error: String?
}

private struct OllamaTagsResponse: Decodable {
    struct Model: Decodable {
        let name: String
    }
    let models: [Model]
}

private struct OllamaShowRequest: Encodable {
    let model: String
}

private struct OllamaShowResponse: Decodable {
    let capabilities: [String]?
}
