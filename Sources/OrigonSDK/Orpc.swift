import Foundation
import COrigonSDK

/// A product-free oRPC session held on gw's `orpc-2` ALPN: one QUIC session
/// plus one generation-fenced session-open stream (for Dock, `cx.v1.Dock/Login`).
///
/// Bytes only — paths, metadata and payloads belong to the caller, which owns
/// the product's protobuf. Read ``items`` from exactly one task. After a
/// ``Item/streamEnded(generation:)`` call ``reopen(_:expectedGeneration:)`` to
/// re-open the stream on the same session (gw's persistent-session relay keeps
/// the session id), or ``end()``. Every blocking native call runs off the
/// caller's thread.
public final class OrpcSession: @unchecked Sendable {
    /// One request: a path, binary-safe metadata and an encoded body.
    public struct Request: Sendable {
        public var path: String
        public var metadata: [(key: String, value: Data)]
        public var body: Data

        public init(path: String, metadata: [(key: String, value: Data)] = [], body: Data = Data()) {
            self.path = path
            self.metadata = metadata
            self.body = body
        }

        /// Borrow this request as C for the duration of `body`.
        func withC<R>(_ body: (UnsafePointer<SessionOrpcRequest>) -> R) -> R {
            let keys = metadata.map { strdup($0.key) }
            let values = metadata.map { [UInt8]($0.value) }
            defer { keys.forEach { free($0) } }
            return values.withUnsafeBufferPointers { valuePointers in
                var entries = zip(keys, zip(valuePointers, values)).map { key, value in
                    SessionOrpcMetadata(
                        key: UnsafePointer(key),
                        value: value.0,
                        value_len: value.1.count
                    )
                }
                return path.withCString { pathPtr in
                    self.body.withUnsafeBytes { bodyBytes in
                        entries.withUnsafeMutableBufferPointer { entryBuffer in
                            var request = SessionOrpcRequest(
                                path: pathPtr,
                                metadata: UnsafePointer(entryBuffer.baseAddress),
                                metadata_count: entryBuffer.count,
                                body: bodyBytes.bindMemory(to: UInt8.self).baseAddress,
                                body_len: bodyBytes.count
                            )
                            return body(&request)
                        }
                    }
                }
            }
        }
    }

    public enum Status: Equatable, Sendable {
        case connecting
        case live
        case reconnecting(attempt: UInt32)
    }

    /// Why the session ended; the last item before ``items`` finishes.
    public enum Terminal: Equatable, Sendable {
        case ended
        case sessionEnded(String)
        case overflow
    }

    public enum Item: Equatable, Sendable {
        case frame(generation: UInt64, data: Data)
        case streamEnded(generation: UInt64)
        case status(Status)
        case terminal(Terminal)
    }

    private let lock = NSLock()
    private var pointer: OpaquePointer?
    private var cancelled = false

    /// The stream generation the session opened with.
    public let initialGeneration: UInt64 = 1

    /// Items until the terminal, then the stream finishes. Single consumer.
    public private(set) lazy var items: AsyncStream<Item> = makeItems()

    init(pointer: OpaquePointer) {
        self.pointer = pointer
    }

    /// Dial the account backend at `url` (its host, gw's `orpc-2` :443) and
    /// open `request` as stream generation 1.
    ///
    /// - Returns: the session and the stream's first response body.
    public static func open(
        client: OrigonClient,
        url: String,
        request: Request
    ) async throws -> (OrpcSession, Data) {
        try await offload {
            let (raw, response) = try client.openOrpc(url: url, request: request)
            return (OrpcSession(pointer: raw), response)
        }
    }

    /// Re-open the session-open stream after ``Item/streamEnded(generation:)``.
    ///
    /// - Returns: the new generation and first body, or `nil` when another
    ///   re-open or ``end()`` already replaced `expectedGeneration`.
    public func reopen(
        _ request: Request,
        expectedGeneration: UInt64
    ) async throws -> (generation: UInt64, response: Data)? {
        try await Self.offload { [self] in
            try withPointer { raw in
                var err = SessionError()
                var generation: UInt64 = 0
                var response = SessionBytes()
                let rc = request.withC { cRequest in
                    session_orpc_reopen(raw, cRequest, expectedGeneration, &generation, &response, &err)
                }
                switch rc {
                case 0:
                    defer { session_bytes_free(&response) }
                    return (generation, Data(orpcBytes: response))
                case 1:
                    return nil
                default:
                    throw OrigonError.consume(&err)
                }
            }
        }
    }

    /// A unary RPC on the held session.
    public func unary(_ request: Request, timeout: TimeInterval = 5) async throws -> Data {
        let timeoutMs = UInt32(clamping: Int((timeout * 1000).rounded()))
        return try await Self.offload { [self] in
            try withPointer { raw in
                var err = SessionError()
                var response = SessionBytes()
                let rc = request.withC { cRequest in
                    session_orpc_unary(raw, cRequest, timeoutMs, &response, &err)
                }
                guard rc == 0 else { throw OrigonError.consume(&err) }
                defer { session_bytes_free(&response) }
                return Data(orpcBytes: response)
            }
        }
    }

    /// End the session intentionally; ``items`` drains, then yields
    /// ``Terminal/ended``. Idempotent.
    public func end() async {
        _ = try? await Self.offload { [self] in
            try withPointer { session_orpc_end($0) }
        }
    }

    // MARK: - Internals

    private func withPointer<R>(_ body: (OpaquePointer) throws -> R) throws -> R {
        lock.lock()
        let current = cancelled ? nil : pointer
        lock.unlock()
        guard let current else {
            throw OrigonError(kind: .orpcUnavailable, message: "orpc session closed")
        }
        return try body(current)
    }

    private func makeItems() -> AsyncStream<Item> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let thread = Thread { [self] in
                while true {
                    lock.lock()
                    let current = pointer
                    lock.unlock()
                    guard let current else { break }
                    var next = SessionOrpcNext()
                    let kind = session_orpc_next(current, &next)
                    let item = Self.item(kind: kind, next)
                    session_orpc_next_clear(&next)
                    guard let item else { break }
                    continuation.yield(item)
                    if case .terminal = item { break }
                }
                continuation.finish()
                freeAfterNext()
            }
            thread.name = "ai.origon.sdk.orpc-next"
            continuation.onTermination = { [weak self] _ in self?.cancel() }
            thread.start()
        }
    }

    static func item(kind: Int32, _ next: SessionOrpcNext) -> Item? {
        switch kind {
        case SESSION_ORPC_NEXT_FRAME:
            return .frame(generation: next.generation, data: Data(orpcBytes: next.data))
        case SESSION_ORPC_NEXT_STREAM_ENDED:
            return .streamEnded(generation: next.generation)
        case SESSION_ORPC_NEXT_STATUS:
            switch next.status {
            case SESSION_ORPC_STATUS_LIVE: return .status(.live)
            case SESSION_ORPC_STATUS_RECONNECTING: return .status(.reconnecting(attempt: next.attempt))
            default: return .status(.connecting)
            }
        case SESSION_ORPC_NEXT_TERMINAL:
            switch next.terminal {
            case SESSION_ORPC_TERMINAL_OVERFLOW: return .terminal(.overflow)
            case SESSION_ORPC_TERMINAL_SESSION_ENDED:
                return .terminal(.sessionEnded(next.detail.map { String(cString: $0) } ?? ""))
            default: return .terminal(.ended)
            }
        default:
            // CLOSED, CANCELLED or a native failure: nothing more will arrive.
            return nil
        }
    }

    /// Unblock a waiting `next`; the reader thread then frees the session.
    private func cancel() {
        lock.lock()
        if !cancelled, let pointer {
            cancelled = true
            session_orpc_cancel(pointer)
        }
        lock.unlock()
    }

    /// Called only by the reader thread after its last `next` returned.
    private func freeAfterNext() {
        lock.lock()
        let current = pointer
        pointer = nil
        cancelled = true
        lock.unlock()
        if let current { session_orpc_free(current) }
    }

    private static func offload<R: Sendable>(_ body: @escaping @Sendable () throws -> R) async throws -> R {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try body() })
            }
        }
    }

    deinit {
        lock.lock()
        let current = pointer
        pointer = nil
        lock.unlock()
        // Without a reader there is no `next` in flight.
        if let current { session_orpc_free(current) }
    }
}

extension Data {
    init(orpcBytes bytes: SessionBytes) {
        if let data = bytes.data, bytes.len > 0 {
            self.init(bytes: data, count: bytes.len)
        } else {
            self.init()
        }
    }
}

extension Array where Element == [UInt8] {
    /// Pointers to each array's storage, valid inside `body`.
    fileprivate func withUnsafeBufferPointers<R>(
        _ body: ([UnsafePointer<UInt8>?]) -> R
    ) -> R {
        func recurse(_ index: Int, _ acc: [UnsafePointer<UInt8>?]) -> R {
            if index == count { return body(acc) }
            return self[index].withUnsafeBufferPointer { buffer in
                recurse(index + 1, acc + [buffer.baseAddress])
            }
        }
        return recurse(0, [])
    }
}
