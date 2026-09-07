import XCTest
@testable import OrigonSDK

final class PublicAPIContractTests: XCTestCase {
    func testInitializerAndConfigSurfaceKeepTheirTypes() throws {
        let initializer: (ClientConfig) throws -> OrigonClient = OrigonClient.init(config:)
        let observe: (OrigonClient) -> () throws -> AsyncThrowingStream<ServerConfigLoadUpdate, Error> =
            OrigonClient.serverConfigUpdates
        let retry: (OrigonClient) -> () throws -> AsyncThrowingStream<ServerConfigLoadUpdate, Error> =
            OrigonClient.retryServerConfig
        _ = initializer
        _ = observe
        _ = retry
    }

    func testConfigSnapshotDecodesOneAtomicGeneration() throws {
        let json = #"{"source":"cache","authoritative":false,"refreshedAt":7,"config":{"startMessage":"Hello","multipleChannels":true,"chatEnabled":true,"callEnabled":false,"attachmentPolicy":{"images":{"enabled":true,"maxSize":5},"documents":{"enabled":false,"maxSize":0},"videos":{"enabled":false,"maxSize":0},"audio":{"enabled":false,"maxSize":0}}}}"#
        let snapshot = try JSONDecoder().decode(
            ServerConfigLoadSnapshot.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(snapshot.source, .cache)
        XCTAssertFalse(snapshot.authoritative)
        XCTAssertEqual(snapshot.refreshedAt, 7)
        XCTAssertEqual(snapshot.config.startMessage, "Hello")
        XCTAssertTrue(snapshot.config.isChatEnabled)
        XCTAssertTrue(snapshot.config.attachmentPolicy.images.enabled)
    }
}
