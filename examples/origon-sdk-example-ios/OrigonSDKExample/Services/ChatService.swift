import SwiftUI
import Combine
import OrigonSDK

/// Owns in-memory chat state for every active chat session.
///
/// Multi-active by design: each open chat session keeps its own
/// `SessionUIState` (messages, typing flag, pending uploads) in
/// `sessionsState`. The `messages`, `isTyping`, and `pendingAttachments`
/// accessors project the focused session (`currentSessionId`) so the
/// existing view bindings keep working.
///
/// Lifecycle:
/// - `openSession(id:)` focuses an existing session if we already hold
///   state for it, otherwise fetches history + opens the SDK chat
///   channel and stores fresh state.
/// - `openSession(id: nil)` switches focus to the "new session" empty
///   state. Other open sessions stay alive in the background.
/// - `sendMessage(text:)` lazily opens an SDK chat session on the very
///   first send when there is none, then dispatches to
///   `client.sendMessage`. The SDK auto-fires `messageAdded(provisional)`
///   and `messageUpdated(delivered/failed)`; the event handler is what
///   populates `messages`.
/// - `uploadFile(...)` drives the upload straight through the SDK with
///   live `onProgress` updates. The write lane is widget-scoped, so no
///   session is opened for it — an attachment can be the first thing a
///   visitor sends. Attachments persist as `PendingAttachment` rows
///   until either bundled into a `sendMessage` or removed by the user
///   (which also deletes the server-side blob).
/// - `endCurrentSession()` ends the focused SDK session and drops its
///   UI state. Background sessions are unaffected.
@MainActor
final class ChatService: ObservableObject {

    enum DestinationLoadState: Equatable {
        case idle
        case loading
        case cached
        case network
        case freshEmpty
        case refreshFailed(cachedShown: Bool)
        case failed
    }

    enum ConnectionState: Equatable {
        case connected
        case reconnecting
        case dropped
        case ended
    }

    struct SessionUIState: Equatable {
        var messages: [Message] = []
        var isTyping: Bool = false
        var typingState: TypingState = .init()
        /// Cache is presentation only. Sending is enabled exclusively after
        /// the named explicit-navigation access operation wins this epoch.
        var accessGranted: Bool = false
        /// The transcript and composer draft outlive transport loss. Only a
        /// clean end is read-only; a dropped session is resumed under the
        /// same id by the next accepted send.
        var connectionState: ConnectionState = .connected
        var loadState: DestinationLoadState = .idle
        /// Rows received from the live event lane while a finite refresh is
        /// running. Reconciliation retains these until the server snapshot
        /// contains their server id.
        var liveMessageKeys: Set<String> = []
        /// Composer-tile state for this session. Survives session
        /// switches so an upload kicked off in session A doesn't vanish
        /// when the user peeks at session B.
        var pendingAttachments: [PendingAttachment] = []
        /// Which option the user tapped on each interactive prompt, keyed by
        /// the prompt message's id.
        ///
        /// In memory only, and deliberately so: connect persists neither the
        /// chosen `value` nor the `galleryLabel` on the reply row, so a
        /// restored transcript cannot say which card was picked. This record
        /// is the only thing that can — see `selection(for:in:)`, which falls
        /// back to a label match for history it never saw live.
        var promptSelections: [String: PromptSelection] = [:]
    }

    /// The option a user tapped on one prompt. `cardIndex` is `nil` for a
    /// top-level button row and the card's position for a gallery pick —
    /// carried because two cards may share a button label.
    struct PromptSelection: Equatable {
        var cardIndex: Int?
        var buttonLabel: String
    }

    @Published private(set) var sessionsState: [String: SessionUIState] = [:]
    @Published private(set) var currentSessionId: String?
    @Published var error: String?

    /// Pending uploads queued before any chat session exists. Uploads no
    /// longer wait on a session, so this list is drained by whichever
    /// comes first: `ensureChatSession` (the lazy start on the first
    /// send) or `adoptDrafts(into:)` (the user focusing an existing
    /// session). Both move the rows into that session's
    /// `pendingAttachments`.
    @Published private(set) var draftPendingAttachments: [PendingAttachment] = []

    private weak var sdk: SDKManager?
    private let testChatClient: (any ChatSessionClient)?
    private var cancellables = Set<AnyCancellable>()
    private var clientEpoch: UInt64 = 0
    private var destinationEpoch: UInt64 = 0
    private var refetchEpoch: [String: UInt64] = [:]
    private var refetchTasks: [String: Task<Void, Never>] = [:]
    private var acceptingEvents = true

    /// In-flight lazy session-start. Racing callers (e.g. the user taps
    /// send twice with no session yet) all `await` this single task so
    /// only one `POST /session/start` fires and the draft → session
    /// migration happens exactly once.
    private var sessionStartTask: Task<String, Error>?

    init(chatClient: (any ChatSessionClient)? = nil) {
        self.testChatClient = chatClient
    }

    /// SDKManager creates this and calls `bind(to:)` once it can pass `self`.
    /// Subscribes to the manager's event stream so messages and typing
    /// updates land in `sessionsState` for every open chat session.
    func bind(to manager: SDKManager) {
        self.sdk = manager
        manager.events
            .sink { [weak self] event in self?.handleEvent(event) }
            .store(in: &cancellables)
    }

    /// Fence every in-flight destination operation before the manager
    /// installs or tears down a client. Late cache, network, and named-open
    /// results can finish, but cannot publish into the replacement endpoint.
    func clientWillChange() {
        acceptingEvents = false
        clientEpoch &+= 1
        destinationEpoch &+= 1
        for id in sessionsState.keys {
            sessionsState[id]?.accessGranted = false
        }
    }

    func clientDidChange() { acceptingEvents = true }

    private var destinationClient: (any ChatSessionClient)? {
        testChatClient ?? sdk?.chatClient
    }

    // MARK: - Focused-session accessors

    /// Messages for the currently focused session. The UI binds here.
    var messages: [Message] {
        guard let id = currentSessionId else { return [] }
        return sessionsState[id]?.messages ?? []
    }

    /// Whether the peer is typing in the focused session.
    var isTyping: Bool {
        guard let id = currentSessionId else { return false }
        return sessionsState[id]?.isTyping ?? false
    }

    var typingParticipant: TypingParticipant? {
        guard let id = currentSessionId else { return nil }
        return sessionsState[id]?.typingState.participants.first
    }

    /// Composer-tile list for the focused session, or the draft list
    /// when no session is open yet.
    var pendingAttachments: [PendingAttachment] {
        if let id = currentSessionId {
            return sessionsState[id]?.pendingAttachments ?? []
        }
        return draftPendingAttachments
    }

    var attachmentsAllowed: Bool {
        ExampleAttachmentCategory.allCases.contains {
            sdk?.endpointPolicy.attachments.allows($0) == true
        }
    }

    func attachmentAllowed(contentType: String) -> Bool {
        sdk?.endpointPolicy.attachments.allows(
            ExampleAttachmentCategory(contentType: contentType)
        ) == true
    }

    var hasUploadingAttachments: Bool {
        pendingAttachments.contains { $0.status == .uploading }
    }

    var canSendFocusedSession: Bool {
        guard let id = currentSessionId else { return true }
        guard let state = sessionsState[id] else { return false }
        switch state.connectionState {
        case .connected: return state.accessGranted
        case .dropped: return true
        case .reconnecting, .ended: return false
        }
    }

    var currentConnectionState: ConnectionState {
        guard let id = currentSessionId else { return .connected }
        return sessionsState[id]?.connectionState ?? .connected
    }

    var focusedHistoryIsAuthoritative: Bool {
        guard let id = currentSessionId, let state = sessionsState[id] else { return false }
        return state.loadState == .network || state.loadState == .freshEmpty
    }

    var focusedLoadState: DestinationLoadState {
        guard let id = currentSessionId else { return .idle }
        return sessionsState[id]?.loadState ?? .idle
    }

    // MARK: - Session lifecycle

    /// Focus a chat session.
    ///
    /// - Parameter id: `nil` switches to the "new session" empty state
    ///   without touching any open sessions. A non-nil id either focuses
    ///   existing in-memory state, or fetches history + opens the SDK
    ///   chat channel for that id (and refreshes the sidebar list so the
    ///   newly-active session is visible there).
    func openSession(id: String?) async {
        destinationEpoch &+= 1
        let operation = destinationEpoch
        let epoch = clientEpoch
        guard let id else {
            currentSessionId = nil
            return
        }
        guard let client = destinationClient else { return }

        var state = sessionsState[id] ?? SessionUIState()
        state.accessGranted = false
        state.loadState = .loading
        sessionsState[id] = state
        currentSessionId = id
        adoptDrafts(into: id)

        async let history: Void = loadDestination(
            id: id, client: client, clientEpoch: epoch, operation: operation
        )
        async let access: Void = acquireDestination(
            id: id, client: client, clientEpoch: epoch, operation: operation
        )
        _ = await (history, access)
        guard destinationIsCurrent(id: id, clientEpoch: epoch, operation: operation) else {
            return
        }
        try? await sdk?.refreshSessions()
    }

    private func loadDestination(
        id: String,
        client: any ChatSessionClient,
        clientEpoch epoch: UInt64,
        operation: UInt64
    ) async {
        do {
            for try await update in try client.sessionUpdates(id: id, policy: .cacheThenNetwork) {
                guard destinationIsCurrent(id: id, clientEpoch: epoch, operation: operation) else {
                    return
                }
                switch update {
                case .snapshot(let snapshot):
                    var state = sessionsState[id] ?? SessionUIState()
                    state = Self.reconciling(snapshot.session.history, into: state)
                    if snapshot.authoritative {
                        state.loadState = snapshot.session.history.isEmpty ? .freshEmpty : .network
                    } else {
                        state.loadState = .cached
                    }
                    sessionsState[id] = state
                case .refreshFailed(let refreshError, let cachedSnapshotEmitted):
                    sessionsState[id]?.loadState = .refreshFailed(cachedShown: cachedSnapshotEmitted)
                    error = cachedSnapshotEmitted
                        ? "Showing saved messages. Couldn't refresh this conversation."
                        : "Failed to load conversation: \(refreshError.localizedDescription)"
                }
            }
        } catch {
            guard destinationIsCurrent(id: id, clientEpoch: epoch, operation: operation) else {
                return
            }
            sessionsState[id]?.loadState = .failed
            self.error = "Failed to load conversation: \(error.localizedDescription)"
        }
    }

    private func acquireDestination(
        id: String,
        client: any ChatSessionClient,
        clientEpoch epoch: UInt64,
        operation: UInt64
    ) async {
        do {
            _ = try await client.acquireChatAccess(
                sessionId: id,
                intent: .explicitNavigation
            )
            guard destinationIsCurrent(id: id, clientEpoch: epoch, operation: operation) else {
                return
            }
            sessionsState[id]?.accessGranted = true
            if sessionsState[id]?.connectionState != .ended {
                sessionsState[id]?.connectionState = .connected
            }
        } catch {
            guard destinationIsCurrent(id: id, clientEpoch: epoch, operation: operation) else {
                return
            }
            sessionsState[id]?.accessGranted = false
            self.error = "Conversation is view-only: \(error.localizedDescription)"
        }
    }

    private func destinationIsCurrent(
        id: String,
        clientEpoch: UInt64,
        operation: UInt64
    ) -> Bool {
        !Task.isCancelled && self.clientEpoch == clientEpoch &&
            destinationEpoch == operation && currentSessionId == id
    }

    /// Move any draft tiles onto the session being focused.
    ///
    /// The draft list holds rows picked while nothing was open. Uploads no
    /// longer wait on a session, so nothing drains that list on its own any
    /// more — and the `pendingAttachments` accessor stops reading it the
    /// moment a real session is focused. Left alone, a tile picked before
    /// opening a conversation would vanish from the composer (unremovable,
    /// its blob stranded on the server) and then silently reappear on
    /// whichever session happened to be started next. Adopting it here keeps
    /// it visible and removable in the chat the user is actually looking at.
    private func adoptDrafts(into id: String) {
        guard !draftPendingAttachments.isEmpty else { return }
        sessionsState[id]?.pendingAttachments.append(contentsOf: draftPendingAttachments)
        draftPendingAttachments = []
    }

    /// Send a text message + any completed attachments.
    ///
    /// With a session already focused this is a plain `sendMessage`. With
    /// none, the send IS the open: `startChat` carries the visitor's first
    /// message, so there is no window where a session exists but has said
    /// nothing (the server gates the flow on visitor content and reaps a
    /// silent session — see `StartChatOptions`).
    ///
    /// Does not mutate `messages` directly — the SDK fires
    /// `messageAdded(provisional)` and `messageUpdated(delivered/failed)`
    /// for every send, so `handleEvent` is the single source of UI
    /// updates.
    /// Send a message on the focused session, starting one if there is none.
    ///
    /// - Parameters:
    ///   - value: the picked option's `value` when answering a prompt.
    ///     connect matches a button reply on `value`, not on the caption.
    ///   - galleryLabel: the picked card's title, for a gallery pick only.
    ///     connect matches a gallery reply on the PAIR `(galleryLabel, value)`,
    ///     because two cards may carry the same option value.
    func sendMessage(text: String, value: String? = nil, galleryLabel: String? = nil) async {
        guard sdk?.hasAuthoritativeConfig == true else {
            error = "Endpoint configuration is still refreshing."
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Read tiles through the accessor: with no session focused they are
        // still on the draft list, and an attachment-only first message is
        // valid.
        let completed = pendingAttachments
            .compactMap { $0.status == .completed ? $0.attachment : nil }
        guard !trimmed.isEmpty || !completed.isEmpty else { return }
        let payload = SendMessagePayload(
            text: trimmed.isEmpty ? nil : trimmed,
            attachments: completed,
            value: value,
            galleryLabel: galleryLabel
        )
        do {
            let id: String
            if let existing = currentSessionId {
                guard let state = sessionsState[existing] else { return }
                guard state.connectionState != .ended else {
                    self.error = "This conversation has ended and is read-only."
                    return
                }
                if state.connectionState == .dropped {
                    id = try await openAndSend(payload: payload, resuming: existing)
                } else {
                    guard state.accessGranted && state.connectionState == .connected else {
                        self.error = "Conversation is reconnecting. Try again when it is ready."
                        return
                    }
                    guard let client = destinationClient else { return }
                    id = existing
                    try await client.sendMessage(id: existing, payload: payload)
                }
            } else {
                id = try await openAndSend(payload: payload, resuming: nil)
            }

            // Completed attachments are now owned by the sent message;
            // any rows still in `.uploading` / `.error` are left alone
            // (the user picked them too late or they failed — they keep
            // their tile).
            sessionsState[id]?.pendingAttachments.removeAll { $0.status == .completed }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Answer an interactive prompt by tapping one of its options.
    ///
    /// Routed through `sendMessage` on purpose: a tap and a typed message
    /// share the optimistic buffer, the lazy session start and the delivery
    /// bookkeeping, and a second copy of that machinery would be a second
    /// place to get it wrong.
    ///
    /// `label` becomes the message `text` (what lands in the transcript, and
    /// connect's fallback match key); `value` is the real match key.
    func sendButtonReply(
        promptId: String,
        cardIndex: Int?,
        label: String,
        value: String,
        galleryLabel: String?
    ) async {
        // A prompt can only exist on a session that is already live, so the
        // focused id is the right key.
        if let id = currentSessionId {
            var state = sessionsState[id] ?? SessionUIState()
            state.promptSelections[promptId] = PromptSelection(
                cardIndex: cardIndex,
                buttonLabel: label
            )
            sessionsState[id] = state
        }
        await sendMessage(text: label, value: value, galleryLabel: galleryLabel)
    }

    /// Which option is highlighted on `promptId`, if any.
    ///
    /// Two mechanisms, because neither covers the other's case. The in-memory
    /// record is exact but empty after a relaunch; the label match works on a
    /// restored transcript but can only compare captions — so on a prompt with
    /// duplicate labels across cards it may highlight the wrong card. connect
    /// persists nothing that could disambiguate it, so that over-match is
    /// accepted rather than solved.
    func selection(for promptId: String, in sessionId: String?) -> PromptSelection? {
        guard let sessionId, let state = sessionsState[sessionId] else { return nil }
        if let recorded = state.promptSelections[promptId] { return recorded }

        // Restored history: the visitor's reply is the row after the prompt,
        // and its text is the label they tapped.
        guard let promptIndex = state.messages.firstIndex(where: { $0.id == promptId }) else {
            return nil
        }
        let after = state.messages[state.messages.index(after: promptIndex)...]
        guard let reply = after.first(where: { $0.role == .external }),
              let text = reply.text, !text.isEmpty
        else { return nil }
        return PromptSelection(cardIndex: nil, buttonLabel: text)
    }

    /// Whether `message`'s options are still answerable.
    ///
    /// Deliberately NOT "any later message": connect puts lifecycle rows
    /// (`queued`/`joined`/`ended`) and paced flow messages on the visitor
    /// stream, so an agent joining mid-prompt would disable a prompt connect
    /// still considers open. The discriminator is a later **visitor-authored**
    /// row, which can only come from this client's own send or from a restored
    /// transcript — both are in `state.messages`.
    func promptIsLive(_ message: Message, in sessionId: String?) -> Bool {
        guard let sessionId, let state = sessionsState[sessionId] else { return false }
        if state.promptSelections[message.id] != nil { return false }
        guard let index = state.messages.firstIndex(where: { $0.id == message.id }) else {
            // Not in this session's transcript — treat as inert rather than
            // offering a tap we cannot attribute.
            return false
        }
        let after = state.messages[state.messages.index(after: index)...]
        return !after.contains { $0.role == .external }
    }

    /// Notify the peer that the user is typing on the focused session.
    /// Cheap to call from `onChange`; the SDK debounces wire traffic.
    func notifyTyping() {
        guard sdk?.hasAuthoritativeConfig == true,
              let client = sdk?.client, let id = currentSessionId else { return }
        try? client.notifyTyping(id: id)
    }

    /// Force outbound typing off — input went empty. The SDK also fires
    /// this implicitly on send and on endSession.
    func stopTyping() {
        guard let client = sdk?.client, let id = currentSessionId else { return }
        try? client.stopTyping(id: id)
    }

    /// End the focused SDK chat session without deleting its transcript or
    /// draft. The terminal conversation remains selected and read-only.
    func endCurrentSession() {
        guard let id = currentSessionId else { return }
        if let client = sdk?.client {
            try? client.endSession(id)
        }
        sessionsState[id]?.connectionState = .ended
        sessionsState[id]?.accessGranted = false
        sessionsState[id]?.isTyping = false
        sessionsState[id]?.typingState = .init()
    }

    // MARK: - Attachments

    /// Queue a file upload onto the focused session (or the draft list
    /// when no session is open yet). The tile appears immediately at
    /// `progress = 0`; live progress updates land via `onProgress`.
    /// On success the row flips to `.completed` and carries the
    /// server-issued ``Attachment``; on failure to `.error` with a
    /// human-friendly message keyed off ``OrigonError`` codes.
    func uploadFile(data: Data, fileName: String, contentType: String, previewImage: UIImage?) {
        guard sdk?.hasAuthoritativeConfig == true else {
            error = "Endpoint configuration is still refreshing."
            return
        }
        guard attachmentAllowed(contentType: contentType) else {
            error = "This file type is disabled for this endpoint."
            return
        }
        let localId = UUID().uuidString
        let pending = PendingAttachment(
            id: localId,
            fileName: fileName,
            contentType: contentType,
            previewImage: previewImage,
            status: .uploading,
            progress: 0,
            attachment: nil,
            errorText: nil
        )
        appendPending(pending)
        Task { await runUpload(localId: localId, data: data, fileName: fileName) }
    }

    func removePendingAttachment(id: String) {
        // Snapshot the row before we mutate so we can fire the right
        // server-side cleanup. We search both the draft list and every
        // session's pending list — the row may have started life in
        // the draft and migrated into a session.
        var removed: PendingAttachment?
        if let i = draftPendingAttachments.firstIndex(where: { $0.id == id }) {
            removed = draftPendingAttachments[i]
            draftPendingAttachments.remove(at: i)
        } else {
            for (sid, state) in sessionsState {
                if let i = state.pendingAttachments.firstIndex(where: { $0.id == id }) {
                    var s = state
                    removed = s.pendingAttachments.remove(at: i)
                    sessionsState[sid] = s
                    break
                }
            }
        }
        guard let removed, let client = sdk?.client else { return }

        switch removed.status {
        case .uploading:
            // The SDK's deleteAttachment is dual-purpose: it matches
            // our local id against its in-flight upload table and
            // tears down the QUIC stream with a RESET. The upload's
            // awaiter throws `.cancelled`, which `runUpload` swallows.
            // Fires regardless of which list hosted the row — the write
            // lane is widget-scoped, and a draft-list upload is now the
            // common case since uploads no longer wait on a session.
            Task.detached {
                try? await client.deleteAttachment(attachmentId: id)
            }

        case .completed:
            // Server already has the blob; clean it up with its
            // server-issued id.
            guard let serverId = removed.attachment?.id else { return }
            Task.detached {
                try? await client.deleteAttachment(attachmentId: serverId)
            }

        case .error:
            // Nothing committed to the server — local remove is enough.
            return
        }
    }

    // MARK: - Teardown

    /// End every active SDK chat session and clear UI state. Called on
    /// logout via `SDKManager.teardown`.
    func destroy() {
        clientWillChange()
        refetchTasks.values.forEach { $0.cancel() }
        refetchTasks = [:]
        refetchEpoch = [:]
        if let client = sdk?.client {
            for id in sessionsState.keys {
                try? client.endSession(id)
            }
        }
        sessionsState = [:]
        currentSessionId = nil
        draftPendingAttachments = []
        sessionStartTask = nil
        error = nil
    }

    // MARK: - Event handling

    private func handleEvent(_ event: ClientEvent) {
        guard acceptingEvents else { return }
        let sid = event.sessionId

        // `sessionUpdated` may arrive for an id we don't hold state for
        // yet (rare server-side remap path) — handle it before the guard
        // so we don't drop it.
        if case let .sessionUpdated(_, newSessionId) = event,
           let state = sessionsState[sid]
        {
            sessionsState[newSessionId] = state
            sessionsState[sid] = nil
            if currentSessionId == sid { currentSessionId = newSessionId }
            return
        }

        // Filter everything else by sessions we own. Voice events for
        // `CallService` get dropped here naturally — their session ids
        // never enter `sessionsState`.
        guard sessionsState[sid] != nil else { return }

        switch event {
        case .messageAdded(_, let msg):
            var state = sessionsState[sid] ?? SessionUIState()
            state.messages.append(msg)
            state.liveMessageKeys.insert(Self.messageKey(msg))
            sessionsState[sid] = state

        case .messageUpdated(_, let key, let msg):
            updateMessage(in: sid, key: key, message: msg)

        case .typing(_, let state):
            sessionsState[sid]?.typingState = state
            sessionsState[sid]?.isTyping = !state.participants.isEmpty

        case .reconnecting:
            guard sessionsState[sid]?.connectionState != .ended else { return }
            sessionsState[sid]?.connectionState = .reconnecting
            sessionsState[sid]?.accessGranted = false

        case .reconnected:
            guard sessionsState[sid]?.connectionState != .ended else { return }
            sessionsState[sid]?.connectionState = .connected
            sessionsState[sid]?.accessGranted = true
            refetchHistory(for: sid)

        case .disconnected(_, let reason):
            sessionsState[sid]?.isTyping = false
            sessionsState[sid]?.typingState = .init()
            sessionsState[sid]?.accessGranted = false
            if reason == .localClose || reason == .sessionEnded {
                sessionsState[sid]?.connectionState = .ended
            } else if sessionsState[sid]?.connectionState != .ended {
                sessionsState[sid]?.connectionState = .dropped
                refetchHistory(for: sid)
            }

        case .chatSessionEnded:
            sessionsState[sid]?.isTyping = false
            sessionsState[sid]?.typingState = .init()
            sessionsState[sid]?.accessGranted = false
            sessionsState[sid]?.connectionState = .ended

        case .connected:
            guard sessionsState[sid]?.connectionState != .ended else { return }
            sessionsState[sid]?.connectionState = .connected
            sessionsState[sid]?.accessGranted = true

        case .sessionUpdated,
             .controlUpdated, .peerAttached, .peerDetached, .callError,
             .audioRouteChanged:
            break
        }
    }

    /// App lifecycle hook: fill a possible event gap without performing
    /// passive active-chat restoration or changing destination ownership.
    func refetchFocusedSession() {
        guard let id = currentSessionId else { return }
        refetchHistory(for: id)
    }

    private func refetchHistory(for id: String) {
        guard sessionsState[id] != nil, let client = destinationClient else { return }
        let epoch = clientEpoch
        let token = (refetchEpoch[id] ?? 0) &+ 1
        refetchEpoch[id] = token
        refetchTasks[id]?.cancel()
        refetchTasks[id] = Task { [weak self] in
            do {
                for try await update in try client.sessionUpdates(id: id, policy: .networkOnly) {
                    guard let self, !Task.isCancelled, self.clientEpoch == epoch,
                          self.refetchEpoch[id] == token, self.sessionsState[id] != nil
                    else { return }
                    if case .snapshot(let snapshot) = update, snapshot.authoritative {
                        var state = self.sessionsState[id] ?? SessionUIState()
                        state = Self.reconciling(snapshot.session.history, into: state)
                        state.loadState = snapshot.session.history.isEmpty ? .freshEmpty : .network
                        self.sessionsState[id] = state
                    }
                }
            } catch {
                // Gap fills are best effort. Keep the transcript and lifecycle
                // state; the next reconnect/refocus retries.
            }
        }
    }

    /// Target-owned deterministic tests inject wrapper events here without
    /// weakening the production SDK surface.
    func receiveForTesting(_ event: ClientEvent) { handleEvent(event) }

    func installStateForTesting(id: String, state: SessionUIState, focused: Bool = true) {
        sessionsState[id] = state
        if focused { currentSessionId = id }
    }

    private func updateMessage(in sid: String, key: String, message: Message) {
        guard var state = sessionsState[sid] else { return }
        state = Self.applyingMessageUpdate(key: key, message: message, to: state)
        sessionsState[sid] = state
    }

    static func applyingMessageUpdate(
        key: String,
        message: Message,
        to state: SessionUIState
    ) -> SessionUIState {
        var state = state
        if let idx = state.messages.firstIndex(where: { messageKey($0) == key }) {
            let prior = state.messages[idx]
            state.messages[idx] = Self.overlayingLocalHints(from: prior, onto: message)
            state.liveMessageKeys.remove(messageKey(prior))
            state.liveMessageKeys.insert(messageKey(state.messages[idx]))
        } else {
            // Defensive: an update can't find a prior add (e.g. race or
            // duplicate). Append so the row still appears.
            state.messages.append(message)
            state.liveMessageKeys.insert(messageKey(message))
        }
        return state
    }

    // Outbound rows show up first as `messageAdded` with `localId` set
    // and `id == ""`; the server `id` lands on `messageUpdated`. Prefer
    // `localId` so the same row tracks across the sending → delivered
    // transition. Inbound rows have no `localId`, so `id` wins.
    private static func messageKey(_ m: Message) -> String {
        if let local = m.localId, !local.isEmpty { return local }
        return m.id
    }

    static func reconciling(_ history: [Message], into state: SessionUIState) -> SessionUIState {
        var updated = state
        let localByServerId = Dictionary(
            state.messages.lazy.filter { !$0.id.isEmpty }.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let serverIds = Set(history.lazy.map(\.id).filter { !$0.isEmpty })
        var consumedLiveKeys = Set<String>()
        let authoritative = history.map { remote -> Message in
            guard let local = localByServerId[remote.id] else { return remote }
            consumedLiveKeys.insert(local.localId?.isEmpty == false ? local.localId! : local.id)
            return overlayingLocalHints(from: local, onto: remote)
        }
        let tail = state.messages.filter { local in
            if !local.id.isEmpty && serverIds.contains(local.id) { return false }
            let key = local.localId?.isEmpty == false ? local.localId! : local.id
            return local.status == .sending || local.status == .failed || state.liveMessageKeys.contains(key)
        }
        updated.messages = authoritative + tail
        updated.liveMessageKeys.subtract(consumedLiveKeys)
        return updated
    }

    static func overlayingLocalHints(from local: Message, onto remote: Message) -> Message {
        let localAttachments = Dictionary(
            local.attachments.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let attachments = remote.attachments.map { item -> Attachment in
            guard let preview = localAttachments[item.id]?.localUrl else { return item }
            return Attachment(
                id: item.id,
                name: item.name,
                contentType: item.contentType,
                url: item.url,
                localUrl: preview
            )
        }
        return Message(
            role: remote.role,
            id: remote.id,
            localId: remote.localId?.isEmpty == false ? remote.localId : local.localId,
            text: remote.text,
            html: remote.html,
            timestamp: remote.timestamp,
            userId: remote.userId,
            userName: remote.userName,
            action: remote.action,
            attachments: attachments,
            buttons: remote.buttons,
            gallery: remote.gallery,
            errorText: remote.errorText,
            status: remote.status,
            state: remote.state
        )
    }

    // MARK: - Upload internals

    /// Open a chat session by SENDING — `startChat` carries `payload` as the
    /// visitor's first message and returns the new session id.
    ///
    /// This is the only path that opens a chat. Uploads are widget-scoped
    /// and never open one, and the sidebar's `openSession` is view-only.
    ///
    /// A second send arriving while a start is in flight joins that start
    /// and then sends normally — it must NOT start its own session, and it
    /// can't join by payload either, since the first message is already
    /// spoken for.
    private func openAndSend(
        payload: SendMessagePayload,
        resuming resumeId: String?
    ) async throws -> String {
        guard sdk?.hasAuthoritativeConfig == true else {
            throw OrigonError(kind: .other, message: "Endpoint configuration is still refreshing")
        }
        guard let client = destinationClient else { throw OrigonError.notInitialized }

        if let inFlight = sessionStartTask {
            let id = try await inFlight.value
            try await client.sendMessage(id: id, payload: payload)
            return id
        }

        let task = Task<String, Error> { [weak self] in
            do {
                // `startChat` returns the session id BEFORE the message goes
                // out, and a first message that fails to DELIVER does not
                // throw — it arrives as `messageUpdated(.failed)` so the user
                // can retry. Only a terminal refusal throws.
                let response = try await client.startChat(StartChatOptions(
                    firstMessage: payload,
                    sessionId: resumeId
                ))
                await MainActor.run {
                    guard let self else { return }
                    var state = resumeId.flatMap { self.sessionsState[$0] }
                        ?? self.sessionsState[response.sessionId] ?? SessionUIState()
                    // Merge any draft tiles that were queued while the
                    // start was in flight. Sessions opened concurrently
                    // via `openSession` would already be in
                    // `sessionsState`; preserve their existing pending
                    // list and append the draft entries onto it.
                    state.pendingAttachments.append(contentsOf: self.draftPendingAttachments)
                    state.connectionState = .connected
                    state.accessGranted = true
                    if let resumeId, resumeId != response.sessionId {
                        self.sessionsState[resumeId] = nil
                    }
                    self.sessionsState[response.sessionId] = state
                    self.draftPendingAttachments = []
                    // Only steal focus if the user didn't navigate to a
                    // different session while the start was in flight.
                    if self.currentSessionId == nil || self.currentSessionId == resumeId {
                        self.currentSessionId = response.sessionId
                    }
                    self.sessionStartTask = nil
                }
                try? await self?.sdk?.refreshSessions()
                if resumeId != nil { await self?.refetchAfterResume(id: response.sessionId) }
                return response.sessionId
            } catch {
                // Clear the cached task on failure so the next caller
                // retries instead of inheriting our error.
                await MainActor.run { self?.sessionStartTask = nil }
                throw error
            }
        }
        sessionStartTask = task
        return try await task.value
    }

    private func refetchAfterResume(id: String) async {
        refetchHistory(for: id)
    }

    private func runUpload(localId: String, data: Data, fileName: String) async {
        guard let client = sdk?.client else {
            updatePending(localId: localId) {
                $0.status = .error
                $0.errorText = "Client not ready"
            }
            return
        }
        // `uploadFile` appends the row and then ENQUEUES this task, so an ×
        // tap can run in between. If the row is gone by the time we get
        // here, abort before any wire work starts — the cancel it fired
        // landed before the SDK registered its in-flight entry, so it would
        // have degraded to a DELETE of an id the server never saw, leaving
        // an orphan blob behind this upload.
        guard pendingExists(localId: localId) else { return }

        do {
            let attachment = try await client.uploadAttachment(
                uploadId: localId,
                data: data,
                fileName: fileName,
                onProgress: { [weak self] progress in
                    self?.updatePending(localId: localId) { row in
                        if let pct = progress.percent {
                            row.progress = Double(pct)
                        } else if let total = progress.totalBytes, total > 0 {
                            row.progress = Double(progress.bytesUploaded) / Double(total) * 100
                        }
                    }
                }
            )
            updatePending(localId: localId) {
                $0.status = .completed
                $0.progress = 100
                $0.attachment = attachment
            }
        } catch let err as OrigonError where err.kind == .cancelled {
            // The row was removed by `removePendingAttachment` and the
            // cancel signal raced through the SDK; nothing left to do.
            // (`updatePending` would silently no-op anyway since the
            // row is gone, but the explicit branch documents intent.)
            return
        } catch {
            // Surface whatever the SDK gave us. `OrigonError.message`
            // is always populated by the Rust side per the contract;
            // foreign errors fall back to `localizedDescription`.
            let message: String
            if let err = error as? OrigonError {
                message = err.message ?? err.code ?? "Upload failed"
            } else {
                message = error.localizedDescription
            }
            updatePending(localId: localId) {
                $0.status = .error
                $0.errorText = message
            }
            // Mirror onto the published `error` so the view can toast
            // it. The tile's inline error overlay is the persistent
            // indicator; the toast is the at-the-moment cue.
            self.error = message
        }
    }

    /// True when a pending row with the given local id is still hosted
    /// somewhere — draft list or any session. Used by `runUpload` as a
    /// pre-upload existence check; see the call site for the no-session
    /// cancel race it plugs.
    private func pendingExists(localId: String) -> Bool {
        if draftPendingAttachments.contains(where: { $0.id == localId }) {
            return true
        }
        for state in sessionsState.values {
            if state.pendingAttachments.contains(where: { $0.id == localId }) {
                return true
            }
        }
        return false
    }

    /// Append a pending row onto whichever list is appropriate right
    /// now. When no session is open we push into the draft list;
    /// `ensureChatSession` migrates it into the session's pending list
    /// when the start resolves.
    private func appendPending(_ row: PendingAttachment) {
        if let id = currentSessionId {
            var state = sessionsState[id] ?? SessionUIState()
            state.pendingAttachments.append(row)
            sessionsState[id] = state
        } else {
            draftPendingAttachments.append(row)
        }
    }

    /// Locate a pending row by its local id and apply `mutate`. Searches
    /// the draft list first, then every session's pending list — the
    /// row may have moved across the draft → session boundary mid-
    /// upload, and the caller (a progress callback) has no way of
    /// knowing that. Silently drops the update when the row is gone,
    /// e.g. the user removed the tile after it completed.
    private func updatePending(
        localId: String,
        _ mutate: (inout PendingAttachment) -> Void
    ) {
        if let i = draftPendingAttachments.firstIndex(where: { $0.id == localId }) {
            mutate(&draftPendingAttachments[i])
            return
        }
        for (sid, state) in sessionsState {
            if let i = state.pendingAttachments.firstIndex(where: { $0.id == localId }) {
                var s = state
                mutate(&s.pendingAttachments[i])
                sessionsState[sid] = s
                return
            }
        }
    }

}
