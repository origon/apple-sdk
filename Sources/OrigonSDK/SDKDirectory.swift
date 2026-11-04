import Foundation

/// A protected folder the SDK owns under `Application Support/ai.origon.sdk`.
enum SDKDirectory {
    static let namespace = "ai.origon.sdk"

    static func applicationSupport() throws -> URL {
        try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
    }

    /// Creates `<applicationSupport>/ai.origon.sdk/<name>`, excludes it from
    /// backup, and on iOS gives it complete-until-first-authentication Data
    /// Protection, which new files inside inherit. The namespace folder and its
    /// other children keep their own attributes.
    static func prepare(_ name: String, in applicationSupport: URL) throws -> URL {
        let owner = applicationSupport.appendingPathComponent(namespace, isDirectory: true)
        let root = owner.appendingPathComponent(name, isDirectory: true)
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
