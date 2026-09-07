import Foundation
import os

// MARK: - Public push API

extension OrigonClient {
    /// Configure an App Group used to mirror the current endpoint generation
    /// into a Notification Service Extension. Call before registering a token.
    public static func configurePushNotifications(appGroupIdentifier: String) {
        PushRegistrar.shared.configure(appGroupIdentifier: appGroupIdentifier)
    }

    /// Register this device's APNs token so the backend can deliver push
    /// notifications.
    ///
    /// Call this from
    /// `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`.
    /// It is safe to call:
    /// - **before `OrigonClient` is initialized** — the token is buffered
    ///   and the registration is sent automatically once a client exists;
    /// - **repeatedly** (e.g. on every APNs token refresh) — the most
    ///   recent token wins.
    ///
    /// The call returns immediately and performs the network request on a
    /// background queue. Failures are logged rather than thrown: APNs
    /// delivers tokens through a fire-and-forget OS callback, so there is
    /// no caller to surface an error to. The SDK re-sends on the next
    /// launch when the app calls this again with the current token.
    ///
    /// - Parameters:
    ///   - deviceToken: the raw token `Data` handed to
    ///     `didRegisterForRemoteNotificationsWithDeviceToken`. The SDK
    ///     hex-encodes it for the wire.
    ///   - environment: APNs environment override. Defaults to `nil`,
    ///     which auto-detects from the embedded provisioning profile
    ///     (and falls back to ``APNSEnvironment/production`` for App Store
    ///     builds, which ship no profile).
    public static func registerForPushNotifications(
        deviceToken: Data,
        environment: APNSEnvironment? = nil
    ) {
        let hexToken = deviceToken.map { String(format: "%02x", $0) }.joined()
        PushRegistrar.shared.register(token: hexToken, environment: environment)
    }

    /// Remove this device's push registration for the current user.
    ///
    /// Clears any token buffered before init so a subsequent
    /// initialization will not re-register. Returns immediately and runs
    /// the network request on a background queue; failures are logged.
    /// Typically called on logout.
    public static func unregisterForPushNotifications() {
        PushRegistrar.shared.unregister()
    }

    /// Clear local preview authority immediately without contacting the backend.
    /// Hosts call this during logout even when no initialized client exists.
    public static func clearPushNotificationAuthority() {
        PushRegistrar.shared.clearAuthority()
    }

    /// Generation-bound logout gate. Completes before returning, so the client
    /// may be released immediately afterwards.
    public func unregisterPushNotificationsForLogout() throws {
        try PushRegistrar.shared.unregisterSynchronously(client: self)
    }
}

// MARK: - Registrar

/// Process-wide coordinator for push registration.
///
/// Push registration is a device/app-level concern that can race
/// `OrigonClient` initialization (APNs often delivers the token before
/// the app has built its client), so the state lives here rather than on
/// a client instance. A single serial queue owns all mutable state and
/// performs the blocking FFI calls, which keeps registration ordered and
/// off the main thread.
final class PushRegistrar: @unchecked Sendable {
    static let shared = PushRegistrar()

    private let queue = DispatchQueue(label: "ai.origon.sdk.push")
    private let log = Logger(subsystem: "ai.origon.sdk", category: "push")

    // All state below is confined to `queue`.

    /// The most recently initialized client, or `nil` before init / after
    /// it is torn down. Weak so the registrar never keeps a client alive.
    private weak var client: OrigonClient?
    /// Latest token awaiting (re-)send. Retained so a client created after
    /// the token arrives can still register, and so we can resend on a
    /// later attach.
    private var bufferedToken: String?
    private var bufferedEnvironment: APNSEnvironment?
    private var appGroupIdentifier: String?
    /// Logout closes registration until a different client attaches. This
    /// drops late APNs callbacks still targeting the old identity.
    private var authoritySuspended = false

    /// APNs environment for this build. Constant for the process lifetime,
    /// so it is resolved once on first use.
    private lazy var detectedEnvironment: APNSEnvironment = Self.detectEnvironment()

    // MARK: Client lifecycle (called by OrigonClient)

    /// Record the active client and flush any token buffered before init.
    ///
    /// The client is held weakly; its reference auto-nils when the client
    /// deallocates, so there is no explicit detach.
    func attach(_ client: OrigonClient) {
        queue.async {
            self.client = client
            self.authoritySuspended = false
            let persisted = PushRegistrationStore.registration()
            guard let token = self.bufferedToken ?? persisted?.token else { return }
            let environment = self.bufferedEnvironment
                ?? persisted.flatMap { APNSEnvironment(rawValue: $0.environment) }
            self.log.debug("flushing buffered push token after init")
            self.sendRegister(client: client, token: token, environment: environment)
        }
    }

    /// Fence a closing client from buffered or already-queued registration.
    /// The token remains buffered for the next authoritative client.
    func detach(_ client: OrigonClient) {
        queue.async { [weak client] in
            if self.client === client {
                self.client = nil
            }
        }
    }

    // MARK: Registration (called by the public API)

    func configure(appGroupIdentifier: String) {
        queue.async {
            self.appGroupIdentifier = appGroupIdentifier
            PushRegistrationStore.mirrorCurrentGeneration(to: appGroupIdentifier)
        }
    }

    func register(token: String, environment: APNSEnvironment?) {
        queue.async {
            guard !self.authoritySuspended else {
                self.log.debug("push authority suspended; dropping token callback")
                return
            }
            let resolved = environment ?? self.detectedEnvironment
            self.bufferedToken = token
            self.bufferedEnvironment = resolved
            guard let client = self.client else {
                self.log.debug("no active client; buffering push token until init")
                return
            }
            self.sendRegister(client: client, token: token, environment: resolved)
        }
    }

    func unregister() {
        queue.async {
            self.authoritySuspended = true
            self.bufferedToken = nil
            self.bufferedEnvironment = nil
            guard let registration = PushRegistrationStore.registration() else {
                PushRegistrationStore.clear(appGroupIdentifier: self.appGroupIdentifier)
                self.log.debug("no persisted push registration; nothing to unregister")
                return
            }
            guard let client = self.client else {
                self.log.debug("no active client; retaining registration for logout retry")
                return
            }
            do {
                try client.unregisterPush(
                    token: registration.token,
                    provider: "apns",
                    environment: registration.environment,
                    generation: registration.generation
                )
                PushRegistrationStore.clear(appGroupIdentifier: self.appGroupIdentifier)
            } catch {
                self.log.error("unregisterForPushNotifications failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func unregisterSynchronously(client: OrigonClient) throws {
        try queue.sync {
            authoritySuspended = true
            bufferedToken = nil
            bufferedEnvironment = nil
            guard let registration = PushRegistrationStore.registration() else {
                PushRegistrationStore.clear(appGroupIdentifier: appGroupIdentifier)
                return
            }
            defer { PushRegistrationStore.clear(appGroupIdentifier: appGroupIdentifier) }
            try client.unregisterPush(
                token: registration.token,
                provider: "apns",
                environment: registration.environment,
                generation: registration.generation
            )
        }
    }

    func clearAuthority() {
        queue.sync {
            authoritySuspended = true
            bufferedToken = nil
            bufferedEnvironment = nil
            PushRegistrationStore.clear(appGroupIdentifier: appGroupIdentifier)
        }
    }

    /// Must be called on `queue`.
    private func sendRegister(client: OrigonClient, token: String, environment: APNSEnvironment?) {
        do {
            let resolvedEnvironment = environment ?? detectedEnvironment
            let generation = try client.registerPush(
                token: token,
                provider: "apns",
                environment: resolvedEnvironment.rawValue
            )
            PushRegistrationStore.save(
                PushRegistration(
                    token: token,
                    environment: resolvedEnvironment.rawValue,
                    generation: generation
                ),
                appGroupIdentifier: appGroupIdentifier
            )
        } catch {
            self.log.error("registerForPushNotifications failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: APNs environment detection

    /// Resolve the APNs environment from the app's embedded provisioning
    /// profile.
    ///
    /// The profile (`embedded.mobileprovision`) is a CMS-signed blob with
    /// a plaintext XML plist embedded in it; we slice out the
    /// `<?xml … </plist>` range and read `Entitlements.aps-environment`
    /// (`development` → ``APNSEnvironment/sandbox``, `production` →
    /// ``APNSEnvironment/production``). App Store builds ship no profile,
    /// so a missing file resolves to `.production`.
    private static func detectEnvironment() -> APNSEnvironment {
        guard
            let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
            let data = try? Data(contentsOf: url),
            let raw = String(data: data, encoding: .ascii) ?? String(data: data, encoding: .isoLatin1),
            let start = raw.range(of: "<?xml"),
            let end = raw.range(of: "</plist>")
        else {
            return .production
        }
        let plistString = String(raw[start.lowerBound..<end.upperBound])
        guard
            let plistData = plistString.data(using: .isoLatin1),
            let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil),
            let dict = plist as? [String: Any],
            let entitlements = dict["Entitlements"] as? [String: Any],
            let apsEnvironment = entitlements["aps-environment"] as? String
        else {
            return .production
        }
        return apsEnvironment == "production" ? .production : .sandbox
    }
}

struct PushRegistration: Codable {
    let token: String
    let environment: String
    let generation: String
}

enum PushRegistrationStore {
    static let generationKey = "ai.origon.sdk.push.endpointGeneration"
    private static let registrationKey = "ai.origon.sdk.push.registration"

    static func registration() -> PushRegistration? {
        guard let data = UserDefaults.standard.data(forKey: registrationKey) else { return nil }
        return try? JSONDecoder().decode(PushRegistration.self, from: data)
    }

    static func save(_ registration: PushRegistration, appGroupIdentifier: String?) {
        if let data = try? JSONEncoder().encode(registration) {
            UserDefaults.standard.set(data, forKey: registrationKey)
        }
        UserDefaults.standard.set(registration.generation, forKey: generationKey)
        if let appGroupIdentifier {
            UserDefaults(suiteName: appGroupIdentifier)?.set(registration.generation, forKey: generationKey)
        }
    }

    static func clear(appGroupIdentifier: String?) {
        UserDefaults.standard.removeObject(forKey: registrationKey)
        UserDefaults.standard.removeObject(forKey: generationKey)
        if let appGroupIdentifier {
            UserDefaults(suiteName: appGroupIdentifier)?.removeObject(forKey: generationKey)
        }
    }

    static func mirrorCurrentGeneration(to appGroupIdentifier: String) {
        guard let generation = UserDefaults.standard.string(forKey: generationKey) else { return }
        UserDefaults(suiteName: appGroupIdentifier)?.set(generation, forKey: generationKey)
    }
}
