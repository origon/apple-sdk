import Foundation
import XCTest
@testable import OrigonSDK

final class MobileContinuityTests: XCTestCase {
    func testDtmfValidationAcceptsExactlyThePublicAlphabet() throws {
        for digit in "0123456789*#ABCD" {
            XCTAssertEqual(
                UInt8(bitPattern: try OrigonClient.validateDtmfDigit(digit)),
                digit.asciiValue
            )
        }
    }

    func testDtmfValidationRejectsLowercaseAndNonAsciiWithoutEchoingInput() {
        for digit: Character in ["a", "d", "é", "１", "1\u{FE0F}"] {
            XCTAssertThrowsError(try OrigonClient.validateDtmfDigit(digit)) { error in
                let typed = error as? OrigonError
                XCTAssertEqual(typed?.kind, .other)
                XCTAssertEqual(typed?.code, "invalid_dtmf_digit")
                XCTAssertEqual(
                    typed?.description,
                    "DTMF digit must be one uppercase ASCII symbol"
                )
            }
        }
    }

    func testNativeHandleGateAllowsConcurrentCallsAndCloseWaitsForEveryLease() throws {
        let handle = try XCTUnwrap(OpaquePointer(bitPattern: 1))
        let gate = NativeHandleGate(handle)
        let bothEntered = DispatchSemaphore(value: 0)
        let releaseCalls = DispatchSemaphore(value: 0)
        let callsFinished = expectation(description: "both native calls finished")
        callsFinished.expectedFulfillmentCount = 2

        for _ in 0..<2 {
            Thread.detachNewThread {
                defer { callsFinished.fulfill() }
                try? gate.withHandle { observed in
                    XCTAssertEqual(observed, handle)
                    bothEntered.signal()
                    releaseCalls.wait()
                }
            }
        }
        XCTAssertEqual(bothEntered.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(
            bothEntered.wait(timeout: .now() + 1),
            .success,
            "native calls must use leases, not serialize behind one lock"
        )

        let destroyed = expectation(description: "native handle destroyed")
        let destroyedSignal = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            gate.close { observed in
                XCTAssertEqual(observed, handle)
                destroyedSignal.signal()
                destroyed.fulfill()
            }
        }
        XCTAssertEqual(
            destroyedSignal.wait(timeout: .now() + 0.05),
            .timedOut,
            "close must wait while native leases are active"
        )
        releaseCalls.signal()
        releaseCalls.signal()
        wait(for: [callsFinished, destroyed], timeout: 2)
        XCTAssertThrowsError(try gate.withHandle { _ in () })
    }

    func testCacheDefaultsOnAndLoaderWireValuesStayPinned() {
        let config = ClientConfig(endpoint: "https://example.test")
        XCTAssertEqual(config.chatCachePolicy, .enabled)
        XCTAssertEqual(SessionLoadPolicy.cacheThenNetwork.rawValue, 0)
        XCTAssertEqual(SessionLoadPolicy.networkOnly.rawValue, 1)
        XCTAssertEqual(SessionLoadPolicy.cacheOnly.rawValue, 2)
        XCTAssertEqual(ChatAccessIntent.passive.rawValue, 0)
        XCTAssertEqual(ChatAccessIntent.explicitNavigation.rawValue, 1)
        XCTAssertEqual(ChatAccessIntent.notification.rawValue, 2)
    }

    func testCacheSnapshotsDecodeBothSources() throws {
        let session = #"{"source":"cache","authoritative":false,"refreshedAt":42,"session":{"history":[],"control":"ai"}}"#
        let decodedSession = try JSONDecoder().decode(
            SessionSnapshot.self,
            from: Data(session.utf8)
        )
        XCTAssertEqual(decodedSession.source, .cache)
        XCTAssertFalse(decodedSession.authoritative)

        let directory = #"{"source":"network","authoritative":true,"refreshedAt":43,"sessions":[]}"#
        let decodedDirectory = try JSONDecoder().decode(
            SessionDirectorySnapshot.self,
            from: Data(directory.utf8)
        )
        XCTAssertEqual(decodedDirectory.source, .network)
        XCTAssertTrue(decodedDirectory.authoritative)
    }

    func testCacheRootIsFixedAndExcludedFromBackup() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("origon-cache-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let owner = base.appendingPathComponent("ai.origon.sdk", isDirectory: true)
        try FileManager.default.createDirectory(at: owner, withIntermediateDirectories: true)
        let sibling = owner.appendingPathComponent("identity-sibling")
        try Data("identity".utf8).write(to: sibling)
        let siblingBackupBefore = try sibling.resourceValues(
            forKeys: [.isExcludedFromBackupKey]
        ).isExcludedFromBackup
        #if (os(iOS) || os(tvOS) || os(watchOS)) && !targetEnvironment(simulator)
        let siblingProtectionBefore = try FileManager.default.attributesOfItem(
            atPath: sibling.path
        )[.protectionKey] as? FileProtectionType
        #endif
        let root = try ChatCacheStorage.prepare(in: base)
        XCTAssertTrue(root.path.hasSuffix("/ai.origon.sdk/chat-cache-v1"))
        let values = try root.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
        XCTAssertEqual(
            try sibling.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup,
            siblingBackupBefore
        )
        #if (os(iOS) || os(tvOS) || os(watchOS)) && !targetEnvironment(simulator)
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: sibling.path)[.protectionKey]
                as? FileProtectionType,
            siblingProtectionBefore
        )
        let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
        XCTAssertEqual(
            attributes[.protectionKey] as? FileProtectionType,
            .completeUntilFirstUserAuthentication
        )
        #endif
    }

    func testModelsDirectoryIsFixedAndExcludedFromBackup() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("origon-models-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let root = try NoiseModelStorage.prepare(in: base)
        XCTAssertTrue(root.path.hasSuffix("/ai.origon.sdk/models"))
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        let values = try root.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
        // Idempotent: a second client reuses the folder.
        XCTAssertEqual(try NoiseModelStorage.prepare(in: base), root)
    }

    func testSessionSummaryRequiresActive() throws {
        let complete = #"{"sessionId":"s","subject":"x","channel":"chat","active":true,"createdAt":"c","updatedAt":"u"}"#
        XCTAssertTrue(try JSONDecoder().decode(SessionSummary.self, from: Data(complete.utf8)).active)

        let legacy = #"{"sessionId":"s","subject":"x","channel":"chat","createdAt":"c","updatedAt":"u"}"#
        XCTAssertThrowsError(try JSONDecoder().decode(SessionSummary.self, from: Data(legacy.utf8)))
    }

    func testMessageAndSendPayloadPreserveOptionalAudienceMetadata() throws {
        let internalRow = #"{"id":"m1","metadata":{"audience":"internal"}}"#
        let decoded = try JSONDecoder().decode(Message.self, from: Data(internalRow.utf8))
        XCTAssertEqual(decoded.metadata?.audience, .internalParticipants)
        let allRow = #"{"id":"m1a","metadata":{"audience":"all"}}"#
        XCTAssertEqual(
            try JSONDecoder().decode(Message.self, from: Data(allRow.utf8)).metadata?.audience,
            .all
        )

        for row in [#"{"id":"m2"}"#, #"{"id":"m2","metadata":null}"#] {
            XCTAssertNil(try JSONDecoder().decode(Message.self, from: Data(row.utf8)).metadata)
        }

        for row in [
            #"{"id":"m3","metadata":{}}"#,
            #"{"id":"m3","metadata":{"audience":null}}"#,
            #"{"id":"m3","metadata":{"audience":""}}"#,
        ] {
            let message = try JSONDecoder().decode(Message.self, from: Data(row.utf8))
            XCTAssertNotNil(message.metadata)
            XCTAssertNil(message.metadata?.audience)
        }

        XCTAssertNil(Message(id: "local").metadata)

        let unknown = #"{"id":"m4","metadata":{"audience":"staff"}}"#
        XCTAssertThrowsError(try JSONDecoder().decode(Message.self, from: Data(unknown.utf8)))
        let whitespace = #"{"id":"m5","metadata":{"audience":" "}}"#
        XCTAssertThrowsError(try JSONDecoder().decode(Message.self, from: Data(whitespace.utf8)))

        let encoder = JSONEncoder()
        let omitted = try XCTUnwrap(JSONSerialization.jsonObject(
            with: encoder.encode(SendMessagePayload(text: "hello"))
        ) as? [String: Any])
        XCTAssertNil(omitted["metadata"])

        let empty = try XCTUnwrap(JSONSerialization.jsonObject(
            with: encoder.encode(SendMessagePayload(metadata: MessageMetadata()))
        ) as? [String: Any])
        XCTAssertEqual((empty["metadata"] as? [String: Any])?.count, 0)

        let explicit = try XCTUnwrap(JSONSerialization.jsonObject(
            with: encoder.encode(SendMessagePayload(metadata: MessageMetadata(audience: .all)))
        ) as? [String: Any])
        XCTAssertEqual((explicit["metadata"] as? [String: Any])?["audience"] as? String, "all")
    }

    func testSessionSummaryLastMessageAcceptsLegacyMissingMetadata() throws {
        let row = #"{"sessionId":"s","subject":"Support","channel":"chat","active":false,"createdAt":"c","updatedAt":"u","lastMessage":{"id":"m","role":"external","attachments":[],"status":"delivered","state":"completed"}}"#
        let summary = try JSONDecoder().decode(SessionSummary.self, from: Data(row.utf8))
        XCTAssertNotNil(summary.lastMessage)
        XCTAssertNil(summary.lastMessage?.metadata)
    }

    func testNotificationGenerationMustMatchExactly() throws {
        let suiteName = "ai.origon.sdk.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("current", forKey: PushRegistrationStore.generationKey)

        XCTAssertTrue(OrigonPushNotification.isCurrent(
            userInfo: ["endpointGeneration": "current"],
            appGroupIdentifier: suiteName
        ))
        XCTAssertFalse(OrigonPushNotification.isCurrent(
            userInfo: ["endpointGeneration": "stale"],
            appGroupIdentifier: suiteName
        ))
        XCTAssertFalse(OrigonPushNotification.isCurrent(userInfo: [:], appGroupIdentifier: suiteName))
    }

    func testExactGenerationCopiesAuthorizedTitleAndPreview() {
        let copy = OrigonPushNotification.deliveryCopy(
            providerTitle: "Provider title",
            providerBody: "Provider body",
            userInfo: [
                "endpointGeneration": "current",
                "title": "Agent Name",
                "preview": "Authorized preview",
            ],
            currentGeneration: "current"
        )

        XCTAssertEqual(copy.title, "Agent Name")
        XCTAssertEqual(copy.body, "Authorized preview")
    }

    func testStaleGenerationPreservesProviderVisibleCopy() {
        let copy = OrigonPushNotification.deliveryCopy(
            providerTitle: "Provider title",
            providerBody: "Provider body",
            userInfo: [
                "endpointGeneration": "stale",
                "title": "Unauthorized title",
                "preview": "Unauthorized preview",
            ],
            currentGeneration: "current"
        )

        XCTAssertEqual(copy.title, "Provider title")
        XCTAssertEqual(copy.body, "Provider body")
    }

    func testMissingGenerationPreservesProviderVisibleCopy() {
        let copy = OrigonPushNotification.deliveryCopy(
            providerTitle: "Provider title",
            providerBody: "Provider body",
            userInfo: [
                "title": "Unauthorized title",
                "preview": "Unauthorized preview",
            ],
            currentGeneration: "current"
        )

        XCTAssertEqual(copy.title, "Provider title")
        XCTAssertEqual(copy.body, "Provider body")
    }

    func testBlankAuthorizedTitlePreservesProviderTitle() {
        let copy = OrigonPushNotification.deliveryCopy(
            providerTitle: "Provider title",
            providerBody: "Provider body",
            userInfo: [
                "endpointGeneration": "current",
                "title": " \n\t ",
                "preview": "Authorized preview",
            ],
            currentGeneration: "current"
        )

        XCTAssertEqual(copy.title, "Provider title")
        XCTAssertEqual(copy.body, "Authorized preview")
    }

    func testAbsentAuthorizedTitlePreservesProviderTitle() {
        let copy = OrigonPushNotification.deliveryCopy(
            providerTitle: "Provider title",
            providerBody: "Provider body",
            userInfo: [
                "endpointGeneration": "current",
                "preview": "Authorized preview",
            ],
            currentGeneration: "current"
        )

        XCTAssertEqual(copy.title, "Provider title")
        XCTAssertEqual(copy.body, "Authorized preview")
    }
}
