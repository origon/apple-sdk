import Foundation

enum ChatCacheStorage {
    static let directory = "chat-cache-v1"

    static func prepare() throws -> URL {
        try prepare(in: SDKDirectory.applicationSupport())
    }

    /// Test seam: production always supplies Application Support.
    static func prepare(in applicationSupport: URL) throws -> URL {
        try SDKDirectory.prepare(directory, in: applicationSupport)
    }
}
