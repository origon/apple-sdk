import XCTest
import OrigonSDK
@testable import OrigonSDKExample

@MainActor
final class ChatSessionClientTests: XCTestCase {
    func testCheckpointScopeUsesLengthPrefixedCrossPlatformVector() {
        let epoch = Data(0..<32)
        XCTAssertEqual(
            exampleCheckpointScopeKey(
                epoch: epoch,
                endpoint: "https://example.invalid/chat/api/widget",
                sessionId: "session-α"
            ),
            "1d2f8669466130bea1f357b8e8e54c7b05a57421c789e51300c0368053dac18f"
        )
        XCTAssertNotEqual(
            exampleCheckpointScopeKey(epoch: epoch, endpoint: "ab", sessionId: "c"),
            exampleCheckpointScopeKey(epoch: epoch, endpoint: "a", sessionId: "bc")
        )
    }

    func testCheckpointQualificationAnchorAuthorityAndPruning() {
        let rows = [
            message("seen", role: .user),
            message("own", role: .external),
            message("flow", role: .system),
            message("joined", role: .user, action: "joined"),
            message("first-new", role: .user),
            message("", role: .user),
        ]
        XCTAssertEqual(exampleUnreadAnchorMessageId(messages: rows, checkpointId: "seen"), "first-new")
        XCTAssertNil(exampleUnreadAnchorMessageId(messages: rows, checkpointId: nil))
        XCTAssertNil(exampleUnreadAnchorMessageId(messages: rows, checkpointId: "evicted"))
        XCTAssertEqual(exampleNewestEligibleMessageId(rows), "first-new")
        XCTAssertFalse(exampleShouldAdvanceCheckpoint(
            authoritative: false, sceneForeground: true, detailVisible: true,
            latestRowVisible: true, newestEligibleId: "first-new"
        ))
        XCTAssertFalse(exampleShouldAdvanceCheckpoint(
            authoritative: true, sceneForeground: false, detailVisible: true,
            latestRowVisible: true, newestEligibleId: "first-new"
        ))
        XCTAssertTrue(exampleShouldAdvanceCheckpoint(
            authoritative: true, sceneForeground: true, detailVisible: true,
            latestRowVisible: true, newestEligibleId: "first-new"
        ))

        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let recent = (0..<105).map { index in
            ExampleChatCheckpoint(
                version: exampleCheckpointVersion,
                scopeKey: "key-\(index)",
                lastSeenMessageId: "message-\(index)",
                lastAccessedAt: now.addingTimeInterval(TimeInterval(-index))
            )
        }
        let old = ExampleChatCheckpoint(
            version: exampleCheckpointVersion,
            scopeKey: "old",
            lastSeenMessageId: "old",
            lastAccessedAt: now.addingTimeInterval(-exampleCheckpointMaximumAge - 1)
        )
        let future = ExampleChatCheckpoint(
            version: exampleCheckpointVersion,
            scopeKey: "future",
            lastSeenMessageId: "future",
            lastAccessedAt: now.addingTimeInterval(1)
        )
        let pruned = pruneExampleCheckpoints(recent + [old, future], now: now)
        XCTAssertEqual(pruned.count, exampleCheckpointMaximumEntries)
        XCTAssertEqual(pruned.first?.scopeKey, "key-0")
        XCTAssertEqual(pruned.last?.scopeKey, "key-99")
    }

    func testCheckpointStoreIsAtomicSerializedScopedAndEpochBound() async throws {
        let epoch = LockedEpochStore(Data(0..<32))
        let files = LockedCheckpointFiles()
        let store = ExampleChatCheckpointStore(epochStore: epoch, fileStore: files)
        let endpoint = "https://example.invalid/chat/api/widget"

        async let first: Void = store.markSeen(
            endpoint: endpoint, sessionId: "session", messageId: "one",
            authoritative: true, sceneForeground: true, detailVisible: true,
            latestRowVisible: true, now: Date(timeIntervalSince1970: 10)
        )
        async let second: Void = store.markSeen(
            endpoint: endpoint, sessionId: "session", messageId: "two",
            authoritative: true, sceneForeground: true, detailVisible: true,
            latestRowVisible: true, now: Date(timeIntervalSince1970: 20)
        )
        _ = try await (first, second)
        let stored = try await store.read(
            endpoint: endpoint, sessionId: "session", now: Date(timeIntervalSince1970: 30)
        )
        XCTAssertEqual(stored?.lastSeenMessageId, "two")
        let otherScope = try await store.read(
            endpoint: endpoint + "/other", sessionId: "session"
        )
        XCTAssertNil(otherScope)

        let raw = try XCTUnwrap(files.data)
        XCTAssertFalse(String(decoding: raw, as: UTF8.self).contains(endpoint))
        XCTAssertFalse(String(decoding: raw, as: UTF8.self).contains("session"))
        XCTAssertFalse(String(decoding: raw, as: UTF8.self).contains(Data(0..<32).base64EncodedString()))
        XCTAssertGreaterThanOrEqual(files.replaceCount, 3)

        epoch.value = Data(repeating: 0xA5, count: 32)
        let restored = try await store.read(endpoint: endpoint, sessionId: "session")
        XCTAssertNil(restored)
    }

    func testCheckpointFailedReplacementDoesNotAcknowledgeAndCachedRowsDoNotAdvance() async throws {
        let epoch = LockedEpochStore(Data(repeating: 7, count: 32))
        let files = LockedCheckpointFiles()
        let store = ExampleChatCheckpointStore(epochStore: epoch, fileStore: files)
        try await store.markSeen(
            endpoint: "endpoint", sessionId: "session", messageId: "seed",
            authoritative: true, sceneForeground: true, detailVisible: true,
            latestRowVisible: true
        )
        files.failNextReplace = true
        do {
            try await store.markSeen(
                endpoint: "endpoint", sessionId: "session", messageId: "lost",
                authoritative: true, sceneForeground: true, detailVisible: true,
                latestRowVisible: true
            )
            XCTFail("expected replacement failure")
        } catch {}
        let afterFailure = try await store.read(endpoint: "endpoint", sessionId: "session")
        XCTAssertEqual(afterFailure?.lastSeenMessageId, "seed")

        try await store.markSeen(
            endpoint: "endpoint", sessionId: "session", messageId: "cached-only",
            authoritative: false, sceneForeground: true, detailVisible: true,
            latestRowVisible: true
        )
        let afterCached = try await store.read(endpoint: "endpoint", sessionId: "session")
        XCTAssertEqual(afterCached?.lastSeenMessageId, "seed")
    }

    func testViewportIntentFollowsExplicitSendButPreservesPassiveReader() {
        let baseline: Set<String> = ["old"]
        XCTAssertEqual(
            exampleTranscriptChangeDecision(
                intent: .explicitSend(previousOutgoingLocalIds: baseline),
                outgoingLocalIds: ["old", "new"], positioned: true, wasAtTail: false
            ),
            .init(followTail: true, consumeIntent: true)
        )
        XCTAssertEqual(
            exampleTranscriptChangeDecision(
                intent: nil, outgoingLocalIds: [], positioned: true, wasAtTail: false
            ),
            .init(followTail: false, consumeIntent: false)
        )
        XCTAssertEqual(
            exampleTranscriptChangeDecision(
                intent: nil, outgoingLocalIds: [], positioned: true, wasAtTail: true
            ),
            .init(followTail: true, consumeIntent: false)
        )
    }

    func testViewportRestoresStableAnchorAcrossReplacementKeyboardAndRotation() {
        let local = Message(id: "", localId: "draft", text: "pending")
        let delivered = Message(id: "server", localId: "draft", text: "sent")
        XCTAssertEqual(exampleTranscriptRowId(local, index: 4), exampleTranscriptRowId(delivered, index: 9))
        XCTAssertEqual(
            exampleViewportRestoreTarget(
                visibleRowIds: ["server-reader", "server-next"],
                atTail: false,
                tailId: "server-tail"
            ),
            "server-reader"
        )
        XCTAssertEqual(
            exampleViewportRestoreTarget(
                visibleRowIds: ["server-reader"], atTail: true, tailId: "server-tail"
            ),
            "server-tail"
        )
        XCTAssertEqual(exampleNewMessagesAccessibilityLabel, "New messages")
    }
    func testCachedSnapshotPaintsBeforeNamedAccessAndCannotGrantSend() async throws {
        let fake = FakeLateChatClient()
        let service = ChatService(chatClient: fake)
        let task = Task { await service.openSession(id: "saved") }
        await fake.waitForRequests(1)

        fake.yield(snapshot(source: "cache", authoritative: false, messages: [message("cached")]), at: 0)
        await waitUntil { service.sessionsState["saved"]?.loadState == .cached }

        XCTAssertEqual(service.messages.map(\.id), ["cached"])
        XCTAssertFalse(service.canSendFocusedSession)
        XCTAssertEqual(fake.accesses.map(\.id), ["saved"])
        XCTAssertEqual(fake.accesses.map(\.intent), [.explicitNavigation])

        fake.finishStream(at: 0)
        fake.succeedAccess(at: 0)
        _ = await task.result
        XCTAssertTrue(service.canSendFocusedSession)
    }

    func testFreshEmptyAndTypedRefreshFailureRemainDistinct() async throws {
        let fake = FakeLateChatClient()
        let service = ChatService(chatClient: fake)
        let emptyTask = Task { await service.openSession(id: "empty") }
        await fake.waitForRequests(1)
        fake.yield(snapshot(source: "network", authoritative: true, messages: []), at: 0)
        fake.finishStream(at: 0)
        fake.succeedAccess(at: 0)
        _ = await emptyTask.result
        XCTAssertEqual(service.sessionsState["empty"]?.loadState, .freshEmpty)

        let failedTask = Task { await service.openSession(id: "offline") }
        await fake.waitForRequests(2)
        fake.yield(snapshot(source: "cache", authoritative: false, messages: [message("saved")]), at: 1)
        fake.failRefresh(cachedShown: true, at: 1)
        fake.finishStream(at: 1)
        fake.failAccess(at: 1)
        _ = await failedTask.result
        XCTAssertEqual(
            service.sessionsState["offline"]?.loadState,
            .refreshFailed(cachedShown: true)
        )
        XCTAssertFalse(service.sessionsState["offline"]?.accessGranted ?? true)
        XCTAssertEqual(service.sessionsState["offline"]?.messages.map(\.id), ["saved"])
    }

    func testRapidDestinationAndClientReplacementFenceLatePublication() async throws {
        let fake = FakeLateChatClient()
        let service = ChatService(chatClient: fake)
        let firstA = Task { await service.openSession(id: "a") }
        await fake.waitForRequests(1)
        let b = Task { await service.openSession(id: "b") }
        await fake.waitForRequests(2)
        let finalA = Task { await service.openSession(id: "a") }
        await fake.waitForRequests(3)

        fake.yield(snapshot(source: "network", authoritative: true, messages: [message("stale-a")]), at: 0)
        fake.finishStream(at: 0)
        fake.succeedAccess(at: 0)
        fake.yield(snapshot(source: "network", authoritative: true, messages: [message("stale-b")]), at: 1)
        fake.finishStream(at: 1)
        fake.succeedAccess(at: 1)
        fake.yield(snapshot(source: "network", authoritative: true, messages: [message("current-a")]), at: 2)
        fake.finishStream(at: 2)
        fake.succeedAccess(at: 2)
        _ = await (firstA.result, b.result, finalA.result)

        XCTAssertEqual(service.currentSessionId, "a")
        XCTAssertEqual(service.messages.map(\.id), ["current-a"])
        XCTAssertNil(service.sessionsState["b"]?.messages.first { $0.id == "stale-b" })

        let endpointTask = Task { await service.openSession(id: "endpoint-old") }
        await fake.waitForRequests(4)
        service.clientWillChange()
        fake.yield(snapshot(source: "network", authoritative: true, messages: [message("late")]), at: 3)
        fake.finishStream(at: 3)
        fake.succeedAccess(at: 3)
        _ = await endpointTask.result
        XCTAssertFalse(service.sessionsState["endpoint-old"]?.accessGranted ?? true)
        XCTAssertFalse(service.sessionsState["endpoint-old"]?.messages.contains { $0.id == "late" } ?? false)
    }

    func testCancelledDestinationCannotPublishLateResults() async throws {
        let fake = FakeLateChatClient()
        let service = ChatService(chatClient: fake)
        let task = Task { await service.openSession(id: "cancelled") }
        await fake.waitForRequests(1)
        task.cancel()
        fake.yield(snapshot(source: "network", authoritative: true, messages: [message("late")]), at: 0)
        fake.finishStream(at: 0)
        fake.succeedAccess(at: 0)
        _ = await task.result
        XCTAssertFalse(service.sessionsState["cancelled"]?.accessGranted ?? true)
        XCTAssertFalse(service.sessionsState["cancelled"]?.messages.contains { $0.id == "late" } ?? false)
    }

    func testReconciliationOverlaysStableIdentityAndAttachmentPreview() {
        let preview = Attachment(
            id: "file", name: "photo", contentType: "image/jpeg",
            url: "https://remote/old", localUrl: "file:///preview"
        )
        let remoteFile = Attachment(
            id: "file", name: "photo", contentType: "image/jpeg",
            url: "https://remote/new"
        )
        let local = Message(
            id: "server-1", localId: "local-1", text: "old",
            attachments: [preview], status: .delivered
        )
        let remote = Message(
            id: "server-1", text: "authoritative",
            attachments: [remoteFile], status: .delivered
        )
        let live = Message(id: "live-2", text: "new live", status: .delivered)
        let failed = Message(id: "", localId: "failed-3", text: "retry", status: .failed)
        let state = ChatService.SessionUIState(
            messages: [local, live, failed],
            liveMessageKeys: ["live-2"]
        )

        let reconciled = ChatService.reconciling([remote], into: state)

        XCTAssertEqual(reconciled.messages.map(\.id), ["server-1", "live-2", ""])
        XCTAssertEqual(reconciled.messages[0].text, "authoritative")
        XCTAssertEqual(reconciled.messages[0].localId, "local-1")
        XCTAssertEqual(reconciled.messages[0].attachments[0].url, "https://remote/new")
        XCTAssertEqual(reconciled.messages[0].attachments[0].localUrl, "file:///preview")
    }

    func testReconciliationHandlesReorderEmptyAndIdempotentReplay() {
        let first = Message(id: "1", text: "first")
        let second = Message(id: "2", text: "second")
        let stale = Message(id: "stale", text: "drop me")
        let sending = Message(id: "", localId: "sending", text: "pending", status: .sending)
        let failed = Message(id: "", localId: "failed", text: "retry", status: .failed)
        let state = ChatService.SessionUIState(messages: [stale, sending, failed])

        let reordered = ChatService.reconciling([second, first], into: state)
        XCTAssertEqual(reordered.messages.map(\.id), ["2", "1", "", ""])
        let replayed = ChatService.reconciling([second, first], into: reordered)
        XCTAssertEqual(replayed.messages, reordered.messages)

        let emptied = ChatService.reconciling([], into: state)
        XCTAssertEqual(emptied.messages.map(\.localId), ["sending", "failed"])
    }

    func testDeliveredAndFailedUpdatesCorrelateToOneProvisionalRow() {
        let provisional = Message(
            id: "", localId: "sdk-local", text: "hello", status: .sending
        )
        let initial = ChatService.SessionUIState(
            messages: [provisional], liveMessageKeys: ["sdk-local"]
        )
        let delivered = Message(id: "server-id", text: "hello", status: .delivered)
        let deliveredState = ChatService.applyingMessageUpdate(
            key: "sdk-local", message: delivered, to: initial
        )
        XCTAssertEqual(deliveredState.messages.count, 1)
        XCTAssertEqual(deliveredState.messages[0].id, "server-id")
        XCTAssertEqual(deliveredState.messages[0].localId, "sdk-local")

        let replayed = ChatService.reconciling([delivered], into: deliveredState)
        XCTAssertEqual(replayed.messages.count, 1)
        XCTAssertEqual(replayed.messages[0].localId, "sdk-local")

        let failure = Message(id: "", text: "hello", errorText: "offline", status: .failed)
        let failedState = ChatService.applyingMessageUpdate(
            key: "sdk-local", message: failure, to: initial
        )
        XCTAssertEqual(failedState.messages.count, 1)
        XCTAssertEqual(failedState.messages[0].status, .failed)
        XCTAssertEqual(failedState.messages[0].localId, "sdk-local")
    }

    func testReconnectPreservesTranscriptAndGapRefetches() async throws {
        let fake = FakeLateChatClient()
        let service = ChatService(chatClient: fake)
        service.installStateForTesting(
            id: "chat",
            state: .init(messages: [message("before")], accessGranted: true)
        )

        service.receiveForTesting(.reconnecting(
            sessionId: "chat", attempt: 1, reason: .networkLoss
        ))
        XCTAssertEqual(service.currentConnectionState, .reconnecting)
        XCTAssertFalse(service.canSendFocusedSession)
        XCTAssertEqual(service.messages.map(\.id), ["before"])

        service.receiveForTesting(.reconnected(sessionId: "chat"))
        await fake.waitForStreamRequests(1)
        fake.yield(snapshot(
            source: "network", authoritative: true,
            messages: [message("before"), message("missed")]
        ), at: 0)
        fake.finishStream(at: 0)
        await waitUntil { service.messages.map(\.id) == ["before", "missed"] }
        XCTAssertEqual(service.currentConnectionState, .connected)
        XCTAssertTrue(service.canSendFocusedSession)
    }

    func testDroppedAttachmentFirstSendResumesSameId() async throws {
        let fake = FakeLateChatClient()
        let service = ChatService(chatClient: fake)
        let attachment = Attachment(
            id: "file", name: "photo.jpg", contentType: "image/jpeg",
            url: "https://example.invalid/file"
        )
        let pending = PendingAttachment(
            id: "local-file", fileName: "photo.jpg", contentType: "image/jpeg",
            previewImage: nil, status: .completed, progress: 100,
            attachment: attachment, errorText: nil
        )
        service.installStateForTesting(
            id: "chat",
            state: .init(
                messages: [message("kept")], accessGranted: false,
                connectionState: .dropped, pendingAttachments: [pending]
            )
        )

        await service.sendMessage(text: "")

        XCTAssertEqual(fake.starts.count, 1)
        XCTAssertEqual(fake.starts[0].sessionId, "chat")
        XCTAssertEqual(fake.starts[0].firstMessage.attachments.map(\.id), ["file"])
        XCTAssertEqual(service.messages.map(\.id), ["kept"])
        XCTAssertEqual(service.currentConnectionState, .connected)
        XCTAssertTrue(service.pendingAttachments.isEmpty)
    }

    func testCleanEndIsReadOnlyAndIgnoresStaleReconnect() async throws {
        let fake = FakeLateChatClient()
        let service = ChatService(chatClient: fake)
        service.installStateForTesting(
            id: "chat",
            state: .init(messages: [message("kept")], accessGranted: true)
        )

        service.receiveForTesting(.chatSessionEnded(
            sessionId: "chat", reason: "complete", acw: nil
        ))
        service.receiveForTesting(.reconnected(sessionId: "chat"))
        await service.sendMessage(text: "blocked")

        XCTAssertEqual(service.currentConnectionState, .ended)
        XCTAssertFalse(service.canSendFocusedSession)
        XCTAssertEqual(service.messages.map(\.id), ["kept"])
        XCTAssertTrue(fake.starts.isEmpty)
        XCTAssertTrue(fake.sent.isEmpty)
    }

    func testClientEpochFencesLateEventsAndRefocusRefetches() async throws {
        let fake = FakeLateChatClient()
        let service = ChatService(chatClient: fake)
        service.installStateForTesting(id: "chat", state: .init(messages: [message("kept")]))
        service.clientWillChange()
        service.receiveForTesting(.messageAdded(
            sessionId: "chat", message: message("stale")
        ))
        XCTAssertEqual(service.messages.map(\.id), ["kept"])

        service.clientDidChange()
        service.refetchFocusedSession()
        await fake.waitForStreamRequests(1)
        fake.yield(snapshot(
            source: "network", authoritative: true,
            messages: [message("kept"), message("refocused")]
        ), at: 0)
        fake.finishStream(at: 0)
        await waitUntil { service.messages.map(\.id) == ["kept", "refocused"] }
    }

    func testEndpointConfigurationMatrixAndCategoryRules() {
        var attachments = ExampleAttachmentPolicy()
        attachments.images = true
        attachments.audio = true
        let cases: [(ExampleServerConfig, Bool, Bool, Bool, Bool)] = [
            (.init(startMessage: "Voice", multipleChannels: false,
                   chatEnabled: false, callEnabled: true), false, true, false, false),
            (.init(startMessage: "Chat", multipleChannels: false,
                   chatEnabled: true, callEnabled: false), true, false, false, true),
            (.init(startMessage: "Both", multipleChannels: true,
                   chatEnabled: true, callEnabled: true), true, false, true, true),
            (.init(startMessage: "Split", multipleChannels: false,
                   chatEnabled: true, callEnabled: true), true, false, false, true),
        ]
        for (config, composer, voiceOnly, composerVoice, promptSend) in cases {
            let policy = ExampleEndpointPolicy(config: config)
            XCTAssertEqual(policy.greeting, config.startMessage)
            XCTAssertEqual(policy.showsComposer, composer)
            XCTAssertEqual(policy.showsVoiceOnlyAction, voiceOnly)
            XCTAssertEqual(policy.showsComposerVoiceAction, composerVoice)
            XCTAssertEqual(policy.promptSendEnabled, promptSend)
        }

        let enabled = ExampleEndpointPolicy(config: .init(
            startMessage: "  ", multipleChannels: false,
            chatEnabled: true, callEnabled: false, attachments: attachments
        ))
        XCTAssertEqual(enabled.greeting, "How can I help you?")
        XCTAssertTrue(enabled.attachments.allows(.images))
        XCTAssertTrue(enabled.attachments.allows(.audio))
        XCTAssertFalse(enabled.attachments.allows(.videos))
        XCTAssertFalse(enabled.attachments.allows(.documents))

        let disabled = ExampleEndpointPolicy(config: .init(
            startMessage: "Hidden", multipleChannels: false,
            chatEnabled: false, callEnabled: true, attachments: attachments
        ))
        XCTAssertFalse(disabled.attachments.allows(.images))
        XCTAssertFalse(disabled.promptSendEnabled)
    }

    func testEndpointConfigurationReplacementRejectsStaleClient() {
        let old = ExampleServerConfig(
            startMessage: "Old", multipleChannels: false,
            chatEnabled: true, callEnabled: false
        )
        let fresh = ExampleServerConfig(
            startMessage: "Fresh", multipleChannels: true,
            chatEnabled: true, callEnabled: true
        )
        var replacement = ExampleConfigReplacement()
        let oldEpoch = replacement.begin()
        XCTAssertTrue(replacement.install(old, for: oldEpoch))
        let freshEpoch = replacement.begin()
        XCTAssertNil(replacement.value)
        XCTAssertFalse(replacement.install(old, for: oldEpoch))
        XCTAssertTrue(replacement.install(fresh, for: freshEpoch))
        XCTAssertEqual(replacement.value, fresh)
    }

    func testCachedEndpointConfigurationIsPresentationOnlyUntilAuthoritative() {
        let cached = ExampleServerConfig(
            startMessage: "Cached greeting",
            multipleChannels: true,
            chatEnabled: true,
            callEnabled: true,
            attachments: ExampleAttachmentPolicy(
                AttachmentPolicy(
                    images: .init(enabled: true, maxSize: 5),
                    documents: .init(enabled: true, maxSize: 5),
                    videos: .init(enabled: true, maxSize: 5),
                    audio: .init(enabled: true, maxSize: 5)
                )
            )
        )
        let policy = ExampleEndpointPolicy(config: cached, authoritative: false)
        XCTAssertEqual(policy.greeting, "Cached greeting")
        XCTAssertFalse(policy.showsComposer)
        XCTAssertFalse(policy.showsVoiceOnlyAction)
        XCTAssertFalse(policy.showsComposerVoiceAction)
        XCTAssertFalse(policy.promptSendEnabled)
        XCTAssertFalse(policy.attachments.allows(.images))
    }

    private func waitUntil(
        _ predicate: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<200 where !predicate() { await Task.yield() }
        XCTAssertTrue(predicate(), file: file, line: line)
    }

    private func message(
        _ id: String,
        role: MessageRole = .external,
        action: String? = nil
    ) -> Message {
        Message(role: role, id: id, text: id, action: action)
    }

    private func snapshot(
        source: String,
        authoritative: Bool,
        messages: [Message]
    ) -> SessionLoadUpdate {
        let encoded = try! JSONEncoder().encode(messages)
        let history = String(decoding: encoded, as: UTF8.self)
        let json = """
        {"source":"\(source)","authoritative":\(authoritative),"refreshedAt":1,
         "session":{"history":\(history),"control":"ai"}}
        """
        let value = try! JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8))
        return .snapshot(value)
    }
}

private final class LockedEpochStore: ExampleCheckpointEpochStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Data

    init(_ value: Data) { storedValue = value }

    var value: Data {
        get { lock.withLock { storedValue } }
        set { lock.withLock { storedValue = newValue } }
    }

    func loadOrCreateEpoch() throws -> Data { value }
}

private final class LockedCheckpointFiles: ExampleCheckpointFileStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storedData: Data?
    private var replacements = 0
    var failNextReplace = false

    var data: Data? { lock.withLock { storedData } }
    var replaceCount: Int { lock.withLock { replacements } }

    func read() throws -> Data? { data }

    func replace(with data: Data) throws {
        try lock.withLock {
            if failNextReplace {
                failNextReplace = false
                throw CocoaError(.fileWriteUnknown)
            }
            storedData = data
            replacements += 1
        }
    }
}

@MainActor
private final class FakeLateChatClient: ChatSessionClient {
    struct Access {
        let id: String
        let intent: ChatAccessIntent
        let continuation: CheckedContinuation<StartSessionResponse, Error>
    }

    private(set) var streamIds: [String] = []
    private(set) var streams: [AsyncThrowingStream<SessionLoadUpdate, Error>.Continuation] = []
    private(set) var accesses: [Access] = []
    private(set) var starts: [StartChatOptions] = []
    private(set) var sent: [(String, SendMessagePayload)] = []

    func sessionUpdates(
        id: String,
        policy: SessionLoadPolicy
    ) throws -> AsyncThrowingStream<SessionLoadUpdate, Error> {
        streamIds.append(id)
        return AsyncThrowingStream { continuation in
            self.streams.append(continuation)
        }
    }

    func acquireChatAccess(
        sessionId: String,
        intent: ChatAccessIntent
    ) async throws -> StartSessionResponse {
        try await withCheckedThrowingContinuation { continuation in
            accesses.append(Access(id: sessionId, intent: intent, continuation: continuation))
        }
    }

    func startChat(_ options: StartChatOptions) async throws -> StartSessionResponse {
        starts.append(options)
        return StartSessionResponse(
            sessionId: options.sessionId ?? "new-chat",
            url: "https://example.invalid", token: "test"
        )
    }

    func sendMessage(id: String, payload: SendMessagePayload) async throws {
        sent.append((id, payload))
    }

    func waitForRequests(_ count: Int) async {
        for _ in 0..<500 where streams.count < count || accesses.count < count {
            await Task.yield()
        }
        XCTAssertEqual(streams.count, count)
        XCTAssertEqual(accesses.count, count)
    }

    func waitForStreamRequests(_ count: Int) async {
        for _ in 0..<500 where streams.count < count { await Task.yield() }
        XCTAssertEqual(streams.count, count)
    }

    func yield(_ update: SessionLoadUpdate, at index: Int) { streams[index].yield(update) }
    func finishStream(at index: Int) { streams[index].finish() }

    func failRefresh(cachedShown: Bool, at index: Int) {
        streams[index].yield(.refreshFailed(
            error: OrigonError(kind: .other, message: "offline"),
            cachedSnapshotEmitted: cachedShown
        ))
    }

    func succeedAccess(at index: Int) {
        let id = accesses[index].id
        accesses[index].continuation.resume(
            returning: StartSessionResponse(sessionId: id, url: "https://example.invalid", token: "test")
        )
    }

    func failAccess(at index: Int) {
        accesses[index].continuation.resume(
            throwing: OrigonError(kind: .other, message: "unavailable")
        )
    }
}
