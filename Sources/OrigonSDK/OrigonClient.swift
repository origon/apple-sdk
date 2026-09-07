import Foundation
import COrigonSDK

final class NativeHandleGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var handle: OpaquePointer?
    private var activeCalls = 0
    private var isClosing = false

    init(_ handle: OpaquePointer) {
        self.handle = handle
    }

    func withHandle<R>(_ body: (OpaquePointer) throws -> R) throws -> R {
        condition.lock()
        guard !isClosing, let handle else {
            condition.unlock()
            throw OrigonError.notInitialized
        }
        activeCalls += 1
        condition.unlock()
        defer {
            condition.lock()
            activeCalls -= 1
            if activeCalls == 0 { condition.broadcast() }
            condition.unlock()
        }
        return try body(handle)
    }

    func withHandleOr<R>(_ fallback: R, _ body: (OpaquePointer) -> R) -> R {
        (try? withHandle(body)) ?? fallback
    }

    func close(_ destroy: (OpaquePointer) -> Void) {
        condition.lock()
        while isClosing { condition.wait() }
        guard let closing = handle else {
            condition.unlock()
            return
        }
        isClosing = true
        while activeCalls > 0 { condition.wait() }
        handle = nil
        condition.unlock()

        destroy(closing)

        condition.lock()
        isClosing = false
        condition.broadcast()
        condition.unlock()
    }
}

private final class ConfigAuthorityObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    func install(_ task: Task<Void, Never>) {
        lock.lock()
        self.task?.cancel()
        self.task = task
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        let task = self.task
        self.task = nil
        lock.unlock()
        task?.cancel()
    }
}

enum AudioLevelNativeStep: Sendable {
    case update(SessionAudioLevels)
    case end
    case cancelled
}

protocol AudioLevelNativeSource: AnyObject, Sendable {
    func next() -> AudioLevelNativeStep
    func cancel()
    func free()
}

private final class CNativeAudioLevelSource: AudioLevelNativeSource, @unchecked Sendable {
    private let lock = NSLock()
    private var pointer: OpaquePointer?

    init(_ pointer: OpaquePointer) {
        self.pointer = pointer
    }

    func next() -> AudioLevelNativeStep {
        lock.lock()
        let current = pointer
        lock.unlock()
        guard let current else { return .cancelled }

        var raw = COrigonSDK.SessionAudioLevels()
        let status = session_audio_level_subscription_next(current, &raw)
        defer { session_audio_levels_clear(&raw) }
        switch status {
        case SESSION_AUDIO_LEVELS_UPDATE:
            guard let sessionId = raw.session_id else { return .end }
            let endpoints: [EndpointAudioLevel]
            if let items = raw.endpoints {
                endpoints = (0..<Int(raw.endpoint_count)).compactMap { index in
                    guard let endpointId = items[index].endpoint_id else { return nil }
                    return EndpointAudioLevel(
                        endpointId: String(cString: endpointId),
                        inbound: items[index].inbound
                    )
                }
            } else {
                endpoints = []
            }
            return .update(SessionAudioLevels(
                sessionId: String(cString: sessionId),
                outbound: raw.outbound,
                inbound: raw.inbound,
                endpoints: endpoints
            ))
        case SESSION_AUDIO_LEVELS_CANCELLED:
            return .cancelled
        case SESSION_AUDIO_LEVELS_END:
            return .end
        default:
            // Invalid bridge arguments are wrapper bugs, not a post-start
            // observer error surface. Fail closed as a terminal end.
            return .end
        }
    }

    func cancel() {
        lock.lock()
        if let current = pointer {
            session_audio_level_subscription_cancel(current)
        }
        lock.unlock()
    }

    func free() {
        lock.lock()
        let current = pointer
        pointer = nil
        lock.unlock()
        if let current {
            session_audio_level_subscription_free(current)
        }
    }
}

final class AudioLevelObservationState: @unchecked Sendable {
    let source: any AudioLevelNativeSource
    private let lock = NSLock()
    private var active = true

    init(source: any AudioLevelNativeSource) {
        self.source = source
    }

    func isActive() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return active
    }

    func cancel() {
        lock.lock()
        guard active else {
            lock.unlock()
            return
        }
        active = false
        source.cancel()
        lock.unlock()
    }

    func finish() {
        lock.lock()
        active = false
        lock.unlock()
    }
}

final class AudioLevelObservationRegistry: @unchecked Sendable {
    private struct Entry {
        let sessionId: String
        let state: AudioLevelObservationState
    }

    private let lock = NSLock()
    private var entries: [UInt64: Entry] = [:]
    private var nextGeneration: UInt64 = 0
    private var closed = false

    func install(
        sessionId: String,
        source: any AudioLevelNativeSource
    ) -> (AudioLevelObservationState, UInt64)? {
        lock.lock()
        guard !closed, nextGeneration < UInt64.max else {
            lock.unlock()
            return nil
        }
        nextGeneration += 1
        let generation = nextGeneration
        let state = AudioLevelObservationState(source: source)
        entries[generation] = Entry(sessionId: sessionId, state: state)
        lock.unlock()
        return (state, generation)
    }

    func accepts(
        sessionId: String,
        generation: UInt64,
        state: AudioLevelObservationState
    ) -> Bool {
        lock.lock()
        let matches = !closed
            && entries[generation]?.sessionId == sessionId
            && entries[generation]?.state === state
        lock.unlock()
        return matches && state.isActive()
    }

    func retire(
        sessionId: String,
        generation: UInt64,
        state: AudioLevelObservationState
    ) {
        lock.lock()
        if entries[generation]?.sessionId == sessionId,
           entries[generation]?.state === state {
            entries.removeValue(forKey: generation)
        }
        lock.unlock()
        state.finish()
    }

    func close() {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        let states = entries.values.map(\.state)
        entries.removeAll()
        lock.unlock()
        for state in states {
            state.cancel()
        }
    }
}

/// Idempotent ownership token for one combined audio-level callback.
/// Cancellation is signalled immediately; the off-main pump owns the native
/// handle and frees it after its blocking `next` exits.
public final class AudioLevelObservation: @unchecked Sendable {
    private let state: AudioLevelObservationState

    fileprivate init(state: AudioLevelObservationState) {
        self.state = state
    }

    public func cancel() {
        state.cancel()
    }

    deinit {
        cancel()
    }
}

/// The primary interface to the Origon platform on Apple platforms.
///
/// Backed by the `COrigonSDK` XCFramework (statically linked
/// `libsession.a`). One instance owns one native handle and one smol
/// executor; create at app start, deinit when shutting down.
///
/// All fallible methods throw ``OrigonError`` with a structured
/// `kind` / `statusCode` / `code` / `message`.
public final class OrigonClient: @unchecked Sendable {
    private let nativeGate: NativeHandleGate
    private let audioLevelObservations = AudioLevelObservationRegistry()
    private let configAuthorityObservation = ConfigAuthorityObservation()
    private let subscribeAudioLevelsNative:
        @Sendable (OpaquePointer, String) throws -> any AudioLevelNativeSource
    private let destroyNative: @Sendable (OpaquePointer) -> Void

    /// Install the global tracing subscriber. Idempotent — only the
    /// first call installs; subsequent calls are no-ops.
    ///
    /// `filter` accepts `RUST_LOG`-style directives. Pass `nil` for the
    /// SDK default.
    public static func initLogging(filter: String? = nil) {
        if let filter {
            filter.withCString { cstr in _ = session_init_logging(cstr) }
        } else {
            _ = session_init_logging(nil)
        }
    }

    public init(config: ClientConfig) throws {
        var err = SessionError()
        var newHandle: OpaquePointer?
        let attributesJson = try Self.encodeAttributes(config.attributes)
        let bundleId = Bundle.main.bundleIdentifier
        let installationId = try InstallationIdentity.loadOrCreate()
        let effectiveUserId = config.userId ?? installationId
        let cacheRoot: String?
        if config.chatCachePolicy == .enabled {
            cacheRoot = try ChatCacheStorage.prepare().path
        } else {
            cacheRoot = nil
        }
        let rc: Int32 = config.endpoint.withCString { endpointPtr in
            withOptionalCString(bundleId) { bundlePtr in
                withOptionalCString(config.token) { tokenPtr in
                    effectiveUserId.withCString { userIdPtr in
                        installationId.withCString { installationIdPtr in
                            withOptionalCString(attributesJson) { attrsPtr in
                                withOptionalCString(cacheRoot) { cachePtr in
                                    var cfg = SessionClientConfig(
                                        endpoint: endpointPtr,
                                        bundle_id: bundlePtr,
                                        token: tokenPtr,
                                        user_id: userIdPtr,
                                        installation_id: installationIdPtr,
                                        attributes_json: attrsPtr,
                                        cache_dir: cachePtr
                                    )
                                    return session_client_create(&cfg, &newHandle, &err)
                                }
                            }
                        }
                    }
                }
            }
        }
        guard rc == 0, let newHandle else {
            throw OrigonError.consume(&err)
        }
        self.nativeGate = NativeHandleGate(newHandle)
        self.subscribeAudioLevelsNative = { handle, sessionId in
            var error = SessionError()
            var subscription: OpaquePointer?
            let result = sessionId.withCString {
                session_client_subscribe_audio_levels(handle, $0, &subscription, &error)
            }
            guard result == 0, let subscription else {
                throw OrigonError.consume(&error)
            }
            return CNativeAudioLevelSource(subscription)
        }
        self.destroyNative = { session_client_destroy($0) }
        observeConfigAuthorityForPush()
    }

    init(
        testingHandle: OpaquePointer,
        subscribeAudioLevels: @escaping @Sendable
            (OpaquePointer, String) throws -> any AudioLevelNativeSource,
        destroy: @escaping @Sendable (OpaquePointer) -> Void
    ) {
        self.nativeGate = NativeHandleGate(testingHandle)
        self.subscribeAudioLevelsNative = subscribeAudioLevels
        self.destroyNative = destroy
    }

    /// Serialize a `[String: Any]?` to a JSON string. Returns `nil` when
    /// the input is `nil`. Throws `OrigonError(.other, ...)` if the
    /// dictionary contains a value `JSONSerialization` can't handle.
    private static func encodeAttributes(_ attrs: [String: Any]?) throws -> String? {
        guard let attrs else { return nil }
        do {
            let data = try JSONSerialization.data(withJSONObject: attrs, options: [])
            guard let s = String(data: data, encoding: .utf8) else {
                throw OrigonError(kind: .other, message: "attributes encode: utf8")
            }
            return s
        } catch let e as OrigonError {
            throw e
        } catch {
            throw OrigonError(
                kind: .other,
                message: "attributes encode: \(error.localizedDescription)"
            )
        }
    }

    deinit {
        // Defensive repeat after an explicit close. Registrar detach keeps
        // only a weak capture so this cannot resurrect a deinitializing client.
        close()
    }

    /// Invalidate and signal every audio observation, cancel and join every
    /// native finite loader, then destroy the client. Audio pumps join and
    /// free their caller-owned observation handles off-main.
    /// Call before `clearAllChatCaches()` during logout.
    public func close() {
        configAuthorityObservation.cancel()
        PushRegistrar.shared.detach(self)
        audioLevelObservations.close()
        nativeGate.close(destroyNative)
    }

    private func withHandle<R>(_ body: (OpaquePointer) throws -> R) throws -> R {
        try nativeGate.withHandle(body)
    }

    private func withHandleOr<R>(_ fallback: R, _ body: (OpaquePointer) -> R) -> R {
        nativeGate.withHandleOr(fallback, body)
    }

    // MARK: - Push notifications (internal)

    /// Blocking FFI call — invoked off the main thread by
    /// ``PushRegistrar``. The public, buffering entry point is the static
    /// ``OrigonClient/registerForPushNotifications(deviceToken:environment:)``.
    func registerPush(token: String, provider: String, environment: String?) throws -> String {
        var err = SessionError()
        var generationPtr: UnsafeMutablePointer<CChar>?
        let rc: Int32 = try withHandle { handle in
            token.withCString { tokenPtr in
                provider.withCString { providerPtr in
                    withOptionalCString(environment) { envPtr in
                        session_client_register_push(
                            handle, tokenPtr, providerPtr, envPtr, &generationPtr, &err
                        )
                    }
                }
            }
        }
        if rc != 0 { throw OrigonError.consume(&err) }
        guard let generationPtr else {
            throw OrigonError(kind: .other, message: "push registration returned no generation")
        }
        defer { session_string_free(generationPtr) }
        return String(cString: generationPtr)
    }

    /// Blocking FFI call — invoked off the main thread by ``PushRegistrar``.
    func unregisterPush(token: String, provider: String, environment: String?, generation: String) throws {
        var err = SessionError()
        let rc: Int32 = try withHandle { handle in
            token.withCString { tokenPtr in
                provider.withCString { providerPtr in
                    withOptionalCString(environment) { environmentPtr in
                        generation.withCString { generationPtr in
                            session_client_unregister_push(
                                handle, tokenPtr, providerPtr, environmentPtr, generationPtr, &err
                            )
                        }
                    }
                }
            }
        }
        if rc != 0 { throw OrigonError.consume(&err) }
    }

    // MARK: - Cached /config getters

    private func readServerConfig() throws -> ServerConfig {
        var error = SessionError()
        var jsonPointer: UnsafeMutablePointer<CChar>?
        let result = try withHandle {
            session_client_server_config($0, &jsonPointer, &error)
        }
        guard result == 0, let jsonPointer else {
            throw OrigonError.consume(&error)
        }
        defer { session_string_free(jsonPointer) }
        do {
            return try JSONDecoder().decode(
                ServerConfig.self,
                from: Data(String(cString: jsonPointer).utf8)
            )
        } catch {
            throw OrigonError(
                kind: .other,
                message: "server config decode: \(error.localizedDescription)"
            )
        }
    }

    /// Pre-populated first assistant message configured for the tenant.
    public var startMessage: String {
        serverConfig.startMessage
    }

    public var isChatEnabled: Bool {
        serverConfig.isChatEnabled
    }

    public var isCallEnabled: Bool {
        serverConfig.isCallEnabled
    }

    /// True when chat and voice may share one session.
    public var multipleChannels: Bool {
        serverConfig.multipleChannels
    }

    public var attachmentPolicy: AttachmentPolicy {
        serverConfig.attachmentPolicy
    }

    public var serverConfig: ServerConfig {
        (try? readServerConfig()) ?? .disabled
    }

    /// Observe the retained cache snapshot and the manager-owned network
    /// refresh. Cancelling this stream detaches only this observer.
    public func serverConfigUpdates()
        throws -> AsyncThrowingStream<ServerConfigLoadUpdate, Error>
    {
        try makeServerConfigUpdates(retry: false)
    }

    /// Coalesce or start a retry after a transient `/config` failure.
    public func retryServerConfig()
        throws -> AsyncThrowingStream<ServerConfigLoadUpdate, Error>
    {
        try makeServerConfigUpdates(retry: true)
    }

    private func makeServerConfigUpdates(
        retry: Bool
    ) throws -> AsyncThrowingStream<ServerConfigLoadUpdate, Error> {
        var error = SessionError()
        var rawLoader: OpaquePointer?
        let result = try withHandle { handle in
            if retry {
                session_client_config_retry(handle, &rawLoader, &error)
            } else {
                session_client_config_loader_start(handle, &rawLoader, &error)
            }
        }
        guard result == 0, let rawLoader else { throw OrigonError.consume(&error) }
        let loader = NativeLoader(rawLoader)
        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(2)) { continuation in
            let task = Task.detached { [weak self] in
                defer { loader.free() }
                do {
                    while !Task.isCancelled {
                        switch try loader.next() {
                        case .update(let json):
                            let snapshot = try JSONDecoder().decode(
                                ServerConfigLoadSnapshot.self,
                                from: Data(json.utf8)
                            )
                            if snapshot.authoritative, let self {
                                PushRegistrar.shared.attach(self)
                            }
                            continuation.yield(.snapshot(snapshot))
                        case .refreshFailed(let error, let cached):
                            continuation.yield(.refreshFailed(
                                error: error,
                                cachedSnapshotEmitted: cached
                            ))
                        case .end, .cancelled:
                            continuation.finish()
                            return
                        }
                    }
                    loader.cancel()
                    continuation.finish()
                } catch {
                    loader.cancel()
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                loader.cancel()
                task.cancel()
            }
        }
    }

    private func observeConfigAuthorityForPush() {
        let task = Task.detached { [weak self] in
            guard let self else { return }
            do {
                for try await update in try self.serverConfigUpdates() {
                    if case .snapshot(let snapshot) = update, snapshot.authoritative {
                        guard !Task.isCancelled else { return }
                        PushRegistrar.shared.attach(self)
                        return
                    }
                }
            } catch {
                // The public stream carries the typed failure. Push remains
                // buffered until a later authoritative generation.
            }
        }
        configAuthorityObservation.install(task)
    }

    /// Replace session-level attributes injected as `data.attributes`
    /// on subsequent `startCall` / `startChat` calls. Pass `nil` to clear.
    public func setAttributes(_ attrs: [String: Any]?) throws {
        let json = try Self.encodeAttributes(attrs)
        var err = SessionError()
        let rc: Int32 = try withHandle { handle in
            withOptionalCString(json) { ptr in
                session_client_set_attributes(handle, ptr, &err)
            }
        }
        if rc != 0 { throw OrigonError.consume(&err) }
    }

    // MARK: - Session lifecycle
    /// Start a **voice call**. Posts `/session/start` and brings the media
    /// plane up.
    ///
    /// **Returning does not mean the media plane is connected.** The MoQ dial
    /// runs in the background: connect success arrives as a `.connected`
    /// event and a dial failure as `.disconnected` (reason
    /// `.transportClosed`) on the event stream — *not* as a thrown error.
    /// Calling ``endSession(_:)`` with the returned id while still dialing
    /// cancels the in-flight dial. Throws only for the `/session/start` HTTP
    /// failure or a malformed request.
    public func startCall(_ options: StartCallOptions) throws -> StartSessionResponse {
        var err = SessionError()
        var resp = SessionStartResponse()

        let rc: Int32 = try withHandle { handle in
            withOptionalCString(options.sessionId) { sidPtr in
                withOptionalCString(options.data) { dataPtr in
                    var opts = SessionStartCallOptions(
                        session_id: sidPtr,
                        data_json: dataPtr
                    )
                    return session_client_start_call(handle, &opts, &resp, &err)
                }
            }
        }
        return try Self.consumeStartResponse(rc, &resp, &err)
    }

    /// Start a **chat**, sending the visitor's first message as part of the
    /// call.
    ///
    /// The first message is required — see ``StartChatOptions`` for why. The
    /// session id comes back BEFORE the message is sent, so the provisional
    /// `.messageAdded` event always has a session to belong to.
    ///
    /// A first message that fails to DELIVER does not throw: the session is
    /// live and the failure arrives as `.messageUpdated` with
    /// `status == .failed`, so the user can retry. Only a TERMINAL refusal
    /// (the session is already gone) throws — returning normally would leave
    /// the app rendering a composer on a dead conversation.
    public func startChat(_ options: StartChatOptions) throws -> StartSessionResponse {
        let firstJson = try Self.encodePayload(options.firstMessage)
        var err = SessionError()
        var resp = SessionStartResponse()

        let rc: Int32 = try withHandle { handle in
            firstJson.withCString { firstPtr in
                withOptionalCString(options.sessionId) { sidPtr in
                    withOptionalCString(options.data) { dataPtr in
                        var opts = SessionStartChatOptions(
                            first_message_json: firstPtr,
                            session_id: sidPtr,
                            data_json: dataPtr
                        )
                        return session_client_start_chat(handle, &opts, &resp, &err)
                    }
                }
            }
        }
        return try Self.consumeStartResponse(rc, &resp, &err)
    }

    private static func consumeStartResponse(
        _ rc: Int32,
        _ resp: inout SessionStartResponse,
        _ err: inout SessionError
    ) throws -> StartSessionResponse {
        guard rc == 0 else { throw OrigonError.consume(&err) }
        defer { session_start_response_free(&resp) }

        guard let sid = resp.session_id, let url = resp.url, let token = resp.token else {
            throw OrigonError(
                kind: .other,
                message: "incomplete StartSessionResponse"
            )
        }
        return StartSessionResponse(
            sessionId: String(cString: sid),
            url: String(cString: url),
            token: String(cString: token)
        )
    }

    /// Attach to a **voice call** whose ``StartSessionResponse`` was obtained
    /// out of band (multi-device handoff, deeplink, persisted session).
    ///
    /// Like ``startCall(_:)``, the MoQ dial runs in the background —
    /// returning here does not mean it is connected; await the `.connected` /
    /// `.disconnected` event.
    public func joinCall(_ input: JoinInput) throws {
        try join(input) { handle, raw, err in
            session_client_join_call(handle, raw, err)
        }
    }

    /// Attach to an existing **chat** obtained out of band — the agent /
    /// chat-offered path. Completes the attach before returning.
    ///
    /// Takes no first message, unlike ``startChat(_:)``: joining is entering
    /// a room whose first-message gate is ALREADY released — the visitor has
    /// spoken, which is why this participant is being offered the
    /// conversation — so there is no deadline left to race.
    public func joinChat(_ input: JoinInput) throws {
        try join(input) { handle, raw, err in
            session_client_join_chat(handle, raw, err)
        }
    }

    private func join(
        _ input: JoinInput,
        _ call: (OpaquePointer, UnsafePointer<SessionJoinInput>, UnsafeMutablePointer<SessionError>) -> Int32
    ) throws {
        var err = SessionError()
        let rc: Int32 = try withHandle { handle in
            input.sessionId.withCString { sidPtr in
                input.url.withCString { urlPtr in
                    input.token.withCString { tokPtr in
                        var raw = SessionJoinInput(
                            session_id: sidPtr,
                            url: urlPtr,
                            token: tokPtr
                        )
                        return call(handle, &raw, &err)
                    }
                }
            }
        }
        if rc != 0 { throw OrigonError.consume(&err) }
    }

    public func endSession(_ id: String) throws {
        var err = SessionError()
        let rc = try withHandle { handle in
            id.withCString { session_client_end_session(handle, $0, &err) }
        }
        if rc != 0 { throw OrigonError.consume(&err) }
    }

    public func endAllSessions() throws {
        var err = SessionError()
        let rc = try withHandle { session_client_end_all_sessions($0, &err) }
        if rc != 0 { throw OrigonError.consume(&err) }
    }

    /// Finite transcript load: optional cache snapshot, one authoritative
    /// refresh (or typed refresh failure), then completion.
    public func sessionUpdates(
        id: String,
        policy: SessionLoadPolicy = .cacheThenNetwork
    ) throws -> AsyncThrowingStream<SessionLoadUpdate, Error> {
        var err = SessionError()
        var rawLoader: OpaquePointer?
        let rc = try withHandle { handle in
            id.withCString {
                session_client_session_loader_start(handle, $0, policy.rawValue, &rawLoader, &err)
            }
        }
        guard rc == 0, let rawLoader else { throw OrigonError.consume(&err) }
        let loader = NativeLoader(rawLoader)
        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(2)) { continuation in
            let task = Task.detached {
                defer { loader.free() }
                do {
                    while !Task.isCancelled {
                        switch try loader.next() {
                        case .update(let json):
                            let snapshot = try JSONDecoder().decode(
                                SessionSnapshot.self,
                                from: Data(json.utf8)
                            )
                            continuation.yield(.snapshot(snapshot))
                        case .refreshFailed(let error, let cached):
                            continuation.yield(.refreshFailed(
                                error: error,
                                cachedSnapshotEmitted: cached
                            ))
                        case .end, .cancelled:
                            continuation.finish()
                            return
                        }
                    }
                    loader.cancel()
                    continuation.finish()
                } catch {
                    loader.cancel()
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                loader.cancel()
                task.cancel()
            }
        }
    }

    /// Finite directory load with the same cache/network ordering as
    /// `sessionUpdates(id:policy:)`.
    public func sessionDirectoryUpdates(
        policy: SessionLoadPolicy = .cacheThenNetwork
    ) throws -> AsyncThrowingStream<SessionDirectoryLoadUpdate, Error> {
        var err = SessionError()
        var rawLoader: OpaquePointer?
        let rc = try withHandle { handle in
            session_client_directory_loader_start(
                handle, policy.rawValue, &rawLoader, &err
            )
        }
        guard rc == 0, let rawLoader else { throw OrigonError.consume(&err) }
        let loader = NativeLoader(rawLoader)
        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(2)) { continuation in
            let task = Task.detached {
                defer { loader.free() }
                do {
                    while !Task.isCancelled {
                        switch try loader.next() {
                        case .update(let json):
                            let snapshot = try JSONDecoder().decode(
                                SessionDirectorySnapshot.self,
                                from: Data(json.utf8)
                            )
                            continuation.yield(.snapshot(snapshot))
                        case .refreshFailed(let error, let cached):
                            continuation.yield(.refreshFailed(
                                error: error,
                                cachedSnapshotEmitted: cached
                            ))
                        case .end, .cancelled:
                            continuation.finish()
                            return
                        }
                    }
                    loader.cancel()
                    continuation.finish()
                } catch {
                    loader.cancel()
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                loader.cancel()
                task.cancel()
            }
        }
    }

    /// Finite strict directory page load. Native request failures are surfaced
    /// as a typed update carrying initial/continuation phase, then the stream ends.
    public func sessionDirectoryPageUpdates(
        request: SessionDirectoryPageRequest = .init()
    ) throws -> AsyncThrowingStream<SessionDirectoryPageLoadUpdate, Error> {
        guard (1...100).contains(request.pageSize) else {
            throw OrigonError(kind: .other, message: "directory page size must be between 1 and 100")
        }
        var err = SessionError()
        var rawLoader: OpaquePointer?
        let rc = try withHandle { handle in
            withOptionalCString(request.cursor) { cursor in
                withOptionalCString(request.search) { search in
                    session_client_directory_page_loader_start(
                        handle, request.pageSize, cursor, search, &rawLoader, &err
                    )
                }
            }
        }
        guard rc == 0, let rawLoader else { throw OrigonError.consume(&err) }
        let loader = NativeLoader(rawLoader)
        let phase = request.phase
        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task.detached {
                defer { loader.free() }
                do {
                    while !Task.isCancelled {
                        switch try loader.next() {
                        case .update(let json):
                            let page = try JSONDecoder().decode(
                                SessionDirectoryPage.self,
                                from: Data(json.utf8)
                            )
                            continuation.yield(.page(page))
                        case .refreshFailed(let error, _):
                            continuation.yield(.failed(error: error, phase: phase))
                        case .end, .cancelled:
                            continuation.finish()
                            return
                        }
                    }
                    loader.cancel()
                    continuation.finish()
                } catch {
                    loader.cancel()
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                loader.cancel()
                task.cancel()
            }
        }
    }

    /// Finite strict transcript page load. Page history is chronological; a
    /// continuation page is older and is prepended by `SessionHistoryPager`.
    public func sessionHistoryPageUpdates(
        id: String,
        request: SessionHistoryPageRequest = .init()
    ) throws -> AsyncThrowingStream<SessionHistoryPageLoadUpdate, Error> {
        guard (1...250).contains(request.pageSize) else {
            throw OrigonError(kind: .other, message: "history page size must be between 1 and 250")
        }
        var err = SessionError()
        var rawLoader: OpaquePointer?
        let rc = try withHandle { handle in
            id.withCString { sessionId in
                withOptionalCString(request.cursor) { cursor in
                    session_client_session_history_page_loader_start(
                        handle, sessionId, request.pageSize, cursor, &rawLoader, &err
                    )
                }
            }
        }
        guard rc == 0, let rawLoader else { throw OrigonError.consume(&err) }
        let loader = NativeLoader(rawLoader)
        let phase = request.phase
        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task.detached {
                defer { loader.free() }
                do {
                    while !Task.isCancelled {
                        switch try loader.next() {
                        case .update(let json):
                            let page = try JSONDecoder().decode(
                                SessionHistoryPage.self,
                                from: Data(json.utf8)
                            )
                            continuation.yield(.page(page))
                        case .refreshFailed(let error, _):
                            continuation.yield(.failed(error: error, phase: phase))
                        case .end, .cancelled:
                            continuation.finish()
                            return
                        }
                    }
                    loader.cancel()
                    continuation.finish()
                } catch {
                    loader.cancel()
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                loader.cancel()
                task.cancel()
            }
        }
    }

    public func cachedSession(id: String) async throws -> SessionSnapshot? {
        for try await update in try sessionUpdates(id: id, policy: .cacheOnly) {
            switch update {
            case .snapshot(let snapshot): return snapshot
            case .refreshFailed(let error, _): throw error
            }
        }
        return nil
    }

    public func refreshSession(id: String) async throws -> SessionSnapshot {
        for try await update in try sessionUpdates(id: id, policy: .networkOnly) {
            switch update {
            case .snapshot(let snapshot): return snapshot
            case .refreshFailed(let error, _): throw error
            }
        }
        throw OrigonError(kind: .other, message: "session refresh ended without a snapshot")
    }

    public func cachedSessions() async throws -> SessionDirectorySnapshot? {
        for try await update in try sessionDirectoryUpdates(policy: .cacheOnly) {
            switch update {
            case .snapshot(let snapshot): return snapshot
            case .refreshFailed(let error, _): throw error
            }
        }
        return nil
    }

    public func refreshSessions() async throws -> SessionDirectorySnapshot {
        for try await update in try sessionDirectoryUpdates(policy: .networkOnly) {
            switch update {
            case .snapshot(let snapshot): return snapshot
            case .refreshFailed(let error, _): throw error
            }
        }
        throw OrigonError(kind: .other, message: "directory refresh ended without a snapshot")
    }

    public func removeCachedSession(id: String) async throws {
        try await Task.detached {
            try self.withHandle { handle in
                var err = SessionError()
                let rc = id.withCString {
                    session_client_remove_cached_session(handle, $0, &err)
                }
                if rc != 0 { throw OrigonError.consume(&err) }
            }
        }.value
    }

    public func clearChatCache() async throws {
        try await Task.detached {
            try self.withHandle { handle in
                var err = SessionError()
                if session_client_clear_chat_cache(handle, &err) != 0 {
                    throw OrigonError.consume(&err)
                }
            }
        }.value
    }

    public func pruneChatCache() async throws {
        try await Task.detached {
            try self.withHandle { handle in
                var err = SessionError()
                if session_client_prune_chat_cache(handle, &err) != 0 {
                    throw OrigonError.consume(&err)
                }
            }
        }.value
    }

    /// Clear every cached identity scope after all clients have been closed.
    public static func clearAllChatCaches() async throws {
        let root = try ChatCacheStorage.prepare().path
        try await Task.detached {
            var err = SessionError()
            let rc = root.withCString { session_chat_cache_clear_root($0, &err) }
            if rc != 0 { throw OrigonError.consume(&err) }
        }.value
    }

    /// Passively attach every retained active chat, newest first. This never
    /// replaces another installation's active visitor stream.
    public func restoreActiveChats() throws -> [RestoreResult] {
        var err = SessionError()
        var report = SessionRestoreReport()
        let rc = try withHandle { session_client_restore_active_chats($0, &report, &err) }
        if rc != 0 { throw OrigonError.consume(&err) }
        defer { session_restore_report_free(&report) }
        guard let items = report.items else { return [] }
        return (0..<Int(report.len)).compactMap { index in
            let item = items[index]
            guard let sessionId = item.session_id,
                  let status = RestoreStatus(rawValue: item.status) else { return nil }
            return RestoreResult(
                sessionId: String(cString: sessionId),
                status: status,
                error: item.error.map { String(cString: $0) }
            )
        }
    }

    /// Open one retained chat with named user authority. Passive restore must
    /// use `.passive`; explicit navigation and notification taps are the only
    /// takeover-authorizing intents.
    public func openChat(
        sessionId: String,
        intent: ChatAccessIntent
    ) throws -> StartSessionResponse {
        var err = SessionError()
        var response = SessionStartResponse()
        let rc = try withHandle { handle in
            sessionId.withCString {
                session_client_open_chat(
                    handle, $0, intent.rawValue, &response, &err
                )
            }
        }
        return try Self.consumeStartResponse(rc, &response, &err)
    }

    /// Snapshot of every active session.
    public func activeSessions() throws -> [ActiveSession] {
        var err = SessionError()
        var jsonPtr: UnsafeMutablePointer<CChar>?
        let rc = try withHandle { session_client_active_session_ids($0, &jsonPtr, &err) }
        if rc != 0 { throw OrigonError.consume(&err) }
        guard let jsonPtr else { return [] }
        defer { session_string_free(jsonPtr) }
        let json = String(cString: jsonPtr)

        guard
            let data = json.data(using: .utf8),
            let array = try? JSONSerialization.jsonObject(with: data) as? [[String: String]]
        else {
            return []
        }
        return array.compactMap { dict in
            guard
                let id = dict["id"],
                let chRaw = dict["channel"],
                let channel = Channel.fromWire(chRaw)
            else { return nil }
            return ActiveSession(sessionId: id, channel: channel)
        }
    }

    // MARK: - Voice controls

    /// Send one DTMF symbol to the active voice session's CX flow.
    ///
    /// `digit` must be one uppercase ASCII symbol from `0-9`, `*`, `#`, or
    /// `A-D`. The SDK sends control data only; it does not synthesize audio,
    /// tones, clicks, or haptics.
    public func sendDtmf(id: String, digit: Character) throws {
        let encoded = try Self.validateDtmfDigit(digit)
        var err = SessionError()
        let rc = try withHandle { handle in
            id.withCString {
                session_client_send_dtmf(handle, $0, encoded, &err)
            }
        }
        if rc != 0 { throw OrigonError.consume(&err) }
    }

    static func validateDtmfDigit(_ digit: Character) throws -> CChar {
        guard
            let ascii = digit.asciiValue,
            "0123456789*#ABCD".utf8.contains(ascii)
        else {
            throw OrigonError(
                kind: .other,
                code: "invalid_dtmf_digit",
                message: "DTMF digit must be one uppercase ASCII symbol"
            )
        }
        return CChar(bitPattern: ascii)
    }

    public func setMute(id: String, muted: Bool) throws {
        var err = SessionError()
        let rc = try withHandle { handle in
            id.withCString {
                session_client_set_mute(handle, $0, muted ? 1 : 0, &err)
            }
        }
        if rc != 0 { throw OrigonError.consume(&err) }
    }

    public func setMuteAll(muted: Bool) throws {
        var err = SessionError()
        let rc = try withHandle { session_client_set_mute_all($0, muted ? 1 : 0, &err) }
        if rc != 0 { throw OrigonError.consume(&err) }
    }

    /// Observe the latest combined outbound, aggregate inbound, and
    /// endpoint-attributed inbound levels for one logical voice session.
    ///
    /// Creation errors throw synchronously. Updates are delivered on
    /// `MainActor`; post-start native failures terminate after the native
    /// terminal-zero update and do not create a callback error channel.
    @discardableResult
    public func observeAudioLevels(
        sessionId: String,
        _ observer: @escaping @MainActor @Sendable (SessionAudioLevels) -> Void
    ) throws -> AudioLevelObservation {
        let source = try withHandle {
            try subscribeAudioLevelsNative($0, sessionId)
        }
        guard let (state, generation) = audioLevelObservations.install(
            sessionId: sessionId,
            source: source
        ) else {
            source.cancel()
            DispatchQueue.global(qos: .userInitiated).async {
                source.free()
            }
            throw OrigonError.notInitialized
        }

        let token = AudioLevelObservation(state: state)
        Self.startAudioLevelPump(
            sessionId: sessionId,
            generation: generation,
            state: state,
            registry: audioLevelObservations,
            observer: observer
        )
        return token
    }

    static func startAudioLevelPump(
        sessionId: String,
        generation: UInt64,
        state: AudioLevelObservationState,
        registry: AudioLevelObservationRegistry,
        observer: @escaping @MainActor @Sendable (SessionAudioLevels) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            defer {
                registry.retire(
                    sessionId: sessionId,
                    generation: generation,
                    state: state
                )
                state.source.free()
            }
            while state.isActive() {
                switch state.source.next() {
                case .update(let levels):
                    let accepted = DispatchSemaphore(value: 0)
                    Task { @MainActor in
                        let deliver = registry.accepts(
                            sessionId: sessionId,
                            generation: generation,
                            state: state
                        )
                        // The pump may continue or retire before user code.
                        // Reentrant cancel/close therefore cannot form a
                        // pump↔MainActor wait cycle.
                        accepted.signal()
                        if deliver {
                            observer(levels)
                        }
                    }
                    accepted.wait()
                case .end, .cancelled:
                    return
                }
            }
        }
    }

    /// Override the audio output route (speaker / receiver / Bluetooth).
    ///
    /// Process-global — affects the app's single active voice session, so it
    /// takes no session id. On iOS this maps to
    /// `AVAudioSession.overrideOutputAudioPort`, and the SDK re-asserts the
    /// route across reconnects and OS route changes. A no-op when no call is
    /// active. Higher-level UI typically wraps this as a boolean speaker toggle
    /// (`.speaker` / `.automatic`).
    public func setAudioOutput(_ route: AudioOutputRoute) throws {
        var err = SessionError()
        let rc = try withHandle {
            session_client_set_audio_output($0, route.rawValue, &err)
        }
        if rc != 0 { throw OrigonError.consume(&err) }
    }

    // MARK: - Chat

    /// Chat-only — send a text / HTML message on the named session.
    ///
    /// Requires an active chat session for `id` (call ``startChat``
    /// first). The SDK fires ``ClientEvent/messageAdded(sessionId:message:)``
    /// (provisional, `status == .sending`) before the wire round-trip
    /// and ``ClientEvent/messageUpdated(sessionId:id:message:)`` (delivered
    /// or failed) after — both surface on ``pollEvent``. Returns the
    /// server-issued `Message`.
    @discardableResult
    public func sendMessage(id: String, payload: SendMessagePayload) throws -> Message {
        let payloadJson = try Self.encodePayload(payload)
        var err = SessionError()
        var outJson: UnsafeMutablePointer<CChar>?
        let rc: Int32 = try withHandle { handle in
            id.withCString { idPtr in
                payloadJson.withCString { jsonPtr in
                    session_client_send_message(handle, idPtr, jsonPtr, &outJson, &err)
                }
            }
        }
        if rc != 0 { throw OrigonError.consume(&err) }
        guard let outJson else {
            throw OrigonError(kind: .other, message: "send_message: missing response body")
        }
        defer { session_string_free(outJson) }
        let json = String(cString: outJson)
        guard let data = json.data(using: .utf8) else {
            throw OrigonError(kind: .other, message: "send_message: utf8 decode")
        }
        do {
            return try JSONDecoder().decode(Message.self, from: data)
        } catch {
            throw OrigonError(
                kind: .other,
                message: "send_message decode: \(error.localizedDescription)"
            )
        }
    }

    /// Chat-only — register a keystroke on the named session. Cheap to
    /// call from `editingChanged`; the SDK debounces outbound
    /// `<sessionUrl>/typing` POSTs so only one wire call fires per
    /// typing burst.
    public func notifyTyping(id: String) throws {
        var err = SessionError()
        let rc = try withHandle { handle in
            id.withCString {
                session_client_notify_typing(handle, $0, &err)
            }
        }
        if rc != 0 { throw OrigonError.consume(&err) }
    }

    /// Chat-only — force outbound typing state to "off" immediately,
    /// cancelling any in-flight debounce. UI fires this on empty-text
    /// transitions; the SDK also fires it implicitly on
    /// ``sendMessage`` and on ``endSession``.
    public func stopTyping(id: String) throws {
        var err = SessionError()
        let rc = try withHandle { handle in
            id.withCString {
                session_client_stop_typing(handle, $0, &err)
            }
        }
        if rc != 0 { throw OrigonError.consume(&err) }
    }

    // MARK: - Attachments

    /// Stream a file at `path` to the WIDGET this client was created
    /// for and return the server-issued ``Attachment``.
    ///
    /// There is no `sessionId` and no session prerequisite — an
    /// attachment can be the first thing a visitor sends.
    ///
    /// For security-scoped `URL`s from `UIDocumentPicker` use the
    /// `url:` overload; for in-memory `Data` use the `data:` overload.
    /// Pass `uploadId` (default: fresh UUID) and hand the same value to
    /// ``deleteAttachment(attachmentId:)`` to cancel in-flight.
    /// `onProgress` is invoked on `@MainActor`.
    ///
    /// See `client-sdk/session/docs/contract.md#attachment-flow` for
    /// MIME detection, policy prechecks, and error code semantics.
    public func uploadAttachment(
        uploadId: String = UUID().uuidString,
        path: String,
        fileName: String,
        onProgress: (@MainActor @Sendable (UploadProgress) -> Void)? = nil
    ) async throws -> Attachment {
        // Retain the closure across the C boundary; released on every
        // exit path below.
        let boxPtr: UnsafeMutableRawPointer? = onProgress.map { closure in
            Unmanaged.passRetained(UploadProgressBox(closure: closure)).toOpaque()
        }

        let trampoline: SessionUploadProgressCallback? = onProgress == nil ? nil : { ctx, uploaded, total in
            guard let ctx else { return }
            let box = Unmanaged<UploadProgressBox>.fromOpaque(ctx).takeUnretainedValue()
            let totalBytes: UInt64? = total < 0 ? nil : UInt64(total)
            let percent: UInt8?
            if let t = totalBytes, t > 0 {
                let p = (uploaded * 100) / t
                percent = UInt8(min(p, 100))
            } else {
                percent = nil
            }
            let progress = UploadProgress(
                bytesUploaded: uploaded,
                totalBytes: totalBytes,
                percent: percent
            )
            Task { @MainActor in
                box.closure(progress)
            }
        }

        do {
            let attachment = try await Task.detached {
                try self.withHandle { handle in
                    try Self.invokeUploadAttachment(
                        handle: handle,
                        uploadId: uploadId,
                        path: path,
                        fileName: fileName,
                        callback: trampoline,
                        ctx: boxPtr
                    )
                }
            }.value
            if let boxPtr {
                Unmanaged<UploadProgressBox>.fromOpaque(boxPtr).release()
            }
            return attachment
        } catch {
            if let boxPtr {
                Unmanaged<UploadProgressBox>.fromOpaque(boxPtr).release()
            }
            throw error
        }
    }

    /// Convenience overload that materialises in-memory `data` under
    /// `NSTemporaryDirectory()` and delegates to the path-based
    /// overload. Temp file is removed on every exit path.
    public func uploadAttachment(
        uploadId: String = UUID().uuidString,
        data: Data,
        fileName: String,
        onProgress: (@MainActor @Sendable (UploadProgress) -> Void)? = nil
    ) async throws -> Attachment {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        // Preserve extension so MIME sniff's filename fallback still works.
        let ext = (fileName as NSString).pathExtension
        let unique = UUID().uuidString + (ext.isEmpty ? "" : ".\(ext)")
        let tempURL = tempDir.appendingPathComponent(unique)
        try data.write(to: tempURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        return try await uploadAttachment(
            uploadId: uploadId,
            path: tempURL.path,
            fileName: fileName,
            onProgress: onProgress
        )
    }

    /// Convenience overload for `URL`s. Manages
    /// `startAccessingSecurityScopedResource()` automatically for
    /// `UIDocumentPicker`-style URLs.
    public func uploadAttachment(
        uploadId: String = UUID().uuidString,
        url: URL,
        fileName: String? = nil,
        onProgress: (@MainActor @Sendable (UploadProgress) -> Void)? = nil
    ) async throws -> Attachment {
        let needsScoped = url.startAccessingSecurityScopedResource()
        defer {
            if needsScoped { url.stopAccessingSecurityScopedResource() }
        }
        let resolvedName = fileName ?? url.lastPathComponent
        return try await uploadAttachment(
            uploadId: uploadId,
            path: url.path,
            fileName: resolvedName,
            onProgress: onProgress
        )
    }

    /// Dual-purpose: cancel an in-flight upload (when `attachmentId`
    /// matches an active `uploadId`) or `DELETE` a completed attachment
    /// by server id. Session-less like ``uploadAttachment(uploadId:path:fileName:onProgress:)``.
    /// See `client-sdk/session/docs/contract.md#cancellation`.
    public func deleteAttachment(attachmentId: String) async throws {
        try await Task.detached {
            try self.withHandle { handle in
                var err = SessionError()
                let rc = attachmentId.withCString { aidPtr in
                    session_client_delete_attachment(handle, aidPtr, &err)
                }
                if rc != 0 { throw OrigonError.consume(&err) }
            }
        }.value
    }

    /// Blocking FFI call, intended for use from a detached task.
    private static func invokeUploadAttachment(
        handle: OpaquePointer,
        uploadId: String,
        path: String,
        fileName: String,
        callback: SessionUploadProgressCallback?,
        ctx: UnsafeMutableRawPointer?
    ) throws -> Attachment {
        var err = SessionError()
        var outJson: UnsafeMutablePointer<CChar>?
        let rc: Int32 = uploadId.withCString { uidPtr in
            path.withCString { pathPtr in
                fileName.withCString { namePtr in
                    session_client_upload_attachment(
                        handle,
                        uidPtr,
                        pathPtr,
                        namePtr,
                        callback,
                        ctx,
                        &outJson,
                        &err
                    )
                }
            }
        }
        if rc != 0 { throw OrigonError.consume(&err) }
        guard let outJson else {
            throw OrigonError(kind: .other, message: "upload_attachment: missing response body")
        }
        defer { session_string_free(outJson) }
        let json = String(cString: outJson)
        guard let jsonData = json.data(using: .utf8) else {
            throw OrigonError(kind: .other, message: "upload_attachment: utf8 decode")
        }
        do {
            return try JSONDecoder().decode(Attachment.self, from: jsonData)
        } catch {
            throw OrigonError(
                kind: .other,
                message: "upload_attachment decode: \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Events

    /// Polls the next event. Returns `nil` when the queue is idle.
    public func pollEvent() -> ClientEvent? {
        withHandleOr(Optional<ClientEvent>.none) { handle in
            var ev = SessionEvent()
            let kind = session_client_poll_event(handle, &ev)
            if kind == SESSION_EVENT_NONE { return nil }
            let mapped = mapEvent(ev)
            session_event_clear(&ev)
            return mapped
        }
    }

    // MARK: - Private

    /// JSON-encode a `SendMessagePayload` for the C FFI. Throws
    /// `OrigonError.other` on encode failure.
    private static func encodePayload(_ payload: SendMessagePayload) throws -> String {
        do {
            let data = try JSONEncoder().encode(payload)
            guard let s = String(data: data, encoding: .utf8) else {
                throw OrigonError(kind: .other, message: "payload encode: utf8")
            }
            return s
        } catch let e as OrigonError {
            throw e
        } catch {
            throw OrigonError(
                kind: .other,
                message: "payload encode: \(error.localizedDescription)"
            )
        }
    }

    /// Decode the FFI's `message_json` field into a Swift `Message`.
    /// Returns `nil` on any failure (caller treats as "drop the event").
    private static func decodeMessage(_ cstr: UnsafeMutablePointer<CChar>?) -> Message? {
        guard let cstr else { return nil }
        let json = String(cString: cstr)
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Message.self, from: data)
    }

    /// Decode the authoritative typing snapshot carried in the existing
    /// `message_json` slot. Malformed payloads are dropped fail-closed.
    private static func decodeTypingState(_ cstr: UnsafeMutablePointer<CChar>?) -> TypingState? {
        guard let cstr else { return nil }
        let json = String(cString: cstr)
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(TypingState.self, from: data)
    }

    /// Wire shape of the `chatSessionEnded` payload, which rides the FFI's
    /// `message_json` slot as `{reason, acw?}` (same field the message
    /// events use). `acw` is present only on an agent participant's stream.
    private struct SessionEndedPayload: Decodable {
        let reason: String
        let acw: Acw?

        private enum CodingKeys: String, CodingKey { case reason, acw }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
            self.acw = try c.decodeIfPresent(Acw.self, forKey: .acw)
        }
    }

    /// Decode the `chatSessionEnded` payload from `message_json`. A missing
    /// or malformed payload degrades to an empty reason with no ACW — the
    /// clean-end signal itself (the event kind) is what matters.
    private static func decodeSessionEnded(_ cstr: UnsafeMutablePointer<CChar>?) -> (reason: String, acw: Acw?) {
        guard let cstr else { return ("", nil) }
        let json = String(cString: cstr)
        guard
            let data = json.data(using: .utf8),
            let payload = try? JSONDecoder().decode(SessionEndedPayload.self, from: data)
        else { return ("", nil) }
        return (payload.reason, payload.acw)
    }

    private func mapEvent(_ ev: SessionEvent) -> ClientEvent? {
        guard let sidPtr = ev.session_id else { return nil }
        let sid = String(cString: sidPtr)

        switch ev.kind {
        case SESSION_EVENT_MESSAGE_ADDED:
            guard let msg = Self.decodeMessage(ev.message_json) else { return nil }
            return .messageAdded(sessionId: sid, message: msg)

        case SESSION_EVENT_MESSAGE_UPDATED:
            guard let msg = Self.decodeMessage(ev.message_json) else { return nil }
            let updateId = ev.update_id.map { String(cString: $0) } ?? ""
            return .messageUpdated(sessionId: sid, id: updateId, message: msg)

        case SESSION_EVENT_SESSION_UPDATED:
            let new = ev.new_session_id.map { String(cString: $0) } ?? ""
            return .sessionUpdated(sessionId: sid, newSessionId: new)

        case SESSION_EVENT_CONTROL_UPDATED:
            return .controlUpdated(sessionId: sid, control: SessionControl.fromC(ev.control))

        case SESSION_EVENT_TYPING:
            guard let state = Self.decodeTypingState(ev.message_json) else { return nil }
            return .typing(sessionId: sid, state: state)

        case SESSION_EVENT_CONNECTED:
            return .connected(sessionId: sid)

        case SESSION_EVENT_RECONNECTING:
            return .reconnecting(
                sessionId: sid,
                attempt: ev.reconnect_attempt,
                reason: DisconnectReason.fromC(ev.disconnect_reason)
            )

        case SESSION_EVENT_RECONNECTED:
            return .reconnected(sessionId: sid)

        case SESSION_EVENT_PEER_ATTACHED:
            let peer = ev.peer_endpoint_id.map { String(cString: $0) } ?? ""
            return .peerAttached(sessionId: sid, peerEndpointId: peer, alias: ev.peer_alias)

        case SESSION_EVENT_PEER_DETACHED:
            let peer = ev.peer_endpoint_id.map { String(cString: $0) } ?? ""
            return .peerDetached(sessionId: sid, peerEndpointId: peer, alias: ev.peer_alias)

        case SESSION_EVENT_DISCONNECTED:
            return .disconnected(
                sessionId: sid,
                reason: DisconnectReason.fromC(ev.disconnect_reason)
            )

        case SESSION_EVENT_CALL_ERROR:
            let msg: String? = ev.call_error_present != 0
                ? ev.call_error_message.map { String(cString: $0) }
                : nil
            return .callError(sessionId: sid, message: msg)

        case SESSION_EVENT_AUDIO_ROUTE_CHANGED:
            let route = AudioOutputRoute(rawValue: ev.audio_route) ?? .automatic
            return .audioRouteChanged(sessionId: sid, route: route)

        case SESSION_EVENT_CHAT_SESSION_ENDED:
            let ended = Self.decodeSessionEnded(ev.message_json)
            return .chatSessionEnded(sessionId: sid, reason: ended.reason, acw: ended.acw)

        default:
            return nil
        }
    }
}

private enum NativeLoaderStep {
    case update(String)
    case refreshFailed(OrigonError, Bool)
    case end
    case cancelled
}

/// Owns the native loader independently of the client pointer. Cancellation
/// never takes the lock used to exchange the pointer, so it can unblock a
/// simultaneous blocking `next`; only the loader task calls `free` after
/// `next` has returned.
private final class NativeLoader: @unchecked Sendable {
    private let lock = NSLock()
    private var pointer: OpaquePointer?
    private var cancelled = false

    init(_ pointer: OpaquePointer) {
        self.pointer = pointer
    }

    func next() throws -> NativeLoaderStep {
        lock.lock()
        let current = pointer
        lock.unlock()
        guard let current else { return .cancelled }

        var result = SessionLoaderResult()
        let status = session_loader_next(current, &result)
        defer { session_loader_result_clear(&result) }
        guard status >= 0 else {
            throw OrigonError(kind: .other, message: "native loader next failed")
        }
        switch status {
        case SESSION_LOADER_UPDATE:
            guard let payload = result.payload_json else {
                throw OrigonError(kind: .other, message: "native loader returned no payload")
            }
            return .update(String(cString: payload))
        case SESSION_LOADER_ERROR:
            return .refreshFailed(
                OrigonError.consume(&result.error),
                result.cached_snapshot_emitted != 0
            )
        case SESSION_LOADER_CANCELLED:
            return .cancelled
        default:
            return .end
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        if let pointer { session_loader_cancel(pointer) }
        lock.unlock()
    }

    func free() {
        lock.lock()
        if let current = pointer {
            if !cancelled { session_loader_cancel(current) }
            cancelled = true
            pointer = nil
            session_loader_free(current)
        }
        lock.unlock()
    }
}

// MARK: - Upload helpers

/// Reference wrapper so the `onProgress` closure can survive a
/// `void *ctx` round-trip across the C boundary.
private final class UploadProgressBox: @unchecked Sendable {
    let closure: @MainActor @Sendable (UploadProgress) -> Void
    init(closure: @escaping @MainActor @Sendable (UploadProgress) -> Void) {
        self.closure = closure
    }
}

// MARK: - Conversion helpers

private func withOptionalCString<R>(
    _ s: String?,
    _ body: (UnsafePointer<CChar>?) -> R
) -> R {
    if let s {
        return s.withCString { body($0) }
    } else {
        return body(nil)
    }
}

// `Channel` no longer crosses the C boundary as an integer: the split into
// startCall/startChat + joinCall/joinChat removed the runtime discriminator
// every signature used to carry, so `SESSION_CHANNEL_*` is gone from the
// bridge header. The enum survives only where the SERVER names a channel in
// a JSON payload — hence `fromWire` below and no `toC` / `fromC`.
extension Channel {

    static func fromWire(_ s: String) -> Channel? {
        switch s {
        case "voice": return .voice
        case "chat": return .chat
        default: return nil
        }
    }
}

extension SessionControl {
    static func fromC(_ c: Int32) -> SessionControl {
        c == SESSION_CONTROL_USER ? .user : .ai
    }
}


extension DisconnectReason {
    static func fromC(_ r: SessionDisconnectReason) -> DisconnectReason {
        switch r.kind {
        case SESSION_DISCONNECT_REASON_LOCAL_CLOSE: return .localClose
        case SESSION_DISCONNECT_REASON_NETWORK_LOSS: return .networkLoss
        case SESSION_DISCONNECT_REASON_ENDPOINT_NOT_PROVISIONED: return .endpointNotProvisioned
        case SESSION_DISCONNECT_REASON_ENDPOINT_ALREADY_CONNECTED: return .endpointAlreadyConnected
        case SESSION_DISCONNECT_REASON_TOKEN_INVALID: return .tokenInvalid
        case SESSION_DISCONNECT_REASON_TOKEN_EXPIRED: return .tokenExpired
        case SESSION_DISCONNECT_REASON_TOKEN_REPLAYED: return .tokenReplayed
        case SESSION_DISCONNECT_REASON_PROTOCOL_VIOLATION: return .protocolViolation
        case SESSION_DISCONNECT_REASON_CAPABILITY_MISSING: return .capabilityMissing
        case SESSION_DISCONNECT_REASON_ILLEGAL_STATE: return .illegalState
        case SESSION_DISCONNECT_REASON_RESOURCE_EXHAUSTED: return .resourceExhausted
        case SESSION_DISCONNECT_REASON_REPLAY_LOST: return .replayLost
        case SESSION_DISCONNECT_REASON_SESSION_ENDED: return .sessionEnded
        case SESSION_DISCONNECT_REASON_SERVER_CLOSED:
            let detail = r.server_detail.map { String(cString: $0) }
            return .serverClosed(code: r.server_code, detail: detail)
        case SESSION_DISCONNECT_REASON_TRANSPORT_CLOSED:
            let detail = r.server_detail.map { String(cString: $0) }
            return .transportClosed(detail: detail)
        default:
            let detail = r.server_detail.map { String(cString: $0) }
            return .serverClosed(code: r.server_code, detail: detail)
        }
    }
}

extension OrigonError {
    /// Read a populated `SessionError`, clear it, and return a Swift
    /// `OrigonError`. Use on every `-1` return path.
    static func consume(_ err: inout SessionError) -> OrigonError {
        let kind = OrigonError.Kind(rawValue: Int(err.kind)) ?? .unknown
        let status = Int(err.status)
        let code = err.code.map { String(cString: $0) }
        let message = err.message.map { String(cString: $0) }
        session_error_clear(&err)
        return OrigonError(kind: kind, statusCode: status, code: code, message: message)
    }
}
