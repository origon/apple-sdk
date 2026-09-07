# OrigonSDK iOS Example

A minimal iOS app demonstrating how to integrate **OrigonSDK** for chat and
voice calls. Two screens:

1. **Endpoint** — user enters an endpoint URL; the app calls
   `SDKManager.initialize(endpoint:)` and persists the URL for next launch.
2. **Home** — chat surface with a side drawer that lists past sessions
   (cache-first `sessionDirectoryUpdates()`), a "New" button, and a voice button that initiates
   a call (`CallService.startCall()`).

## Requirements

- Xcode 16+ with its Swift 6 package toolchain (the app remains in Swift 5
  language mode)
- iOS 16+ target device or simulator
- A valid Apple Developer team for signing (configure once in Xcode)

## Getting started

Open `OrigonSDKExample.xcodeproj` directly — no extra tooling required:

```bash
cd apple-sdk/examples/origon-sdk-example-ios
open OrigonSDKExample.xcodeproj
```

From there:

1. Select a development team under **Signing & Capabilities**.
2. Pick a destination (simulator or device).
3. Hit ⌘R.

The shared scheme includes the example-owned policy test target. Run it on the
same simulator from Xcode with ⌘U, or from a terminal:

```bash
xcodebuild test \
  -project OrigonSDKExample.xcodeproj \
  -scheme OrigonSDKExample \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  CODE_SIGNING_ALLOWED=NO
```

On first launch the app shows the Endpoint screen. Enter your Origon endpoint
URL (e.g. `https://api.example.com`) and continue — the app stays signed in
to that endpoint across relaunches. To switch endpoints, open the sidebar →
**Options → Change Endpoint**.

## Cache and named chat access

The example renders the SDK's finite cache-first directory/transcript streams:
cached state may paint immediately, followed by one authoritative snapshot or a
typed refresh failure. Selecting a history row calls
`openChat(sessionId:intent: .explicitNavigation)` before it can send, so passive
cache display never acquires takeover authority. `NEW MESSAGES` is an
example-owned, protected unread checkpoint rather than SDK state.

This sample deliberately does **not** call `restoreActiveChats()` and does not
auto-return to a recent chat. Those are host-product lifecycle choices, not
required SDK integration. Apps that want passive retained-chat restore can use
the API described in the repository's main README while keeping explicit row
and notification navigation on their named intents.

## Audio-level callback probe

The example UI intentionally remains unchanged, but a call surface can attach the
new native meter without opening another microphone path:

```swift
let observation = try client.observeAudioLevels(sessionId: sessionId) { levels in
    // MainActor. Use aggregate levels for a wave and endpoint entries for tiles.
    let wave = min(max(max(levels.outbound, levels.inbound) * 4, 0), 1)
    renderWave(wave)
}

// Retain while the call view is active, then cancel (also idempotent on deinit).
observation.cancel()
```

The callback is advisory UI data. Cancellation or metering failure never changes
the underlying audio call, and endpoint ids must not be persisted or treated as
canonical participant identities.

## Where to look in the code

If you want to wire OrigonSDK into your own app, start with these files:

| File | Role |
| --- | --- |
| `Services/SDKManager.swift` | Single entry point. Owns `OrigonClient`, drains the SDK event stream, and exposes `CallService` / `ChatService` to the UI. |
| `Services/ChatService.swift` | Chat state machine — `openSession`, `sendMessage`, attachment upload, typing, multi-session bookkeeping. |
| `Services/CallService.swift` | Voice-call state machine — `startCall`, `setMute`, `endCall`, phase transitions. |
| `Views/EndpointView.swift` | Calls `sdk.initialize(endpoint:)`. |
| `Views/RootChatView.swift` | Boots the SDK, lists sessions, hosts ChatView + CallView. |
| `Views/ChatView.swift` | Composes messages, drives upload UI, kicks off calls. |
| `Views/CallView.swift` | Active-call surface (logo, mute, end). |
| `Components/MessageBubble.swift` | One transcript row. **Note the divider rule:** a lifecycle row is discriminated by the presence of `Message.action`, *not* by `role == .system` — a `.system` message with no action is a flow-bot prompt and stays a bubble. |
| `Components/MessageButtons.swift`, `Components/MessageGallery.swift` | Interactive prompt options. A `"url"` option opens the link **and** posts the reply — the flow still has to walk that edge. |

## Project layout

```
origon-sdk-example-ios/
├── README.md
├── OrigonSDKExample.xcodeproj   # open this directly
└── OrigonSDKExample/
    ├── OrigonSDKExampleApp.swift
    ├── RootView.swift
    ├── Theme.swift
    ├── Constants.swift
    ├── Models.swift
    ├── Assets.xcassets/
    ├── Components/
    ├── Services/
    └── Views/
```

## Permissions

The app requests:
- **Microphone** — for voice calls
- **Camera** — for attaching photos taken in-app

Both usage descriptions are configured in the app target's Info settings.
Photo library access goes through `PHPickerViewController` and does not require
a usage string.

To keep an active voice call running after screen lock or backgrounding, add
the **Background Modes** capability and select **Audio, AirPlay, and Picture in
Picture** (`UIBackgroundModes = audio`) on the host app target. The example has
no push runtime by design; the main README is the complete APNs capability,
token/generation, Notification Service Extension, tap, logout, uninstall, and
safe-logging integration guide.

## SDK version

The `OrigonSDK` Swift package is consumed via SPM from
[github.com/Origon/apple-sdk](https://github.com/Origon/apple-sdk). The version
rule is **Up to Next Major Version** from `0.3.4`. To change it, select the project in Xcode →
**Package Dependencies** → double-click the `apple-sdk` row and edit the rule.

## Scope notes

The example authenticates **by endpoint only** — it never signs a person in, so
there is no login, profile, or account screen. Its test target owns regression
coverage for policy copied into the example; SDK package tests remain supporting
coverage for the wrapper itself.

There are no screenshots, deliberately. A screenshot in a repo goes stale the
moment the UI moves, and this app is meant to be read and run.
