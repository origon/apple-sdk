import Foundation
import Combine
import OrigonSDK

enum ExampleAttachmentCategory: CaseIterable {
    case images, documents, videos, audio

    init(contentType: String) {
        if contentType.hasPrefix("image/") { self = .images }
        else if contentType.hasPrefix("video/") { self = .videos }
        else if contentType.hasPrefix("audio/") { self = .audio }
        else { self = .documents }
    }
}

struct ExampleAttachmentPolicy: Equatable {
    var images = false
    var documents = false
    var videos = false
    var audio = false

    init() {}

    init(_ policy: AttachmentPolicy) {
        images = policy.images.enabled
        documents = policy.documents.enabled
        videos = policy.videos.enabled
        audio = policy.audio.enabled
    }

    func allows(_ category: ExampleAttachmentCategory) -> Bool {
        switch category {
        case .images: images
        case .documents: documents
        case .videos: videos
        case .audio: audio
        }
    }
}

/// Immutable app-owned copy of the SDK's cached endpoint configuration.
/// A copy is installed only with its initialized client, so an endpoint switch
/// cannot leak the previous tenant's greeting or channel/picker policy.
struct ExampleServerConfig: Equatable {
    let startMessage: String
    let multipleChannels: Bool
    let chatEnabled: Bool
    let callEnabled: Bool
    let attachments: ExampleAttachmentPolicy

    init(
        startMessage: String,
        multipleChannels: Bool,
        chatEnabled: Bool,
        callEnabled: Bool,
        attachments: ExampleAttachmentPolicy = .init()
    ) {
        self.startMessage = startMessage
        self.multipleChannels = multipleChannels
        self.chatEnabled = chatEnabled
        self.callEnabled = callEnabled
        self.attachments = attachments
    }

    init(_ config: ServerConfig) {
        self.init(
            startMessage: config.startMessage,
            multipleChannels: config.multipleChannels,
            chatEnabled: config.isChatEnabled,
            callEnabled: config.isCallEnabled,
            attachments: ExampleAttachmentPolicy(config.attachmentPolicy)
        )
    }
}

struct ExampleEndpointPolicy: Equatable {
    let greeting: String
    let showsComposer: Bool
    let showsVoiceOnlyAction: Bool
    let showsComposerVoiceAction: Bool
    let promptSendEnabled: Bool
    let attachments: ExampleAttachmentPolicy

    init(config: ExampleServerConfig?, authoritative: Bool = true) {
        let config = config ?? ExampleServerConfig(
            startMessage: "", multipleChannels: false,
            chatEnabled: false, callEnabled: false
        )
        greeting = config.startMessage.trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty ?? "How can I help you?"
        showsComposer = authoritative && config.chatEnabled
        showsVoiceOnlyAction = authoritative && config.callEnabled && !config.chatEnabled
        showsComposerVoiceAction = authoritative && config.chatEnabled && config.callEnabled && config.multipleChannels
        promptSendEnabled = authoritative && config.chatEnabled
        attachments = authoritative && config.chatEnabled ? config.attachments : .init()
    }
}

struct ExampleConfigReplacement {
    private(set) var epoch: UInt64 = 0
    private(set) var value: ExampleServerConfig?

    mutating func begin() -> UInt64 {
        epoch &+= 1
        value = nil
        return epoch
    }

    mutating func install(_ config: ExampleServerConfig, for expectedEpoch: UInt64) -> Bool {
        guard epoch == expectedEpoch else { return false }
        value = config
        return true
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

/// Owns the `OrigonClient` for the lifetime of an authenticated session and
/// serves as the single entry point the UI uses for both call and chat
/// functionality.
///
/// The app has exactly one of these (injected at the root); every other
/// component that needs the SDK consumes it from here. Responsibilities:
///
/// - Hold the `OrigonClient` handle (one per logged-in session).
/// - Own the `CallService` and `ChatService` instances and expose them so
///   the UI can reach `sdk.call` / `sdk.chat`.
/// - Host the shared session list (used by both call and chat) and the
///   cache-first directory stream.
/// - Drain the SDK's event channel on a 50 ms timer and broadcast every
///   `ClientEvent` to subscribers via `events`. Consumers (e.g.
///   `CallService`) filter by `sessionId`.
/// - Tear down cleanly on logout — destroys the client and stops the
///   poll loop so the FFI handle is released.
@MainActor
final class SDKManager: ObservableObject {

    enum ConfigAuthorityState {
        case unavailable
        case cached
        case authoritative
        case transientFailure(OrigonError)
        case terminal(OrigonError)
    }

    @Published private(set) var isReady = false
    @Published private(set) var sessions: [SessionSummary] = []
    @Published private(set) var isLoadingSessions = false
    @Published private(set) var serverConfig: ExampleServerConfig?
    @Published private(set) var configAuthority: ConfigAuthorityState = .unavailable
    private var configReplacement = ExampleConfigReplacement()
    private var configUpdatesTask: Task<Void, Never>?
    private let checkpointStore = try? ExampleChatCheckpointStore.live()
    private(set) var checkpointEndpoint: String?

    var hasAuthoritativeConfig: Bool {
        if case .authoritative = configAuthority { return true }
        return false
    }

    var endpointPolicy: ExampleEndpointPolicy {
        ExampleEndpointPolicy(config: serverConfig, authoritative: hasAuthoritativeConfig)
    }

    private(set) var client: OrigonClient?

    /// Narrow, fakeable surface for chat-selection policy. Call and media
    /// behavior continues to use the concrete client.
    var chatClient: (any ChatSessionClient)? { client }

    let call: CallService
    let chat: ChatService

    /// Broadcast every event drained from `client.pollEvent()`. Use a
    /// `PassthroughSubject` so subscribers see events without retaining
    /// any per-event state on this side.
    private let eventSubject = PassthroughSubject<ClientEvent, Never>()
    var events: AnyPublisher<ClientEvent, Never> { eventSubject.eraseToAnyPublisher() }

    private var pollTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    init() {
        self.call = CallService()
        self.chat = ChatService()
        // Bind child services to this manager so they can read `client` and
        // subscribe to `events`. Done after self-init so we can pass `self`.
        self.call.bind(to: self)
        self.chat.bind(to: self)

        // Re-publish child @Published changes through this manager so views
        // observing only SDKManager re-render when `chat.messages` or
        // `call.phase` change. SwiftUI does not chain ObservableObjects
        // automatically.
        self.call.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        self.chat.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    // MARK: - Lifecycle

    /// Connect to the Origon backend and start the event poll loop.
    func initialize(
        endpoint: String,
        userId: String? = nil,
        token: String? = nil
    ) async throws {
        chat.clientWillChange()
        let configEpoch = configReplacement.begin()
        serverConfig = nil
        configAuthority = .unavailable
        // `userId` is optional; when nil the SDK resolves a device
        // identifier internally to use as the fallback.
        let config = ClientConfig(
            endpoint: endpoint,
            token: token,
            userId: userId
        )

        // OrigonClient(config:) blocks on the FFI runtime — do it off the
        // main thread so the UI stays responsive during the /config round
        // trip.
        let newClient = try await Task.detached {
            try OrigonClient(config: config)
        }.value

        let nextConfig = ExampleServerConfig(newClient.serverConfig)
        guard configReplacement.install(nextConfig, for: configEpoch) else {
            newClient.close()
            throw CancellationError()
        }
        self.client = newClient
        self.checkpointEndpoint = endpoint
        self.serverConfig = configReplacement.value
        chat.clientDidChange()
        self.isReady = true
        startPolling()
        observeConfigUpdates(from: newClient, epoch: configEpoch)
    }

    /// Destroy the client, reset child services, and stop polling.
    /// Idempotent — safe to call on logout regardless of whether
    /// `initialize` ran.
    func teardown() {
        configUpdatesTask?.cancel()
        configUpdatesTask = nil
        stopPolling()
        chat.destroy()
        sessions = []
        client?.close()
        client = nil
        checkpointEndpoint = nil
        _ = configReplacement.begin()
        serverConfig = nil
        configAuthority = .unavailable
        isReady = false
    }

    func retryServerConfig() {
        guard let client else { return }
        startConfigTask(client: client, epoch: configReplacement.epoch, retry: true)
    }

    private func observeConfigUpdates(from client: OrigonClient, epoch: UInt64) {
        configAuthority = .cached
        startConfigTask(client: client, epoch: epoch, retry: false)
    }

    private func startConfigTask(client: OrigonClient, epoch: UInt64, retry: Bool) {
        configUpdatesTask?.cancel()
        configUpdatesTask = Task { [weak self, weak client] in
            guard let client else { return }
            do {
                let updates = retry
                    ? try client.retryServerConfig()
                    : try client.serverConfigUpdates()
                for try await update in updates {
                    guard !Task.isCancelled, let self,
                          self.configReplacement.epoch == epoch,
                          self.client === client else { return }
                    switch update {
                    case .snapshot(let snapshot):
                        let next = ExampleServerConfig(snapshot.config)
                        guard self.configReplacement.install(next, for: epoch) else { return }
                        self.serverConfig = next
                        self.configAuthority = snapshot.authoritative ? .authoritative : .cached
                    case .refreshFailed(let error, _):
                        if [400, 401, 403, 404].contains(error.statusCode) {
                            _ = self.configReplacement.begin()
                            self.serverConfig = nil
                            self.sessions = []
                            self.chat.destroy()
                            self.configAuthority = .terminal(error)
                        } else {
                            self.configAuthority = .transientFailure(error)
                        }
                    }
                }
            } catch let error as OrigonError {
                guard let self, self.configReplacement.epoch == epoch,
                      self.client === client else { return }
                if [400, 401, 403, 404].contains(error.statusCode) {
                    _ = self.configReplacement.begin()
                    self.serverConfig = nil
                    self.sessions = []
                    self.chat.destroy()
                    self.configAuthority = .terminal(error)
                } else {
                    self.configAuthority = .transientFailure(error)
                }
            } catch {
                // Cancellation and wrapper decode failures cannot promote
                // cached endpoint policy to authoritative state.
            }
        }
    }

    func checkpoint(sessionId: String) async -> ExampleChatCheckpoint? {
        guard let checkpointStore, let endpoint = checkpointEndpoint else { return nil }
        return try? await checkpointStore.read(endpoint: endpoint, sessionId: sessionId)
    }

    func markCheckpointSeen(
        sessionId: String,
        latestRowVisible: Bool,
        sceneForeground: Bool
    ) async {
        guard let checkpointStore, let endpoint = checkpointEndpoint else { return }
        try? await checkpointStore.markSeen(
            endpoint: endpoint,
            sessionId: sessionId,
            messageId: exampleNewestEligibleMessageId(chat.messages),
            authoritative: chat.focusedHistoryIsAuthoritative,
            sceneForeground: sceneForeground,
            detailVisible: chat.currentSessionId == sessionId,
            latestRowVisible: latestRowVisible
        )
    }

    // MARK: - Sessions (shared between call and chat)

    /// Refresh the cached session list from the SDK. Used by the sidebar
    /// (chat history) and any future call-history surface.
    func refreshSessions() async throws {
        guard let client else { return }
        isLoadingSessions = true
        do {
            for try await update in try client.sessionDirectoryUpdates() {
                switch update {
                case .snapshot(let snapshot):
                    sessions = snapshot.sessions
                case .refreshFailed(let error, _):
                    throw error
                }
            }
            isLoadingSessions = false
        } catch {
            isLoadingSessions = false
            throw error
        }
    }

    // MARK: - Event polling

    private func startPolling() {
        stopPolling()
        // 50 ms cadence matches the web client's poll loop. Drains up to
        // 50 events per tick to avoid backlog if a burst arrives between
        // ticks.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.drainEvents()
            }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func drainEvents() {
        guard let client else { return }
        for _ in 0..<50 {
            guard let event = client.pollEvent() else { break }
            eventSubject.send(event)
        }
    }
}
