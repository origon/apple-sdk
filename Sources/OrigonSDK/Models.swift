import Foundation

// MARK: - Enums

public enum Channel: String, Codable, Sendable {
    case chat
    case voice
}

public enum SessionControl: String, Codable, Sendable {
    case ai
    case user
}

public enum MessageRole: String, Codable, Sendable {
    case ai
    case external
    case user
    case system
}

/// Delivery status of a `Message`.
public enum MessageStatus: String, Codable, Sendable {
    case sending
    case delivered
    case failed
}

/// Generation state of a `Message`. `streaming` while tokens are still
/// arriving from the agent; `completed` once finalised.
public enum MessageState: String, Codable, Sendable {
    case streaming
    case completed
}

/// Closed delivery-audience vocabulary. The field holding it may be absent.
public enum MessageAudience: String, Codable, Sendable {
    /// Visible only to attached internal agents and supervisors.
    case internalParticipants = "internal"
    /// Visible to internal participants and the external visitor.
    case all
}

/// Server-stamped identity for one active remote typer. This value is
/// ephemeral; consumers must not persist or log it.
public struct TypingParticipant: Codable, Sendable, Equatable {
    public let participantId: String
    public let role: MessageRole
    public let userId: String?
    public let userName: String?
    public let audience: MessageAudience

    public init(
        participantId: String,
        role: MessageRole,
        userId: String? = nil,
        userName: String? = nil,
        audience: MessageAudience
    ) {
        self.participantId = participantId
        self.role = role
        self.userId = userId
        self.userName = userName
        self.audience = audience
    }
}

/// Stable first-activation-ordered snapshot of active remote typers.
public struct TypingState: Codable, Sendable, Equatable {
    public let participants: [TypingParticipant]

    public init(participants: [TypingParticipant] = []) {
        self.participants = participants
    }
}

/// Optional message metadata. Unknown non-empty audiences fail decoding.
public struct MessageMetadata: Codable, Sendable, Equatable {
    public let audience: MessageAudience?

    public init(audience: MessageAudience? = nil) {
        self.audience = audience
    }

    private enum CodingKeys: String, CodingKey { case audience }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let raw = try c.decodeIfPresent(String.self, forKey: .audience), !raw.isEmpty else {
            self.audience = nil
            return
        }
        guard let audience = MessageAudience(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(
                forKey: .audience,
                in: c,
                debugDescription: "Unknown message audience: \(raw)"
            )
        }
        self.audience = audience
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(audience, forKey: .audience)
    }
}

/// Audio output route override for a voice call — the "speakerphone" concept,
/// distinct from device selection. On iOS this maps onto
/// `AVAudioSession.overrideOutputAudioPort`; the SDK re-asserts the choice
/// across reconnects and OS route changes. Raw values are ABI-stable across
/// the native boundary (`default` is a Swift keyword, hence `automatic`).
public enum AudioOutputRoute: Int32, Sendable {
    /// System default — receiver/earpiece, or wired/Bluetooth when present.
    case automatic = 0
    /// Built-in loudspeaker (speakerphone).
    case speaker = 1
    /// Bluetooth hands-free. iOS resolves this via `automatic`.
    case bluetooth = 2
}

/// APNs delivery environment for a device token.
///
/// A token is bound to the environment of the build that produced it —
/// development builds yield `.sandbox` tokens, App Store / TestFlight
/// builds yield `.production` tokens — and the backend must target the
/// matching APNs host or APNs rejects the push with `BadDeviceToken`.
/// `OrigonClient.registerForPushNotifications` auto-detects this from the
/// app's embedded provisioning profile; pass an explicit value only to
/// override that detection.
public enum APNSEnvironment: String, Sendable {
    case sandbox
    case production
}

/// Durable transcript caching is enabled by default. Disable it only when the
/// host deliberately requires network-only persistence semantics.
public enum ChatCachePolicy: Sendable, Equatable {
    case enabled
    case disabled
}

public enum SessionLoadPolicy: Int32, Sendable, Equatable {
    case cacheThenNetwork = 0
    case networkOnly = 1
    case cacheOnly = 2
}

public enum SessionLoadSource: String, Codable, Sendable, Equatable {
    case cache
    case network
}

public enum ChatAccessIntent: Int32, Sendable, Equatable {
    case passive = 0
    case explicitNavigation = 1
    case notification = 2
}

/// One endpoint-attributed inbound level in a logical voice session.
public struct EndpointAudioLevel: Sendable {
    public let endpointId: String
    public let inbound: Float

    public init(endpointId: String, inbound: Float) {
        self.endpointId = endpointId
        self.inbound = inbound
    }
}

/// Latest complete numeric audio-level snapshot for one logical voice session.
public struct SessionAudioLevels: Sendable {
    public let sessionId: String
    public let outbound: Float
    public let inbound: Float
    public let endpoints: [EndpointAudioLevel]

    public init(
        sessionId: String,
        outbound: Float,
        inbound: Float,
        endpoints: [EndpointAudioLevel]
    ) {
        self.sessionId = sessionId
        self.outbound = outbound
        self.inbound = inbound
        self.endpoints = endpoints
    }
}

// MARK: - Configuration / requests

/// Configuration for creating an `OrigonClient`.
public struct ClientConfig: Sendable {
    public let endpoint: String
    public let token: String?
    /// Optional. When omitted, the SDK uses its random, install-scoped
    /// identifier as an opaque anonymous id. It is not a person or hardware
    /// identity and is excluded from backup/restore.
    public let userId: String?
    /// Initial session-level attributes. Injected as `data.attributes`
    /// on `POST /session/start`. Encoded to a JSON string via
    /// `JSONSerialization` before crossing the native boundary; pass
    /// any valid top-level JSON object.
    public let attributes: [String: Any]?
    public let chatCachePolicy: ChatCachePolicy

    public init(
        endpoint: String,
        token: String? = nil,
        userId: String? = nil,
        attributes: [String: Any]? = nil,
        chatCachePolicy: ChatCachePolicy = .enabled
    ) {
        self.endpoint = endpoint
        self.token = token
        self.userId = userId
        self.attributes = attributes
        self.chatCachePolicy = chatCachePolicy
    }
}

/// Options for `OrigonClient.startCall`.
public struct StartCallOptions: Sendable {
    /// Existing session id to resume; `nil` for a new session.
    public let sessionId: String?
    /// Optional consumer-defined raw JSON forwarded as `data` on the wire.
    public let data: String?

    /// Raw-JSON initializer. Use this when `data` is already a JSON
    /// string (or `nil` to omit it).
    public init(sessionId: String? = nil, data: String? = nil) {
        self.sessionId = sessionId
        self.data = data
    }

    /// Convenience initializer that accepts any `Encodable` value
    /// (e.g. `[String: String]` or a typed struct) and serializes it
    /// to JSON before forwarding. If encoding fails, `data` is set to
    /// `nil` — the call still proceeds, just without the optional payload.
    public init<T: Encodable>(sessionId: String? = nil, data: T) {
        self.sessionId = sessionId
        if let bytes = try? JSONEncoder().encode(data) {
            self.data = String(data: bytes, encoding: .utf8)
        } else {
            self.data = nil
        }
    }
}

/// Options for `OrigonClient.startChat`.
///
/// `firstMessage` is REQUIRED, and that is the whole point of the split from
/// the old `startSession`. The server runs a two-stage gate on every chat:
/// the flow does not start until the visitor has actually said something, and
/// a session that stays silent past the deadline is reaped. An API that
/// opened a session and then waited for a human to type was racing that
/// deadline; carrying the message here makes the race unreachable.
///
/// Attachment-only is valid — the gate fires on ANY visitor content.
public struct StartChatOptions: Sendable {
    /// The visitor's first message. Required.
    public let firstMessage: SendMessagePayload
    /// Existing session id to resume; `nil` for a new session.
    public let sessionId: String?
    /// Optional consumer-defined raw JSON forwarded as `data` on the wire.
    public let data: String?

    public init(
        firstMessage: SendMessagePayload,
        sessionId: String? = nil,
        data: String? = nil
    ) {
        self.firstMessage = firstMessage
        self.sessionId = sessionId
        self.data = data
    }

    public init<T: Encodable>(
        firstMessage: SendMessagePayload,
        sessionId: String? = nil,
        data: T
    ) {
        self.firstMessage = firstMessage
        self.sessionId = sessionId
        if let bytes = try? JSONEncoder().encode(data) {
            self.data = String(data: bytes, encoding: .utf8)
        } else {
            self.data = nil
        }
    }
}

/// Response from `OrigonClient.startCall` / `startChat`.
public struct StartSessionResponse: Sendable {
    public let sessionId: String
    public let url: String
    /// Per-session auth token, scoped to this session only.
    public let token: String

    public init(sessionId: String, url: String, token: String) {
        self.sessionId = sessionId
        self.url = url
        self.token = token
    }
}

/// Input for `OrigonClient.joinCall` / `OrigonClient.joinChat` — a
/// previously-obtained `StartSessionResponse`. No channel: the method
/// carries it.
public struct JoinInput: Sendable {
    public let sessionId: String
    public let url: String
    public let token: String

    public init(sessionId: String, url: String, token: String) {
        self.sessionId = sessionId
        self.url = url
        self.token = token
    }
}

/// Snapshot entry returned by `OrigonClient.activeSessions`.
public struct ActiveSession: Sendable {
    public let sessionId: String
    public let channel: Channel

    public init(sessionId: String, channel: Channel) {
        self.sessionId = sessionId
        self.channel = channel
    }
}

// MARK: - Server config

public struct AttachmentRule: Codable, Sendable, Equatable {
    public let enabled: Bool
    /// Maximum allowed size in megabytes.
    public let maxSize: UInt32

    public init(enabled: Bool, maxSize: UInt32) {
        self.enabled = enabled
        self.maxSize = maxSize
    }
}

public struct AttachmentPolicy: Codable, Sendable, Equatable {
    public let images: AttachmentRule
    public let documents: AttachmentRule
    public let videos: AttachmentRule
    public let audio: AttachmentRule

    public init(
        images: AttachmentRule,
        documents: AttachmentRule,
        videos: AttachmentRule,
        audio: AttachmentRule
    ) {
        self.images = images
        self.documents = documents
        self.videos = videos
        self.audio = audio
    }

    /// Fallback returned when the native layer refuses to hand back the
    /// policy. All categories disabled, zero size.
    public static let disabled = AttachmentPolicy(
        images: AttachmentRule(enabled: false, maxSize: 0),
        documents: AttachmentRule(enabled: false, maxSize: 0),
        videos: AttachmentRule(enabled: false, maxSize: 0),
        audio: AttachmentRule(enabled: false, maxSize: 0)
    )
}

/// Tenant configuration returned by `GET /config` at connect time.
public struct ServerConfig: Codable, Sendable, Equatable {
    public let startMessage: String
    public let multipleChannels: Bool
    public let isChatEnabled: Bool
    public let isCallEnabled: Bool
    public let attachmentPolicy: AttachmentPolicy

    public init(
        startMessage: String,
        multipleChannels: Bool,
        isChatEnabled: Bool,
        isCallEnabled: Bool,
        attachmentPolicy: AttachmentPolicy
    ) {
        self.startMessage = startMessage
        self.multipleChannels = multipleChannels
        self.isChatEnabled = isChatEnabled
        self.isCallEnabled = isCallEnabled
        self.attachmentPolicy = attachmentPolicy
    }

    public static let disabled = ServerConfig(
        startMessage: "",
        multipleChannels: false,
        isChatEnabled: false,
        isCallEnabled: false,
        attachmentPolicy: .disabled
    )

    private enum CodingKeys: String, CodingKey {
        case startMessage
        case multipleChannels
        case isChatEnabled = "chatEnabled"
        case isCallEnabled = "callEnabled"
        case attachmentPolicy
    }
}

/// One cache or network generation of the endpoint configuration.
public struct ServerConfigLoadSnapshot: Codable, Sendable, Equatable {
    public let source: SessionLoadSource
    public let authoritative: Bool
    public let refreshedAt: UInt64
    public let config: ServerConfig
}

/// Retained cache-first `/config` observation. A transient refresh error may
/// follow a cached snapshot; terminal scope failures are delivered here after
/// the native snapshot getter has been revoked.
public enum ServerConfigLoadUpdate: Sendable {
    case snapshot(ServerConfigLoadSnapshot)
    case refreshFailed(error: OrigonError, cachedSnapshotEmitted: Bool)
}

// MARK: - Session history

/// Uploaded media descriptor. Surfaced on `Message.attachments` and
/// passed back into `SendMessagePayload.attachments`.
///
/// Set `localUrl` to a local preview source (e.g. `file://` to a cached
/// pick) before `sendMessage`; the SDK echoes it back on
/// `MessageUpdated` without leaking it to the wire. See
/// `client-sdk/session/docs/contract.md#attachment-flow`.
public struct Attachment: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let contentType: String
    public let url: String
    public let localUrl: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case contentType
        case url
        case localUrl
    }

    public init(
        id: String = "",
        name: String = "",
        contentType: String = "",
        url: String = "",
        localUrl: String? = nil
    ) {
        self.id = id
        self.name = name
        self.contentType = contentType
        self.url = url
        self.localUrl = localUrl
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        self.name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.contentType = try c.decodeIfPresent(String.self, forKey: .contentType) ?? ""
        self.url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        self.localUrl = try c.decodeIfPresent(String.self, forKey: .localUrl)
    }

    /// Custom encoder so `localUrl: null` is omitted rather than
    /// written when `nil`. Swift's synthesised encoder doesn't match
    /// `encodeIfPresent` for an `Optional` `let`.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(contentType, forKey: .contentType)
        try c.encode(url, forKey: .url)
        try c.encodeIfPresent(localUrl, forKey: .localUrl)
    }
}

/// Progress notification surfaced from
/// `OrigonClient.uploadAttachment`. `totalBytes` is `nil` when the
/// payload length is unknown (chunked / streaming sources); `percent`
/// is computed by the SDK when `totalBytes` is known and non-zero.
public struct UploadProgress: Codable, Sendable, Equatable {
    public let bytesUploaded: UInt64
    public let totalBytes: UInt64?
    public let percent: UInt8?

    public init(bytesUploaded: UInt64, totalBytes: UInt64?, percent: UInt8?) {
        self.bytesUploaded = bytesUploaded
        self.totalBytes = totalBytes
        self.percent = percent
    }
}

/// One transcript line / message. Mirrors the Rust `Message` shape.
///
/// For outbound sends the SDK fires `MessageAdded` with a provisional
/// `Message(id: "", localId: <uuid>, status: .sending, ...)` before
/// the wire round-trip. The server-issued `id` lands on the follow-up
/// `MessageUpdated`. The stable lookup key during the sending phase is
/// `localId`; once delivered, both `id` and `localId` are populated.
/// One option on an interactive flow prompt — `Message.buttons`, or a
/// gallery card's own button stack.
///
/// The visitor answers by sending `SendMessagePayload.value` set to this
/// option's `value`. The server matches on **`value`**, never on `label`.
public struct MessageButton: Codable, Sendable, Equatable {
    /// The caption to render. Wire key `label` on this lane — the platform
    /// GraphQL read spells the same field `text`, so shapes from that
    /// source are not interchangeable with these.
    public let label: String
    /// The match key sent back in `SendMessagePayload.value`.
    public let value: String
    /// Authored kind — `"text"` / `"postback"` / `"url"`. A free string,
    /// not an enum: an unknown kind must degrade, not fail to decode.
    public let buttonType: String

    /// `buttonType` rides the wire key **`type`**. Without this mapping it
    /// would encode as `buttonType` and decode to empty, silently turning
    /// every URL button into a plain postback.
    private enum CodingKeys: String, CodingKey {
        case label
        case value
        case buttonType = "type"
    }

    public init(label: String = "", value: String = "", buttonType: String = "") {
        self.label = label
        self.value = value
        self.buttonType = buttonType
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        self.value = try c.decodeIfPresent(String.self, forKey: .value) ?? ""
        self.buttonType = try c.decodeIfPresent(String.self, forKey: .buttonType) ?? ""
    }
}

/// One card in a `Message.gallery` carousel.
public struct MessageCard: Codable, Sendable, Equatable {
    /// Card heading. Doubles as the gallery match key — a reply sends it as
    /// `SendMessagePayload.galleryLabel`.
    public let title: String
    public let description: String
    /// **Optional, and legitimately so** — the server emits `null` for a
    /// card authored without an image. Unwrap it before rendering; a card
    /// with no image is valid, not malformed.
    public let image: Attachment?
    /// This card's own options, same shape as the top-level array.
    public let buttons: [MessageButton]

    public init(
        title: String = "",
        description: String = "",
        image: Attachment? = nil,
        buttons: [MessageButton] = []
    ) {
        self.title = title
        self.description = description
        self.image = image
        self.buttons = buttons
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        self.description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        self.image = try c.decodeIfPresent(Attachment.self, forKey: .image)
        self.buttons = try c.decodeIfPresent([MessageButton].self, forKey: .buttons) ?? []
    }
}

public struct Message: Codable, Sendable, Equatable {
    public let role: MessageRole
    public let id: String
    public let localId: String?
    public let text: String?
    public let html: String?
    public let timestamp: String?
    public let userId: String?
    public let userName: String?
    /// Lifecycle action for a `role: .system` row: `"queued"` | `"joined"`
    /// | `"ended"`. Set by connect on lifecycle system messages; absent on
    /// ordinary messages and on flow-bot `.system` messages (which keep
    /// bubble rendering — the divider discriminator is action-presence, not
    /// role). The label is connect's server-formatted `text` ("Bo has
    /// joined", "Conversation has ended", the queue line), rendered verbatim.
    /// Mirrors the SDK `Message.action` passthrough (wire key `action`).
    public let action: String?
    public let attachments: [Attachment]
    /// Interactive prompt options on a flow-authored `.system` row. Empty
    /// on every ordinary message — a non-empty array is what makes this
    /// message a prompt. Note a prompt carries NO `action`, so it must stay
    /// on the bubble branch, not the lifecycle-divider branch.
    public let buttons: [MessageButton]
    /// Gallery-card carousel on a flow-authored `.system` row — the
    /// card-shaped sibling of `buttons`. Empty on ordinary messages.
    public let gallery: [MessageCard]
    public let errorText: String?
    public let status: MessageStatus
    public let state: MessageState
    /// Optional server/client delivery classification.
    public let metadata: MessageMetadata?

    public init(
        role: MessageRole = .external,
        id: String,
        localId: String? = nil,
        text: String? = nil,
        html: String? = nil,
        timestamp: String? = nil,
        userId: String? = nil,
        userName: String? = nil,
        action: String? = nil,
        attachments: [Attachment] = [],
        buttons: [MessageButton] = [],
        gallery: [MessageCard] = [],
        errorText: String? = nil,
        status: MessageStatus = .delivered,
        state: MessageState = .completed,
        metadata: MessageMetadata? = nil
    ) {
        self.role = role
        self.id = id
        self.localId = localId
        self.text = text
        self.html = html
        self.timestamp = timestamp
        self.userId = userId
        self.userName = userName
        self.action = action
        self.attachments = attachments
        self.buttons = buttons
        self.gallery = gallery
        self.errorText = errorText
        self.status = status
        self.state = state
        self.metadata = metadata
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.role = try c.decodeIfPresent(MessageRole.self, forKey: .role) ?? .external
        self.id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        self.localId = try c.decodeIfPresent(String.self, forKey: .localId)
        self.text = try c.decodeIfPresent(String.self, forKey: .text)
        self.html = try c.decodeIfPresent(String.self, forKey: .html)
        self.timestamp = try c.decodeIfPresent(String.self, forKey: .timestamp)
        self.userId = try c.decodeIfPresent(String.self, forKey: .userId)
        self.userName = try c.decodeIfPresent(String.self, forKey: .userName)
        self.action = try c.decodeIfPresent(String.self, forKey: .action)
        self.attachments = try c.decodeIfPresent([Attachment].self, forKey: .attachments) ?? []
        self.buttons = try c.decodeIfPresent([MessageButton].self, forKey: .buttons) ?? []
        self.gallery = try c.decodeIfPresent([MessageCard].self, forKey: .gallery) ?? []
        self.errorText = try c.decodeIfPresent(String.self, forKey: .errorText)
        self.status = try c.decodeIfPresent(MessageStatus.self, forKey: .status) ?? .delivered
        self.state = try c.decodeIfPresent(MessageState.self, forKey: .state) ?? .completed
        self.metadata = try c.decodeIfPresent(MessageMetadata.self, forKey: .metadata)
    }
}

/// Payload for `OrigonClient.sendMessage`. Mirrors the Rust
/// `SendMessagePayload` shape (wire keys camelCase).
public struct SendMessagePayload: Codable, Sendable {
    public let text: String?
    public let html: String?
    public let attachments: [Attachment]
    /// The chosen `MessageButton.value` when this send answers an
    /// interactive prompt. The server matches a button on this, falling
    /// back to `text` — so `text` must ALSO be set (to the option's label):
    /// a body with no `text`/`html`/`attachments` is refused with a 400
    /// before the flow ever sees it.
    public let value: String?
    /// The picked `MessageCard.title` when answering a gallery prompt. The
    /// server matches a gallery pick on the PAIR `(galleryLabel, value)`,
    /// which is what disambiguates two cards sharing a button value. Leave
    /// nil for a plain button reply.
    public let galleryLabel: String?
    /// Optional participant/monitor audience metadata.
    public let metadata: MessageMetadata?

    /// Both prompt keys are `Optional`, so Swift's synthesised encoder
    /// omits them when nil — an ordinary message carries neither key.
    public init(
        text: String? = nil,
        html: String? = nil,
        attachments: [Attachment] = [],
        value: String? = nil,
        galleryLabel: String? = nil,
        metadata: MessageMetadata? = nil
    ) {
        self.text = text
        self.html = html
        self.attachments = attachments
        self.value = value
        self.galleryLabel = galleryLabel
        self.metadata = metadata
    }
}

public struct Contact: Codable, Sendable, Equatable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// Element of a session-directory snapshot.
public struct SessionSummary: Codable, Sendable {
    public let sessionId: String
    public let subject: String
    public let channel: Channel
    /// Live only on the cx owner that served this directory row.
    public let active: Bool
    public let createdAt: String
    public let updatedAt: String
    public let lastMessage: Message?
    public let contact: Contact?

    public init(
        sessionId: String,
        subject: String,
        channel: Channel,
        active: Bool,
        createdAt: String,
        updatedAt: String,
        lastMessage: Message? = nil,
        contact: Contact? = nil
    ) {
        self.sessionId = sessionId
        self.subject = subject
        self.channel = channel
        self.active = active
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastMessage = lastMessage
        self.contact = contact
    }
}

public enum RestoreStatus: Int32, Sendable {
    case connected = 0
    case alreadyConnected = 1
    case activeElsewhere = 2
    case noLongerActive = 3
    case failed = 4
}

/// One passive restore outcome. A failure for one retained chat does not fail
/// the other rows in the report.
public struct RestoreResult: Sendable {
    public let sessionId: String
    public let status: RestoreStatus
    public let error: String?

    public init(sessionId: String, status: RestoreStatus, error: String? = nil) {
        self.sessionId = sessionId
        self.status = status
        self.error = error
    }
}

/// Authoritative transcript history carried by a session snapshot.
public struct SessionHistory: Codable, Sendable {
    public let history: [Message]
    /// Who is currently driving the session.
    public let control: SessionControl

    public init(history: [Message] = [], control: SessionControl = .ai) {
        self.history = history
        self.control = control
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.history = try c.decodeIfPresent([Message].self, forKey: .history) ?? []
        self.control = try c.decodeIfPresent(SessionControl.self, forKey: .control) ?? .ai
    }
}

public struct SessionSnapshot: Codable, Sendable {
    public let source: SessionLoadSource
    public let authoritative: Bool
    public let refreshedAt: UInt64
    public let session: SessionHistory
}

public struct SessionDirectorySnapshot: Codable, Sendable {
    public let source: SessionLoadSource
    public let authoritative: Bool
    public let refreshedAt: UInt64
    public let sessions: [SessionSummary]
}

public let sessionPageEmptyContinuationLimit = 8

public enum SessionPageLoadPhase: Sendable {
    case initial
    case continuation
}

public struct SessionDirectoryPageRequest: Sendable {
    public let pageSize: Int32
    public let cursor: String?
    public let search: String?

    public init(pageSize: Int32 = 50, cursor: String? = nil, search: String? = nil) {
        self.pageSize = pageSize
        self.cursor = cursor
        self.search = search
    }

    public var phase: SessionPageLoadPhase { cursor == nil ? .initial : .continuation }
}

public struct SessionHistoryPageRequest: Sendable {
    public let pageSize: Int32
    public let cursor: String?

    public init(pageSize: Int32 = 100, cursor: String? = nil) {
        self.pageSize = pageSize
        self.cursor = cursor
    }

    public var phase: SessionPageLoadPhase { cursor == nil ? .initial : .continuation }
}

public struct SessionDirectoryPage: Codable, Sendable {
    public let sessions: [SessionSummary]
    public let nextCursor: String?

    public init(sessions: [SessionSummary], nextCursor: String?) {
        self.sessions = sessions
        self.nextCursor = nextCursor
    }

    private enum CodingKeys: String, CodingKey { case sessions, nextCursor }

    public init(from decoder: Decoder) throws {
        try requireExactKeys(decoder, expected: ["sessions", "nextCursor"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessions = try container.decode([SessionSummary].self, forKey: .sessions)
        nextCursor = try container.decode(String?.self, forKey: .nextCursor)
    }
}

public struct SessionHistoryPage: Codable, Sendable {
    public let history: [Message]
    public let control: SessionControl
    public let nextCursor: String?

    public init(history: [Message], control: SessionControl, nextCursor: String?) {
        self.history = history
        self.control = control
        self.nextCursor = nextCursor
    }

    private enum CodingKeys: String, CodingKey { case history, control, nextCursor }

    public init(from decoder: Decoder) throws {
        try requireExactKeys(decoder, expected: ["history", "control", "nextCursor"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        history = try container.decode([Message].self, forKey: .history)
        control = try container.decode(SessionControl.self, forKey: .control)
        nextCursor = try container.decode(String?.self, forKey: .nextCursor)
    }
}

public enum SessionDirectoryPageLoadUpdate: Sendable {
    case page(SessionDirectoryPage)
    case failed(error: OrigonError, phase: SessionPageLoadPhase)
}

public enum SessionHistoryPageLoadUpdate: Sendable {
    case page(SessionHistoryPage)
    case failed(error: OrigonError, phase: SessionPageLoadPhase)
}

public struct SessionDirectoryPageSnapshot: Sendable {
    public let generation: UInt64
    public let search: String?
    public let sessions: [SessionSummary]
    public let nextCursor: String?
    public let emptyContinuations: Int

    public var canLoadMore: Bool {
        nextCursor != nil && emptyContinuations < sessionPageEmptyContinuationLimit
    }
}

public struct SessionHistoryPageSnapshot: Sendable {
    public let generation: UInt64
    public let history: [Message]
    public let control: SessionControl
    public let nextCursor: String?
    public let emptyContinuations: Int

    public var canLoadMore: Bool {
        nextCursor != nil && emptyContinuations < sessionPageEmptyContinuationLimit
    }
}

private struct AnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private func requireExactKeys(_ decoder: Decoder, expected: Set<String>) throws {
    let container = try decoder.container(keyedBy: AnyCodingKey.self)
    let actual = Set(container.allKeys.map(\.stringValue))
    guard actual == expected else {
        throw DecodingError.dataCorrupted(
            .init(codingPath: decoder.codingPath, debugDescription: "Unexpected page envelope keys")
        )
    }
}

public enum SessionLoadUpdate: Sendable {
    case snapshot(SessionSnapshot)
    case refreshFailed(error: OrigonError, cachedSnapshotEmitted: Bool)
}

public enum SessionDirectoryLoadUpdate: Sendable {
    case snapshot(SessionDirectorySnapshot)
    case refreshFailed(error: OrigonError, cachedSnapshotEmitted: Bool)
}

// MARK: - Disconnect reason

public enum DisconnectReason: Sendable, Equatable {
    case localClose
    case networkLoss
    case endpointNotProvisioned
    case endpointAlreadyConnected
    case tokenInvalid
    case tokenExpired
    case tokenReplayed
    case protocolViolation
    case capabilityMissing
    case illegalState
    case resourceExhausted
    case replayLost
    /// `0x1040` — server closed the session cleanly because the bridge
    /// collapsed (remote SIP leg hung up, or the engine drained the
    /// call). Terminal: no reconnect attempts follow.
    case sessionEnded
    case serverClosed(code: UInt64, detail: String?)
    /// Local transport failed before the MOQ session was established
    /// (QUIC dial / DNS / TLS / etc.). `detail` carries the underlying
    /// error message for diagnostics.
    case transportClosed(detail: String?)
}

// MARK: - After-call work

/// After-Call-Work offer carried on a chat ``ClientEvent/chatSessionEnded``
/// event for an **agent** participant (the wrap-up window). Absent for the
/// visitor / widget side, which receives `reason` alone. Mirrors connect's
/// chat `sessionEnded.acw` block one-for-one.
///
/// Producer: `platform/connect` chat SSE encoder
/// (`services/http/chat/sse.rs`, `ServerEvent::SessionEnded`).
public struct Acw: Codable, Sendable, Equatable {
    /// Always `true` when the block is present — its presence is the signal.
    public let enabled: Bool
    /// Wrap-up window in seconds. `0` ⇒ open-ended server-side.
    public let duration: UInt64
    /// The agent cannot finish wrap-up without a disposition. Wire key is
    /// `enforce` (not `enforced`).
    public let enforce: Bool
    /// RFC3339 instant the agent entered ACW.
    public let startedAt: String?
    /// The team's disposition tags — the pickable wrap-up chips.
    public let dispositions: [String]

    public init(
        enabled: Bool = false,
        duration: UInt64 = 0,
        enforce: Bool = false,
        startedAt: String? = nil,
        dispositions: [String] = []
    ) {
        self.enabled = enabled
        self.duration = duration
        self.enforce = enforce
        self.startedAt = startedAt
        self.dispositions = dispositions
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        self.duration = try c.decodeIfPresent(UInt64.self, forKey: .duration) ?? 0
        self.enforce = try c.decodeIfPresent(Bool.self, forKey: .enforce) ?? false
        self.startedAt = try c.decodeIfPresent(String.self, forKey: .startedAt)
        self.dispositions = try c.decodeIfPresent([String].self, forKey: .dispositions) ?? []
    }
}

// MARK: - Events

/// Async event from a session. All variants carry `sessionId` so the
/// consumer can demultiplex when several sessions are active at once.
public enum ClientEvent: Sendable {
    /// A message was appended to the transcript — outbound provisional
    /// (`status == .sending`), inbound peer message, or future AI
    /// message. Store under the key `message.localId ?? message.id`
    /// so `.messageUpdated` can find it.
    case messageAdded(sessionId: String, message: Message)
    /// A previously-added message was updated. `id` matches the lookup
    /// key the consumer used when the row was added — equal to the
    /// provisional's `localId` for outbound ack / failure, or
    /// `message.id` for server-driven updates. Always non-empty.
    case messageUpdated(sessionId: String, id: String, message: Message)
    case sessionUpdated(sessionId: String, newSessionId: String)
    case controlUpdated(sessionId: String, control: SessionControl)
    case typing(sessionId: String, state: TypingState)
    case connected(sessionId: String)
    case reconnecting(sessionId: String, attempt: UInt32, reason: DisconnectReason)
    case reconnected(sessionId: String)
    case peerAttached(sessionId: String, peerEndpointId: String, alias: UInt64)
    case peerDetached(sessionId: String, peerEndpointId: String, alias: UInt64)
    case disconnected(sessionId: String, reason: DisconnectReason)
    /// Voice-side soft error. `message == nil` means a previously-
    /// surfaced error has cleared.
    case callError(sessionId: String, message: String?)
    /// The audio output route changed — the app's `setAudioOutput` choice or
    /// an OS-driven change (e.g. a headset plugged in mid-call). Drive a
    /// speaker toggle from `route == .speaker`.
    case audioRouteChanged(sessionId: String, route: AudioOutputRoute)
    /// A chat session ended cleanly — the agent or flow explicitly closed it.
    /// Distinct from ``disconnected(sessionId:reason:)``: the SDK emits this
    /// and then stops the chat actor WITHOUT a trailing `.disconnected`, so a
    /// consumer renders a clean end (no "disconnected" toast). `reason` is
    /// connect's end reason; `acw` (after-call-work) rides only an agent
    /// participant's stream — the visitor / widget side receives `nil`.
    case chatSessionEnded(sessionId: String, reason: String, acw: Acw?)

    public var sessionId: String {
        switch self {
        case .messageAdded(let s, _),
             .messageUpdated(let s, _, _),
             .sessionUpdated(let s, _),
             .controlUpdated(let s, _),
             .typing(let s, _),
             .connected(let s),
             .reconnecting(let s, _, _),
             .reconnected(let s),
             .peerAttached(let s, _, _),
             .peerDetached(let s, _, _),
             .disconnected(let s, _),
             .callError(let s, _),
             .audioRouteChanged(let s, _),
             .chatSessionEnded(let s, _, _):
            return s
        }
    }
}

// MARK: - Errors

/// Structured error thrown by `OrigonClient`. Mirrors the Rust
/// `ClientError` discriminants — dispatch on `kind` for typed handling,
/// or read `message` / `code` for display.
public struct OrigonError: Error, Sendable, CustomStringConvertible, LocalizedError {
    public let kind: Kind
    /// HTTP status when applicable (`.http` / `.serverUnavailable`); 0 otherwise.
    public let statusCode: Int
    /// Machine-readable code (e.g. `"user_unavailable"`) or field name (`.missingField`).
    public let code: String?
    public let message: String?

    public enum Kind: Int, Sendable {
        case unknown = 0
        case notInitialized = 1
        case noSession = 2
        case session = 3
        case missingField = 4
        case serverUnavailable = 5
        case http = 6
        case attachment = 7
        case other = 8
        /// Upload was cancelled via `deleteAttachment(attachmentId:)`
        /// using the same `uploadId` passed to `uploadAttachment`. Only
        /// surfaced from `uploadAttachment`. See its doc for the pattern.
        case cancelled = 9
    }

    public init(kind: Kind, statusCode: Int = 0, code: String? = nil, message: String? = nil) {
        self.kind = kind
        self.statusCode = statusCode
        self.code = code
        self.message = message
    }

    public var description: String {
        if let message, !message.isEmpty { return message }
        if let code, !code.isEmpty { return code }
        return "OrigonError(kind: \(kind))"
    }

    /// `LocalizedError` conformance — makes `error.localizedDescription`
    /// surface the server-supplied message instead of Swift's generic
    /// fallback. Mirrors ``description`` so consumers see the same text
    /// whether they read `\(error)`, `error.description`, or
    /// `error.localizedDescription`.
    public var errorDescription: String? { description }

    public static let notInitialized = OrigonError(
        kind: .notInitialized,
        message: "Client is not initialized"
    )
}
