import Foundation
import XCTest
@testable import OrigonSDK

final class ClientLifecycleTests: XCTestCase {
    func testExplicitCloseThenReleaseDoesNotRetainClientDuringDeinit() throws {
        weak var releasedClient: OrigonClient?
        let destroyed = expectation(description: "native client destroyed once")

        autoreleasepool {
            let handle = OpaquePointer(bitPattern: 1)!
            var client: OrigonClient? = OrigonClient(
                testingHandle: handle,
                subscribeAudioLevels: { _, _ in throw OrigonError.notInitialized },
                destroy: { _ in destroyed.fulfill() }
            )
            releasedClient = client

            client?.close()
            client = nil
        }

        // Drain detach work queued before the registrar's synchronous barrier.
        // A detach closure must not keep a closing client alive or re-retain it
        // when deinit defensively calls close a second time.
        OrigonClient.clearPushNotificationAuthority()

        wait(for: [destroyed], timeout: 1)
        XCTAssertNil(releasedClient)
    }
}
