import Foundation

public final class SessionDirectoryPager: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var search: String?
    private var sessions: [SessionSummary] = []
    private var live: [SessionSummary] = []
    private var nextCursor: String?
    private var emptyContinuations = 0

    public init() {}

    @discardableResult
    public func begin(search rawSearch: String? = nil, cached: [SessionSummary] = []) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        generation = generation &+ 1
        if generation == 0 { generation = 1 }
        let normalized = normalizeSessionSearch(rawSearch ?? "")
        search = normalized.isEmpty ? nil : normalized
        sessions = search == nil ? cached : []
        live = []
        nextCursor = nil
        emptyContinuations = 0
        return generation
    }

    public func applyLive(_ summary: SessionSummary) {
        lock.lock()
        defer { lock.unlock() }
        live.removeAll { $0.sessionId == summary.sessionId }
        sessions.removeAll { $0.sessionId == summary.sessionId }
        if search.map({ sessionSummary(summary, matches: $0) }) ?? true {
            live.append(summary)
            sessions.append(summary)
        }
        sortSessions()
    }

    @discardableResult
    public func merge(_ page: SessionDirectoryPage, generation candidate: UInt64, firstPage: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard candidate == generation else { return false }
        let pageWasEmpty = page.sessions.isEmpty
        if firstPage { sessions = [] }
        for summary in page.sessions { upsert(summary, into: &sessions) }
        for summary in live { upsert(summary, into: &sessions) }
        sortSessions()
        nextCursor = page.nextCursor
        emptyContinuations = pageWasEmpty && nextCursor != nil ? min(255, emptyContinuations + 1) : 0
        return true
    }

    public var snapshot: SessionDirectoryPageSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return .init(
            generation: generation,
            search: search,
            sessions: sessions,
            nextCursor: nextCursor,
            emptyContinuations: emptyContinuations
        )
    }

    private func sortSessions() {
        sessions.sort { $0.updatedAt > $1.updatedAt }
    }
}

public final class SessionHistoryPager: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var history: [Message] = []
    private var live: [Message] = []
    private var control: SessionControl = .ai
    private var nextCursor: String?
    private var emptyContinuations = 0

    public init() {}

    @discardableResult
    public func begin(cached: SessionHistory? = nil) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        generation = generation &+ 1
        if generation == 0 { generation = 1 }
        history = cached?.history ?? []
        control = cached?.control ?? .ai
        live = []
        nextCursor = nil
        emptyContinuations = 0
        return generation
    }

    public func applyLive(_ message: Message) {
        lock.lock()
        defer { lock.unlock() }
        upsert(message, into: &live)
        upsert(message, into: &history)
    }

    @discardableResult
    public func merge(_ page: SessionHistoryPage, generation candidate: UInt64, firstPage: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard candidate == generation else { return false }
        let pageWasEmpty = page.history.isEmpty
        if firstPage {
            history = page.history
        } else {
            var merged = page.history
            for message in history { upsert(message, into: &merged) }
            history = merged
        }
        for message in live { upsert(message, into: &history) }
        control = page.control
        nextCursor = page.nextCursor
        emptyContinuations = pageWasEmpty && nextCursor != nil ? min(255, emptyContinuations + 1) : 0
        return true
    }

    public var snapshot: SessionHistoryPageSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return .init(
            generation: generation,
            history: history,
            control: control,
            nextCursor: nextCursor,
            emptyContinuations: emptyContinuations
        )
    }
}

public func normalizeSessionSearch(_ value: String) -> String {
    var result = ""
    var pendingSpace = false
    for scalar in value.unicodeScalars {
        if scalar.properties.isWhitespace {
            pendingSpace = !result.isEmpty
            continue
        }
        if scalar.properties.generalCategory == .control { continue }
        if pendingSpace {
            result.append(" ")
            pendingSpace = false
        }
        result.append(contentsOf: String(scalar).lowercased())
    }
    return result
}

public func sessionSummary(_ summary: SessionSummary, matches normalizedSearch: String) -> Bool {
    func contains(_ value: String?) -> Bool {
        value.map { normalizeSessionSearch($0).contains(normalizedSearch) } ?? false
    }
    return contains(summary.subject)
        || contains(summary.contact?.name)
        || contains(summary.lastMessage?.text)
        || (summary.lastMessage?.attachments.contains { contains($0.name) } ?? false)
}

private func upsert(_ summary: SessionSummary, into values: inout [SessionSummary]) {
    if let index = values.firstIndex(where: { $0.sessionId == summary.sessionId }) {
        values[index] = summary
    } else {
        values.append(summary)
    }
}

private func sameMessage(_ existing: Message, _ incoming: Message) -> Bool {
    (!incoming.id.isEmpty && (existing.id == incoming.id || existing.localId == incoming.id))
        || incoming.localId.map { existing.id == $0 || existing.localId == $0 } == true
}

private func upsert(_ message: Message, into values: inout [Message]) {
    if let index = values.firstIndex(where: { sameMessage($0, message) }) {
        values[index] = message
    } else {
        values.append(message)
    }
}
