import COrigonSDK
import XCTest
@testable import OrigonSDK

final class CallStatsTests: XCTestCase {
    func testMapsEveryFieldOfTheNativeStruct() {
        var native = SessionCallStats()
        native.uplink_sent = 1
        native.uplink_red = 1
        native.uplink_fec_loss_percent = 5
        native.downlink_tracks = 2
        native.downlink_audio_age_ms = 40
        native.transport_rtt_us = 900
        native.transport_reconnects = 3

        let stats = CallStats(native)

        XCTAssertEqual(stats.uplink.sent, 1)
        XCTAssertTrue(stats.uplink.redundancyOn)
        XCTAssertEqual(stats.uplink.fecLossPercent, 5)
        XCTAssertEqual(stats.downlink.tracks, 2)
        XCTAssertEqual(stats.downlink.audioAgeMs, 40)
        XCTAssertEqual(stats.transport.rttUs, 900)
        XCTAssertEqual(stats.transport.reconnects, 3)
    }

    func testTheStructKeepsItsAbiSize() {
        XCTAssertEqual(MemoryLayout<SessionCallStats>.size, 224)
    }
}
