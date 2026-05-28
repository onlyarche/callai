import Foundation

struct ChatRequest: Sendable, Equatable {
    enum Role: String, Sendable, Equatable {
        case system
        case user
        case assistant
    }

    struct Message: Sendable, Equatable {
        var role: Role
        var content: String
        // base64-encoded PNG strings, no `data:` prefix — vision models only (Ollama spec).
        var images: [String]?

        init(role: Role, content: String, images: [String]? = nil) {
            self.role = role
            self.content = content
            self.images = images
        }
    }

    var model: String
    var messages: [Message]

    init(model: String, messages: [Message]) {
        self.model = model
        self.messages = messages
    }
}
