import Foundation
import CryptoKit
import Security
import UIKit
import OrigonSDK

let exampleCheckpointVersion = 1
let exampleCheckpointMaximumEntries = 100
let exampleCheckpointMaximumAge: TimeInterval = 30 * 24 * 60 * 60
let exampleNewMessagesAccessibilityLabel = "New messages"

struct ExampleChatCheckpoint: Codable, Equatable, Sendable {
    let version: Int
    let scopeKey: String
    var lastSeenMessageId: String
    var lastAccessedAt: Date
}

protocol ExampleCheckpointEpochStore: Sendable {
    func loadOrCreateEpoch() throws -> Data
}

protocol ExampleCheckpointFileStore: Sendable {
    func read() throws -> Data?
    func replace(with data: Data) throws
}

struct KeychainCheckpointEpochStore: ExampleCheckpointEpochStore {
    private let service = "ai.origon.sdk.example.chat-checkpoint"
    private let account = "epoch-v1"

    func loadOrCreateEpoch() throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, data.count == 32 {
            return data
        }
        guard status == errSecItemNotFound || status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }

        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(errSecAllocate))
        }
        let epoch = Data(bytes)
        var insertion = query
        insertion.removeValue(forKey: kSecReturnData as String)
        insertion.removeValue(forKey: kSecMatchLimit as String)
        insertion[kSecValueData as String] = epoch
        insertion[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(insertion as CFDictionary, nil)
        if addStatus == errSecSuccess { return epoch }
        if addStatus == errSecDuplicateItem {
            var racedResult: CFTypeRef?
            let racedStatus = SecItemCopyMatching(query as CFDictionary, &racedResult)
            if racedStatus == errSecSuccess,
               let racedEpoch = racedResult as? Data,
               racedEpoch.count == 32 {
                return racedEpoch
            }
        }
        throw NSError(domain: NSOSStatusErrorDomain, code: Int(addStatus))
    }
}

final class ProtectedCheckpointFileStore: ExampleCheckpointFileStore, @unchecked Sendable {
    private let fileManager: FileManager
    private let directory: URL
    private let file: URL

    init(fileManager: FileManager = .default, root: URL? = nil) throws {
        self.fileManager = fileManager
        let applicationSupport = try root ?? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        directory = applicationSupport
            .appendingPathComponent("OrigonSDKExample", isDirectory: true)
            .appendingPathComponent("UnreadCheckpoints", isDirectory: true)
        file = directory.appendingPathComponent("rows-v1.json", isDirectory: false)
    }

    func read() throws -> Data? {
        guard fileManager.fileExists(atPath: file.path) else { return nil }
        return try Data(contentsOf: file)
    }

    func replace(with data: Data) throws {
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        var directoryValues = URLResourceValues()
        directoryValues.isExcludedFromBackup = true
        var protectedDirectory = directory
        try protectedDirectory.setResourceValues(directoryValues)

        let temporary = directory.appendingPathComponent(".rows-\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: temporary) }
        try data.write(
            to: temporary,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
        var fileValues = URLResourceValues()
        fileValues.isExcludedFromBackup = true
        var protectedTemporary = temporary
        try protectedTemporary.setResourceValues(fileValues)
        if fileManager.fileExists(atPath: file.path) {
            _ = try fileManager.replaceItemAt(file, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: file)
        }
    }
}

final class ExampleChatCheckpointStore: @unchecked Sendable {
    private let epochStore: any ExampleCheckpointEpochStore
    private let fileStore: any ExampleCheckpointFileStore
    private let queue = DispatchQueue(label: "ai.origon.example.unread-checkpoints")

    init(
        epochStore: any ExampleCheckpointEpochStore,
        fileStore: any ExampleCheckpointFileStore
    ) {
        self.epochStore = epochStore
        self.fileStore = fileStore
    }

    static func live() throws -> ExampleChatCheckpointStore {
        try ExampleChatCheckpointStore(
            epochStore: KeychainCheckpointEpochStore(),
            fileStore: ProtectedCheckpointFileStore()
        )
    }

    func read(endpoint: String, sessionId: String, now: Date = Date()) async throws
        -> ExampleChatCheckpoint? {
        try await perform { [self] in
            let key = try scopedKey(endpoint: endpoint, sessionId: sessionId)
            var records = try load()
            guard let index = records.firstIndex(where: { $0.scopeKey == key }) else { return nil }
            let found = records[index]
            records[index].lastAccessedAt = now
            try save(pruneExampleCheckpoints(records, now: now))
            return found
        }
    }

    func markSeen(
        endpoint: String,
        sessionId: String,
        messageId: String?,
        authoritative: Bool,
        sceneForeground: Bool,
        detailVisible: Bool,
        latestRowVisible: Bool,
        now: Date = Date()
    ) async throws {
        guard exampleShouldAdvanceCheckpoint(
            authoritative: authoritative,
            sceneForeground: sceneForeground,
            detailVisible: detailVisible,
            latestRowVisible: latestRowVisible,
            newestEligibleId: messageId
        ), let messageId else { return }
        try await perform { [self] in
            let key = try scopedKey(endpoint: endpoint, sessionId: sessionId)
            var records = try load().filter { $0.scopeKey != key }
            records.append(ExampleChatCheckpoint(
                version: exampleCheckpointVersion,
                scopeKey: key,
                lastSeenMessageId: messageId,
                lastAccessedAt: now
            ))
            try save(pruneExampleCheckpoints(records, now: now))
        }
    }

    private func scopedKey(endpoint: String, sessionId: String) throws -> String {
        let epoch = try epochStore.loadOrCreateEpoch()
        guard epoch.count == 32 else { throw CocoaError(.fileReadCorruptFile) }
        return exampleCheckpointScopeKey(epoch: epoch, endpoint: endpoint, sessionId: sessionId)
    }

    private func load() throws -> [ExampleChatCheckpoint] {
        let data = try fileStore.read()
        guard let data else { return [] }
        return try JSONDecoder().decode([ExampleChatCheckpoint].self, from: data)
            .filter { $0.version == exampleCheckpointVersion }
    }

    private func save(_ records: [ExampleChatCheckpoint]) throws {
        let data = try JSONEncoder().encode(records)
        try fileStore.replace(with: data)
    }

    private func perform<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try operation() })
            }
        }
    }
}

func exampleCheckpointScopeKey(epoch: Data, endpoint: String, sessionId: String) -> String {
    var input = Data("origon-example-checkpoint-v1".utf8)
    input.append(epoch)
    for value in [endpoint, sessionId] {
        let bytes = Data(value.utf8)
        var length = UInt32(bytes.count).bigEndian
        withUnsafeBytes(of: &length) { input.append(contentsOf: $0) }
        input.append(bytes)
    }
    return SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
}

func pruneExampleCheckpoints(
    _ records: [ExampleChatCheckpoint],
    now: Date
) -> [ExampleChatCheckpoint] {
    records
        .filter {
            let age = now.timeIntervalSince($0.lastAccessedAt)
            return age >= 0 && age <= exampleCheckpointMaximumAge
        }
        .sorted { $0.lastAccessedAt > $1.lastAccessedAt }
        .prefix(exampleCheckpointMaximumEntries)
        .map { $0 }
}

extension Message {
    var qualifiesForExampleUnread: Bool {
        role == .user && action?.isEmpty != false && !id.isEmpty
    }
}

func exampleUnreadAnchorMessageId(messages: [Message], checkpointId: String?) -> String? {
    guard let checkpointId, !checkpointId.isEmpty,
          let index = messages.firstIndex(where: { $0.id == checkpointId })
    else { return nil }
    return messages.dropFirst(index + 1).first(where: \.qualifiesForExampleUnread)?.id
}

func exampleNewestEligibleMessageId(_ messages: [Message]) -> String? {
    messages.last(where: \.qualifiesForExampleUnread)?.id
}

func exampleShouldAdvanceCheckpoint(
    authoritative: Bool,
    sceneForeground: Bool,
    detailVisible: Bool,
    latestRowVisible: Bool,
    newestEligibleId: String?
) -> Bool {
    authoritative && sceneForeground && detailVisible && latestRowVisible && newestEligibleId != nil
}

struct ExampleTranscriptRow: Identifiable {
    let index: Int
    let message: Message
    var id: String { exampleTranscriptRowId(message, index: index) }
}

func exampleTranscriptRowId(_ message: Message, index: Int) -> String {
    if let localId = message.localId, !localId.isEmpty { return "local-\(localId)" }
    return message.id.isEmpty ? "index-\(index)" : "server-\(message.id)"
}

enum ExampleTranscriptFollowIntent: Equatable {
    case explicitSend(previousOutgoingLocalIds: Set<String>)
}

struct ExampleTranscriptChangeDecision: Equatable {
    let followTail: Bool
    let consumeIntent: Bool
}

func exampleTranscriptChangeDecision(
    intent: ExampleTranscriptFollowIntent?,
    outgoingLocalIds: Set<String>,
    positioned: Bool,
    wasAtTail: Bool
) -> ExampleTranscriptChangeDecision {
    if case .explicitSend(let previous) = intent,
       !outgoingLocalIds.subtracting(previous).isEmpty {
        return .init(followTail: true, consumeIntent: true)
    }
    return .init(followTail: positioned && wasAtTail, consumeIntent: false)
}

func exampleViewportRestoreTarget(
    visibleRowIds: [String],
    atTail: Bool,
    tailId: String?
) -> String? {
    atTail ? tailId : visibleRowIds.first
}

/// One pending-upload tile in the chat composer.
///
/// `id` is a local UUID assigned at pick time. It serves two purposes:
/// (1) the SwiftUI `Identifiable` key for `ForEach`; and (2) the
/// `uploadId` we pass to `client.uploadAttachment(...)` so that
/// `client.cancelUpload(uploadId: id)` can cancel the upload in flight.
/// Removing a completed tile only discards the local reference.
struct PendingAttachment: Identifiable, Equatable {
    let id: String
    let fileName: String
    let contentType: String
    let previewImage: UIImage?
    var status: Status
    var progress: Double
    var attachment: Attachment?
    var errorText: String?

    enum Status: Equatable {
        case uploading
        case completed
        case error
    }

    var isImage: Bool { contentType.hasPrefix("image/") }

    var fileExtension: String {
        (fileName as NSString).pathExtension.uppercased()
    }

    static func == (lhs: PendingAttachment, rhs: PendingAttachment) -> Bool {
        lhs.id == rhs.id
            && lhs.status == rhs.status
            && lhs.progress == rhs.progress
            && lhs.attachment == rhs.attachment
            && lhs.errorText == rhs.errorText
    }
}
