import Foundation
import SwiftData

@Model
final class Message {
    // Raw value of ChatRequest.Role. M4 only persists user/assistant;
    // `system` arrives with PromptTemplate later, so the column already fits it.
    var roleRaw: String
    var content: String
    // base64 PNG seam — always nil in M4, populated by M6 vision support.
    var images: [String]?
    var createdAt: Date
    var conversation: Conversation?

    init(role: ChatRequest.Role, content: String, images: [String]? = nil, createdAt: Date = .now) {
        self.roleRaw = role.rawValue
        self.content = content
        self.images = images
        self.createdAt = createdAt
    }

    var role: ChatRequest.Role {
        // Unknown raw values fall back to .user rather than crashing a query.
        ChatRequest.Role(rawValue: roleRaw) ?? .user
    }
}
