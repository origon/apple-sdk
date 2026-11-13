import XCTest
import COrigonSDK
@testable import OrigonSDK

final class OrpcSessionTests: XCTestCase {
    func testRequestIsBorrowedAsBinarySafeC() {
        let request = OrpcSession.Request(
            path: "cx.v1.Dock/Login",
            metadata: [(key: "authorization", value: Data("Bearer t".utf8)), (key: "bin", value: Data([0, 255]))],
            body: Data([1, 2, 3])
        )
        request.withC { c in
            XCTAssertEqual(String(cString: c.pointee.path), "cx.v1.Dock/Login")
            XCTAssertEqual(c.pointee.metadata_count, 2)
            XCTAssertEqual(c.pointee.body_len, 3)
            let entries = UnsafeBufferPointer(start: c.pointee.metadata, count: 2)
            XCTAssertEqual(String(cString: entries[0].key), "authorization")
            XCTAssertEqual(Data(bytes: entries[1].value!, count: entries[1].value_len), Data([0, 255]))
            XCTAssertEqual(Data(bytes: c.pointee.body!, count: 3), Data([1, 2, 3]))
        }
    }

    func testEmptyRequestHasNoMetadata() {
        OrpcSession.Request(path: "a/B").withC { c in
            XCTAssertEqual(c.pointee.metadata_count, 0)
            XCTAssertEqual(c.pointee.body_len, 0)
        }
    }

    func testNextKindsMapToItems() {
        var next = SessionOrpcNext()
        next.generation = 2
        XCTAssertEqual(OrpcSession.item(kind: SESSION_ORPC_NEXT_STREAM_ENDED, next), .streamEnded(generation: 2))
        next.status = SESSION_ORPC_STATUS_RECONNECTING
        next.attempt = 3
        XCTAssertEqual(OrpcSession.item(kind: SESSION_ORPC_NEXT_STATUS, next), .status(.reconnecting(attempt: 3)))
        next.terminal = SESSION_ORPC_TERMINAL_OVERFLOW
        XCTAssertEqual(OrpcSession.item(kind: SESSION_ORPC_NEXT_TERMINAL, next), .terminal(.overflow))
        XCTAssertNil(OrpcSession.item(kind: SESSION_ORPC_NEXT_CANCELLED, next))
        XCTAssertNil(OrpcSession.item(kind: SESSION_ORPC_NEXT_CLOSED, next))
    }

    func testOrpcErrorKindsDecode() {
        XCTAssertEqual(OrigonError.Kind(rawValue: 12), .orpcRejected)
        XCTAssertEqual(OrigonError.Kind(rawValue: 15), .orpcInvalid)
    }
}
