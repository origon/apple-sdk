# OrigonSDK

iOS and macOS SDK for the Origon platform.

## About

The Origon SDK for Apple platforms lets you embed Origon directly in your
iOS and macOS apps: **audio calls**, **chat**, and **session history**.

A basic chat + voice integration takes around 15 minutes; allow a little
longer if you also wire up push notifications or background calls. The SDK
authenticates your app by its **Bundle ID**, which you register once in the
Origon Connect web app (see [Prerequisites](#prerequisites)). At runtime all
you pass is your Origon **endpoint**.

## Features

- **Audio calls** — low-latency voice, with automatic Bluetooth device
  routing.
- **Chat** — messaging with typing indicators and attachments.
- **Push notifications** — wake your app for incoming calls and messages.
- **Session history** — retrieve past sessions and their messages.

## Requirements

- iOS 15.0+
- macOS 13.0+
- Xcode 16+ (includes the Swift 6 package toolchain required by the example's
  exact SwiftSoup dependency)
- Swift 5.9+ for the SDK package; the iOS example remains in Swift 5 language mode

## Prerequisites

Register your app in the Origon Connect web app before the SDK can connect.
Your account owner or admin has access to it. The SDK authenticates each app
by the **Bundle ID** it reports, so that Bundle ID has to be on your tenant's
allow-list first.

1. Sign in to **Origon Connect** at <https://origon.ai/connect>.
2. Go to **Settings → Integrations → Mobile → Setup Mobile SDK**.
3. Fill in your app details — **Company Name**, **logo**, and the
   **routing** rules for your flow (where calls and chats are sent). Press
   **Next**.
4. In the **Deployment** tab, add your app's **Bundle ID** (e.g.
   `com.domain.YourApp`) to the **Bundle IDs** field. It accepts multiple
   entries, so you can register several apps (e.g. staging and production)
   against the same config. To run and test the [sample app](#sample-app),
   add its Bundle ID `origon.example.ios` here as well.
5. Copy the **endpoint** shown in the **Deployment** tab and pass it as the
   `endpoint` in `ClientConfig` when you initialize `OrigonClient` (see
   [Quick Start](#quick-start)).
6. **Save** the config.

Your Bundle ID is the target's **Bundle Identifier** under Xcode's
**General → Identity**; it must match exactly what the app reports at
runtime.

## Installation

Add the package to your `Package.swift` or through Xcode's package manager:

```swift
dependencies: [
    .package(url: "https://github.com/Origon/apple-sdk", from: "0.3.4"),
]
```

Then add `OrigonSDK` to your target's dependencies:

```swift
.target(
    name: "YourApp",
    dependencies: [
        .product(name: "OrigonSDK", package: "apple-sdk"),
    ]
),
```

The pre-built `COrigonSDK` XCFramework is downloaded automatically by SPM
from [GitHub Releases](https://github.com/Origon/apple-sdk/releases).

### Validate a local native build

For SDK development, build the native XCFramework from a sibling `workspace`
checkout and run both wrapper and example tests against that exact artifact:

```bash
workspace/apps/sdk/session/scripts/build-xcframework.sh \
  --output apple-sdk/Frameworks
cd apple-sdk
ORIGON_XCFRAMEWORK="$PWD/Frameworks/COrigonSDK.xcframework" \
ORIGON_IOS_TEST_DESTINATION='platform=iOS Simulator,name=iPhone 17 Pro' \
  scripts/test-local-xcframework.sh
```

The script uses a scratch checkout, rewrites only that checkout to the local
binary target, checks current/retired ABI symbols, runs `swift test`, then runs
the example-owned XCTest target. The maintained local rig is Apple Silicon and
therefore exercises the arm64 simulator slice; release packaging still builds
the device, simulator, and macOS slices declared by the XCFramework.

## Sample app

You'll find the Origon SDK for Apple on GitHub
[here](https://github.com/Origon/apple-sdk). The repo also includes a
runnable sample app — a minimal iOS app that integrates chat and voice
calls — under
[`examples/origon-sdk-example-ios`](https://github.com/Origon/apple-sdk/tree/main/examples/origon-sdk-example-ios).
See its [README](https://github.com/Origon/apple-sdk/blob/main/examples/origon-sdk-example-ios/README.md)
for build and run instructions, plus a guide to which files to read first
when wiring the SDK into your own app.

## Host App Configuration

iOS reads permission and capability declarations only from the **main
bundle's** `Info.plist` — keys placed inside an embedded framework are
ignored at runtime. The following entries must be added by the
integrating app.

### Required: microphone permission

Voice sessions request audio recording via `AVAudioSession`. Without
this key the app crashes the first time a call starts.

```xml
<key>NSMicrophoneUsageDescription</key>
<string>Microphone access is required for voice calls.</string>
```

### Optional: background voice calls

If calls must continue while the app is backgrounded (e.g. the user
locks the screen mid-call), declare the `audio` background mode:

```xml
<key>UIBackgroundModes</key>
<array>
    <string>audio</string>
</array>
```

If you integrate with CallKit / PushKit for system call UI, also add
`voip` to the same array.

### Optional: push notifications

To receive push notifications, enable the **Push Notifications**
capability on the app target (adds the `aps-environment` entitlement)
and add the `remote-notification` background mode if you handle silent
pushes:

```xml
<key>UIBackgroundModes</key>
<array>
    <string>remote-notification</string>
</array>
```

The host app owns APNs registration (requesting authorization and
calling `registerForRemoteNotifications()`); the SDK only needs the
resulting device token. See [Push notifications](#push-notifications).

## Quick Start

```swift
import OrigonSDK

// Optional: install Rust-side logging once at app launch.
OrigonClient.initLogging()

// 1. Create the client. `userId` is optional — when omitted, the SDK
//    uses a random, persisted app-install id as an opaque anonymous id.
//    It never uses IDFV or another hardware identifier.
let client = try OrigonClient(config: ClientConfig(
    endpoint: "https://origon.ai/chat/api/<id>",
    userId: "user-123"
))

// Render a cached generation immediately when available, but enable actions
// only after an authoritative network generation arrives.
for try await update in try client.serverConfigUpdates() {
    if case .snapshot(let snapshot) = update {
        render(snapshot.config)
        actionsEnabled = snapshot.authoritative
        if snapshot.authoritative { break }
    }
}

// 2. Start a voice session.
let response = try client.startCall(StartCallOptions())
print("session \(response.sessionId) dialing \(response.url)")

// 3. Drain the event stream.
while true {
    guard let event = client.pollEvent() else {
        try await Task.sleep(nanoseconds: 50_000_000) // 50ms
        continue
    }
    switch event {
    case .connected:                        print("connected")
    case .peerAttached(_, let peerId, _):   print("peer \(peerId)")
    case .audioRouteChanged(_, let route):  speakerOn = route == .speaker
    case .disconnected(_, let reason):      print("disconnected: \(reason)"); return
    default: break
    }
}
```

### Voice controls

```swift
// Mute (per session).
try client.setMute(id: response.sessionId, muted: true)

// Send one DTMF digit to the active CX flow. Valid symbols are 0-9, *, #, A-D.
try client.sendDtmf(id: response.sessionId, digit: "5")

// Observe combined local/remote RMS plus endpoint-attributed inbound levels.
// Retain the token for as long as the UI needs updates; callbacks run on MainActor.
let levelObservation = try client.observeAudioLevels(sessionId: response.sessionId) { levels in
    let displayLevel = min(max(max(levels.outbound, levels.inbound) * 4, 0), 1)
    updateSpeakingWave(displayLevel)
}
// Later: levelObservation.cancel()

// Audio output route — process-global, so no session id. Maps onto
// `AVAudioSession.overrideOutputAudioPort`; the SDK re-asserts the choice
// across reconnects and OS route changes (headset plug/unplug). Resets to
// `.automatic` on each new call.
try client.setAudioOutput(.speaker)     // force the loudspeaker
try client.setAudioOutput(.automatic)   // back to the default route (receiver / wired / Bluetooth)
```

A speaker toggle is typically `client.setAudioOutput(on ? .speaker : .automatic)`.

### Multiple sessions

```swift
let active = try client.activeSessions()
try client.setMuteAll(muted: true)
try client.endAllSessions()
```

### Joining a pre-obtained session

```swift
try client.joinCall(JoinInput(
    sessionId: "...",
    url: "...",
    token: "..."
))
```

### Chat

`sendMessage`, `notifyTyping`, and `stopTyping` all require an active
chat session. **Call `startChat(_:)` with the first message first** —
otherwise these throw `OrigonError(kind: .noSession)`. The same
applies after `endSession(id:)`.

```swift
let started = try client.startChat(StartChatOptions(
    firstMessage: SendMessagePayload(text: "hello")
))
let sessionId = started.sessionId

// Outbound send. The SDK fires `.messageAdded` (status `.sending`)
// before the wire round-trip and `.messageUpdated` (delivered or
// failed) after — both surface on `pollEvent()`. The return value is
// the server-issued Message.
let msg = try client.sendMessage(
    id: sessionId,
    payload: SendMessagePayload(text: "hello", html: "hello")
)

// Typing — call per keystroke. The SDK debounces; only one outbound
// `{state: "on"}` fires per typing burst, and a `{state: "off"}` is
// auto-emitted after ~3 s of no further calls. Fire `stopTyping(id:)`
// explicitly when the input clears (e.g. user deleted all text) to
// snap the peer's "typing…" indicator off instantly.
try client.notifyTyping(id: sessionId)
try client.stopTyping(id: sessionId)
```

### Retained chat continuity

Restore is owned by the SDK's session manager. On foreground/bootstrap, call
the bounded passive restore once; it attaches only rows the server reports as
`active` and never takes over another installation:

```swift
let report = try client.restoreActiveChats()
for result in report where result.status == .activeElsewhere {
    // Keep the row view-only until the user explicitly opens it.
}

// History can render cache immediately while the authoritative refresh runs.
for try await update in try client.sessionUpdates(id: sessionId) {
    if case .snapshot(let snapshot) = update {
        render(snapshot.session.history)
    }
}

// Named authority keeps passive work from accidentally taking over.
_ = try client.openChat(sessionId: sessionId, intent: .explicitNavigation)
```

The host owns app lifecycle triggers; it must not create a second restore loop
or attach the same id independently. An ended chat remains view-only until the
ordinary first-send reopen path runs.

Polling chat events:

```swift
while let event = client.pollEvent() {
    switch event {
    case .messageAdded(let sid, let message):
        // Store under message.localId ?? message.id
    case .messageUpdated(let sid, let id, let message):
        // Look up the row by id (matches the original localId / message.id)
    case .typing(let sid, let state):
        // Render state.participants.first; hide when participants is empty.
    default: break
    }
}
```

### Attachments

Upload a file, then attach the returned `Attachment` to your next
message. **There is no `sessionId:`** — attachments are scoped to the
widget the client was created for, so an attachment can be the first
thing a visitor sends, before any session exists. `uploadAttachment` is
`async` with overloads for a filesystem path, `Data`, or a `URL` (the
`url:` overload manages `startAccessingSecurityScopedResource()` for
`UIDocumentPicker` URLs):

```swift
let attachment = try await client.uploadAttachment(
    url: pickedURL,
    fileName: "photo.jpg"
) { progress in
    // progress.percent is nil when the total size is unknown
    updateProgressBar(progress.percent)
}

try client.sendMessage(
    id: sessionId,
    payload: SendMessagePayload(attachments: [attachment])
)

// Cancel an in-flight upload (pass the uploadId) or delete a completed
// one (pass attachment.id) — the SDK works out which.
try await client.deleteAttachment(attachmentId: attachment.id)
```

Uploads are prechecked against the tenant's `attachmentPolicy` (type and
size); a disallowed file throws `OrigonError` before any bytes are sent.

### Push notifications

Enable Push Notifications for the App ID in the Apple Developer portal and add
the **Push Notifications** capability to the app target so the signed app has
`aps-environment`. Request alert authorization for visible notifications, but
call `registerForRemoteNotifications()` on every launch even when you only need
an updated token; APNs tokens can change after restore, reinstall, or OS changes.
See Apple's [APNs registration guide](https://developer.apple.com/documentation/usernotifications/registering-your-app-with-apns).

Register this device's APNs token so the backend can deliver push
notifications. The host app owns token acquisition — request
authorization and call `registerForRemoteNotifications()`, then forward
the device token to the SDK from your `UIApplicationDelegate`:

```swift
import OrigonSDK
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Required only when a Notification Service Extension shares the
        // endpoint-generation gate with the app.
        OrigonClient.configurePushNotifications(
            appGroupIdentifier: "group.com.example.app"
        )
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
                guard granted else { return }
                DispatchQueue.main.async { application.registerForRemoteNotifications() }
            }
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        // Forward the raw token — the SDK hex-encodes it for the wire.
        OrigonClient.registerForPushNotifications(deviceToken: deviceToken)
    }
}

// On logout:
try client.unregisterPushNotificationsForLogout() // completes before release
```

The static `OrigonClient.unregisterForPushNotifications()` remains the
fire-and-forget convenience. Use the instance method above when logout will
immediately release the client.

`registerForPushNotifications(deviceToken:environment:)` is a **static**
method and is safe to call **before** the client is initialized — the
token is buffered and sent automatically once `OrigonClient` is created.
It is also safe to call repeatedly (e.g. on APNs token refresh); the
latest token wins. The call returns immediately and runs the network
request in the background; failures are logged, not thrown.

Each successful registration persists the opaque server generation. A
Notification Service Extension must compare the incoming
`endpointGeneration` before showing the optional human-agent `title` or
`preview`; use
`OrigonPushNotification.contentForDelivery` as shown in
`examples/notification-service-extension/NotificationService.swift`. On an
exact match, the helper copies each present, nonblank field over the APNs alert.
An absent or blank `title` keeps the APNs title. A stale or missing generation
keeps the original provider/APNs title and body unchanged—the SDK never invents
fallback branding. Foreground delegates may instead suppress the notification
by returning no presentation options when
`OrigonPushNotification.isCurrent(...)` is false. On a matching notification
tap, read `OrigonPushNotification.sessionId(...)` and call
`openChat(sessionId:intent: .notification)`.

Add the Notification Service Extension target to the same App Group configured
above and embed it in the host app. The provider payload must contain an alert
and `mutable-content: 1` for iOS to invoke the extension. The extension must
always call its content handler, including from `serviceExtensionTimeWillExpire`;
if it cannot validate the generation, deliver the original provider alert or
suppress it in app-owned foreground presentation—never promote unverified
`title`/`preview`. Apple's [service-extension guide](https://developer.apple.com/documentation/usernotifications/modifying-content-in-newly-delivered-notifications)
describes the platform timeout and payload requirements.

Call registration on every APNs token refresh. On logout, unregister before
discarding the client and clear delivered notifications in the host app. An
uninstall cannot call logout; APNs invalid-token feedback and the server's
90-day endpoint TTL perform eventual cleanup.

Visible alerts can be delivered while the app is suspended or terminated and a
tap can launch the app; initialize the client, validate the local generation,
then route the `sessionId` with `.notification`. Silent/background updates are
best-effort, may be throttled or coalesced, and are discarded after a force quit,
so never make continuity correctness depend on receiving one. If you use them,
enable **Background Modes → Remote notifications** and refresh authoritative
history after wake. Do not log device tokens, endpoint generations, notification
payloads, installation identifiers, or endpoint query strings; SDK logging is
intended for transport state, not credentials or preview content.

**APNs environment.** A device token is bound to the environment of the
build that produced it (development builds → sandbox; App Store /
TestFlight → production), and the backend must target the matching APNs
host. The SDK auto-detects this from the app's embedded provisioning
profile, so you normally pass nothing. Override only if detection is
wrong:

```swift
OrigonClient.registerForPushNotifications(deviceToken: deviceToken, environment: .sandbox)
```

## API Reference

### OrigonClient

| Method | Description |
| --- | --- |
| `init(config:)` | Create a client. Throws `OrigonError` on connect failure. |
| `pollEvent()` | Non-blocking poll. Returns `nil` when idle. |
| `startCall(_:)` / `startChat(_:)` | Open voice or chat. Chat requires its first message. Returns `(sessionId, url, token)`. |
| `restoreActiveChats()` | Passively attach all retained active chats and return per-id outcomes. |
| `openChat(sessionId:intent:)` | Open a retained chat with named passive, navigation, or notification authority. |
| `sessionUpdates(id:policy:)` | Finite `AsyncThrowingStream`: optional cache snapshot, one network snapshot or typed refresh failure, then completion. |
| `sessionDirectoryUpdates(policy:)` | Cache-first finite directory stream with the same ordering. |
| `sessionDirectoryPageUpdates(request:)` | Finite strict directory/search page stream. Defaults to 50 rows (100 maximum) and reports whether a failure was initial or continuation. |
| `sessionHistoryPageUpdates(id:request:)` | Finite strict chronological transcript page stream. Defaults to 100 rows (250 maximum); continuation pages are older. |
| `cachedSession(s)` / `refreshSession(s)` | Explicit cache-only and authoritative network snapshots. |
| `removeCachedSession(id:)` / `clearChatCache()` / `pruneChatCache()` | Explicit cache maintenance. |
| `close()` / `OrigonClient.clearAllChatCaches()` | Close joins native loaders and cache writers; after all clients close, atomically clear every cached scope. |
| `joinCall(_:)` / `joinChat(_:)` | Attach to a previously-obtained `StartSessionResponse`. |
| `endSession(_:)` / `endAllSessions()` | Close a single / every session. |
| `sendDtmf(id:digit:)` | Voice — send one uppercase ASCII `0-9`, `*`, `#`, or `A-D` control symbol to the CX flow. Produces no local tone or haptic. |
| `observeAudioLevels(sessionId:_:)` | Voice — cancellable MainActor callback carrying aggregate outbound/inbound RMS and endpoint-attributed inbound levels. Retain the returned `AudioLevelObservation`. |
| `setMute(id:muted:)` / `setMuteAll(muted:)` | Voice — absolute mute. |
| `setAudioOutput(_:)` | Voice — override the audio output route (`.speaker` / `.automatic` / `.bluetooth`). Process-global; survives reconnects. |
| `sendMessage(id:payload:)` | Chat — POST `<sessionUrl>/message`. Returns the server-issued `Message`. Fires `.messageAdded` then `.messageUpdated`. |
| `notifyTyping(id:)` | Chat — register a keystroke; SDK debounces outbound `/typing` POSTs. |
| `stopTyping(id:)` | Chat — force outbound typing state to "off" immediately. |
| `uploadAttachment(path:\|data:\|url:)` | `async`; upload a file (`path:` / `data:` / `url:` overloads) against the client's widget and return the server-issued `Attachment`. No session required. Reports progress via `onProgress`. |
| `deleteAttachment(attachmentId:)` | `async`; cancel an in-flight upload (pass the `uploadId`) or delete a completed attachment (pass `attachment.id`). No session required. |
| `activeSessions()` | Snapshot of every active session. |
| `setAttributes(_:)` | Replace session-level attributes injected on the next start. |
| `OrigonClient.registerForPushNotifications(deviceToken:environment:)` | Static. Register an APNs device token (buffered until init; auto-detects environment). |
| `OrigonClient.unregisterForPushNotifications()` | Static. Remove this device's push registration (e.g. on logout). |
| `startMessage` / `isChatEnabled` / `isCallEnabled` / `multipleChannels` / `attachmentPolicy` / `serverConfig` | Cached `/config` getters. |
| `OrigonClient.initLogging(filter:)` | Install Rust-side `tracing` subscriber. |

### Types

| Type | Description |
| --- | --- |
| `ClientConfig` | endpoint, optional `token`, optional `userId`, attributes, and default-on `chatCachePolicy`. The protected cache root is fixed under Application Support and excluded from backup. |
| `APNSEnvironment` | `.sandbox`, `.production`. Optional override for `registerForPushNotifications(deviceToken:environment:)`; auto-detected from the provisioning profile when omitted. |
| `Channel` | `.chat`, `.voice`. |
| `SessionControl` | `.ai`, `.user`. |
| `MessageRole` | `.ai`, `.external`, `.user`, `.system`. |
| `MessageStatus` | `.sending`, `.delivered`, `.failed`. |
| `MessageState` | `.streaming`, `.completed`. |
| `AudioOutputRoute` | `.automatic` (default route — receiver / wired / Bluetooth), `.speaker` (loudspeaker), `.bluetooth` (on iOS, resolved via `.automatic` — the active session already routes to a connected HFP device). Argument to `setAudioOutput(_:)`. |
| `StartCallOptions` / `StartChatOptions` | Voice options; chat options with required first message; optional session id and raw JSON `data`. |
| `StartSessionResponse` | sessionId, url, token. |
| `JoinInput` | sessionId, url, token, passed to `joinCall` or `joinChat`. |
| `ActiveSession` | sessionId, channel. |
| `AttachmentRule` / `AttachmentPolicy` | tenant policy for attachments. |
| `ServerConfig` | full `/config` snapshot. |
| `DisconnectReason` | structured disconnect reasons (incl. `.serverClosed(code:detail:)`). |
| `ClientEvent` | `.messageAdded`, `.messageUpdated`, `.connected`, `.reconnecting`, `.reconnected`, `.peerAttached`, `.peerDetached`, `.disconnected`, `.callError`, `.audioRouteChanged`, `.controlUpdated`, `.typing`, `.sessionUpdated`. Every case carries `sessionId`. `.audioRouteChanged` carries the now-current `AudioOutputRoute` (drive a speaker toggle from `route == .speaker`); it fires on OS-driven route changes (headset plug/unplug) as well as your own `setAudioOutput`. |
| `Message` / `MessageMetadata` / `MessageAudience` | typed transcript line with optional `metadata` and optional closed audience (`internal` or `all`). Missing/null/empty legacy metadata remains nil; unknown non-empty audiences fail decoding. |
| `TypingState` / `TypingParticipant` | ordered authoritative active-typer snapshot. Render `participants.first` for the one-avatar UI; treat it as ephemeral and never persist/log it. |
| `Attachment` | uploaded-media descriptor: `id`, `name`, `contentType`, `url`, and an optional client-side `localUrl` preview (kept on the local `Message`, stripped from the wire). Returned by `uploadAttachment(...)`, carried on `Message.attachments`, and passed back into `SendMessagePayload.attachments`. |
| `UploadProgress` | `bytesUploaded`, optional `totalBytes`, optional `percent` (both `nil` when the transport reports no content length). Passed to the `uploadAttachment` `onProgress` callback. |
| `SessionLoadPolicy`, `SessionSnapshot`, `SessionDirectorySnapshot`, load updates | Typed cache/network source, authority, refresh time, snapshots, and refresh failures. |
| `SessionDirectoryPager`, `SessionHistoryPager`, page requests/pages/snapshots/load updates | Wrapper-owned generation fencing, search isolation, live reconciliation, stable-ID dedupe, prepend accumulation, nullable cursors, and bounded empty continuation. |
| `Contact`, `SessionSummary`, `SessionHistory` | typed directory/transcript shapes carried by snapshots. |
| `SendMessagePayload` | `text`, `html`, `attachments`, and optional `metadata` (input shape for `sendMessage(id:payload:)`). |
| `OrigonError` | structured error with `kind`, `statusCode`, `code`, `message`. |

## License

Proprietary. All rights reserved.
