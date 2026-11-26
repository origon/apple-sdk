import Foundation

enum ChatCacheStorage {
    static let namespace = "ai.origon.sdk"
    static let directory = "chat-cache-v1"

    static func prepare() throws -> URL {
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return try prepare(in: applicationSupport)
    }

    /// The folder the SDK caches its denoiser model in (`ClientConfig.models_dir`):
    /// protected, excluded from backup, refetched if the OS clears it.
    static func prepareModels() throws -> URL {
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return try prepare(modelsDirectory, in: applicationSupport)
    }

    static let modelsDirectory = "denoiser-models"

    /// Test seam: production always supplies Application Support.
    static func prepare(in applicationSupport: URL) throws -> URL {
        try prepare(directory, in: applicationSupport)
    }

    private static func prepare(_ directory: String, in applicationSupport: URL) throws -> URL {
        let owner = applicationSupport.appendingPathComponent(namespace, isDirectory: true)
        let root = owner.appendingPathComponent(directory, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: protectedDirectoryAttributes
        )
        try excludeFromBackup(root)
        #if os(iOS) || os(tvOS) || os(watchOS)
        try FileManager.default.setAttributes(
            protectedDirectoryAttributes,
            ofItemAtPath: root.path
        )
        #endif
        return root
    }

    private static var protectedDirectoryAttributes: [FileAttributeKey: Any] {
        #if os(iOS) || os(tvOS) || os(watchOS)
        return [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        #else
        return [:]
        #endif
    }

    private static func excludeFromBackup(_ url: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = url
        try mutable.setResourceValues(values)
    }
}
