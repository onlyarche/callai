import Foundation

enum ResponseChunk: Sendable, Equatable {
    case text(String)
    case image(Data)
    case audio(Data)
}
