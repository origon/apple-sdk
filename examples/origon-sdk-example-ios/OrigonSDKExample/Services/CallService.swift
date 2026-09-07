import Foundation
import Combine
import OrigonSDK

/// Voice call state machine. Owns the *active* voice session id (one at
/// a time) and reflects its lifecycle into UI-friendly state. Consumes
/// `SDKManager` for the underlying client and event stream — does not
/// own either.
@MainActor
final class CallService: ObservableObject {

    enum Phase: Equatable {
        case idle
        case connecting
        case connected
        case reconnecting
        /// Optional reason for display. `nil` = user-initiated end.
        case ended(String?)
    }

    @Published var phase: Phase = .idle
    @Published var muted = false
    /// Whether call audio is routed to the loudspeaker. Driven by the SDK's
    /// `ClientEvent.audioRouteChanged` (our own `setSpeaker` and OS-driven route
    /// changes alike), so it never goes stale. Reset to `false` on each new call.
    @Published var speakerOn = false
    /// Soft errors surfaced via `ClientEvent.callError` while a call is
    /// up. `nil` = no error / cleared.
    @Published var lastError: String?

    private(set) var sessionId: String?

    private weak var sdk: SDKManager?
    private var cancellables = Set<AnyCancellable>()

    /// SDKManager creates this and calls `bind(to:)` once it can pass `self`.
    /// Subscribes to the manager's event stream so phase updates flow in
    /// from the moment the service is wired up.
    func bind(to manager: SDKManager) {
        self.sdk = manager
        manager.events
            .sink { [weak self] event in
                self?.handleEvent(event)
            }
            .store(in: &cancellables)
    }

    // MARK: - Voice call lifecycle

    /// Open a voice session. Phase moves `.idle` → `.connecting`
    /// synchronously, then `.connected` once the SDK fires `.connected`
    /// for our session id.
    func startCall() async throws {
        guard let sdk, sdk.hasAuthoritativeConfig else {
            throw OrigonError(kind: .other, message: "Endpoint configuration is still refreshing")
        }
        guard let client = sdk.client else { throw OrigonError.notInitialized }

        phase = .connecting
        lastError = nil
        muted = false
        speakerOn = false
        do {
            // `startCall` blocks on the FFI runtime (HTTP + QUIC dial).
            // Hop off the main actor so SwiftUI commits the `.connecting`
            // change and renders the loading state before we block;
            // otherwise the whole sync call happens in one main-thread
            // tick and SwiftUI only ever renders the final phase.
            let response = try await Task.detached {
                try client.startCall(StartCallOptions())
            }.value
            sessionId = response.sessionId
        } catch {
            // The synchronous throw fires when `startCall` fails to
            // dial the transport (e.g. TLS / DNS / QUIC). The SDK also
            // emits a `Disconnected(TransportClosed)` event for the
            // same failure, but it's dropped by `handleEvent` because
            // `sessionId` was never assigned. Surface the error here
            // so the UI moves off `.connecting`.
            let message = (error as? OrigonError)?.message
                ?? error.localizedDescription
            phase = .ended(message)
            throw error
        }
    }

    /// Absolute mute setter. Updates local UI state on success; surfaces
    /// failure via `lastError` rather than throwing — mute toggles
    /// shouldn't block a live call.
    func setMute(_ value: Bool) {
        guard let client = sdk?.client, let id = sessionId else { return }
        do {
            try client.setMute(id: id, muted: value)
            muted = value
        } catch let e as OrigonError {
            lastError = e.message ?? "Failed to update mute"
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Route call audio to the loudspeaker (`true`) or back to the default
    /// route — receiver / headset / Bluetooth (`false`). Process-global, so it
    /// needs no session id. Updates `speakerOn` optimistically for the explicit
    /// toggle; OS-driven changes (e.g. a headset plugged in) arrive separately
    /// via `audioRouteChanged`. Surfaces failure via `lastError` rather than
    /// throwing — a routing toggle shouldn't block a live call.
    func setSpeaker(_ on: Bool) {
        guard let client = sdk?.client else { return }
        do {
            try client.setAudioOutput(on ? .speaker : .automatic)
            speakerOn = on
        } catch let e as OrigonError {
            lastError = e.message ?? "Failed to switch speaker"
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// User-initiated end. The SDK will fire `.disconnected(.localClose)`
    /// shortly afterward; we don't wait for it — flip phase immediately
    /// so the UI dismisses without a hang.
    func endCall() {
        guard let client = sdk?.client, let id = sessionId else {
            phase = .ended(nil)
            return
        }
        try? client.endSession(id)
        sessionId = nil
        phase = .ended(nil)
    }

    // MARK: - Event handling

    private func handleEvent(_ event: ClientEvent) {
        // Ignore events for sessions we don't own (e.g. stragglers from
        // a prior call, or another session type we don't track).
        guard let active = sessionId, event.sessionId == active else { return }

        switch event {
        case .connected:
            phase = .connected

        case .reconnecting:
            phase = .reconnecting

        case .reconnected:
            phase = .connected

        case .disconnected(_, let reason):
            phase = .ended(disconnectReasonText(reason))
            sessionId = nil

        case .callError(_, let message):
            // Soft error — surface but don't tear the call down.
            lastError = message

        case .audioRouteChanged(_, let route):
            // SDK is the source of truth for the route: fires for our own
            // setSpeaker and for OS-driven changes (headset plug), so the
            // toggle never goes stale.
            speakerOn = route == .speaker

        // Voice-irrelevant events on a voice session — ignore. Chat
        // plane events (`messageAdded` / `messageUpdated`) are owned by
        // `ChatService`; we drop them here as a safety net in case a
        // voice session id ever shows up on a chat event.
        case .controlUpdated, .typing, .sessionUpdated,
             .peerAttached, .peerDetached,
             .messageAdded, .messageUpdated,
             .chatSessionEnded:
            break
        }
    }

    /// Map a structured `DisconnectReason` to short text for the
    /// CallView error row. `nil` for clean local closes — the UI
    /// dismisses without showing anything.
    private func disconnectReasonText(_ reason: DisconnectReason) -> String? {
        switch reason {
        case .localClose:
            return nil
        case .sessionEnded:
            return nil
        case .networkLoss:
            return "Network connection lost"
        case .tokenInvalid, .tokenExpired, .tokenReplayed:
            return "Session expired"
        case .endpointNotProvisioned:
            return "Endpoint not provisioned"
        case .endpointAlreadyConnected:
            return "Already connected on another device"
        case .capabilityMissing, .protocolViolation, .illegalState:
            return "Connection error"
        case .resourceExhausted:
            return "Server is at capacity"
        case .replayLost:
            return "Connection lost"
        case .serverClosed(_, let detail):
            return detail ?? "Disconnected"
        case .transportClosed(let detail):
            return detail ?? "Could not connect"
        }
    }
}
