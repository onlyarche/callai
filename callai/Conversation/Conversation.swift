import Foundation
import SwiftData

@Model
final class Conversation {
    @Attribute(.unique) var id: UUID
    // Derived from the first user message; used to label otherwise-empty
    // conversations and consumed in earnest by M5 history.
    var title: String
    var createdAt: Date
    var updatedAt: Date

    @Relationship(deleteRule: .cascade, inverse: \Message.conversation)
    var messages: [Message]

    init(id: UUID = UUID(), title: String = "", createdAt: Date = .now) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.messages = []
    }

    // SwiftData relationships are unordered — callers needing multi-turn
    // context must read this, never `messages` directly.
    var orderedMessages: [Message] {
        messages.sorted { $0.createdAt < $1.createdAt }
    }
}
