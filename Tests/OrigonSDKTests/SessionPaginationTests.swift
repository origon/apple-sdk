import XCTest
@testable import OrigonSDK

final class SessionPaginationTests: XCTestCase {
    private func summary(
        _ id: String,
        updatedAt: String,
        subject: String = "",
        contact: Contact? = nil,
        lastMessage: Message? = nil
    ) -> SessionSummary {
        SessionSummary(
            sessionId: id,
            subject: subject,
            channel: .chat,
            active: true,
            createdAt: updatedAt,
            updatedAt: updatedAt,
            lastMessage: lastMessage,
            contact: contact
        )
    }

    func testStrictPageEnvelopesRequireNullableCursorAndClosedControl() throws {
        let directory = #"{"sessions":[],"nextCursor":null}"#
        XCTAssertNil(
            try JSONDecoder().decode(SessionDirectoryPage.self, from: Data(directory.utf8)).nextCursor
        )
        for invalid in [
            #"{"sessions":[]}"#,
            #"{"sessions":[],"nextCursor":null,"extra":true}"#,
        ] {
            XCTAssertThrowsError(
                try JSONDecoder().decode(SessionDirectoryPage.self, from: Data(invalid.utf8))
            )
        }

        let history = #"{"history":[],"control":"user","nextCursor":null}"#
        XCTAssertEqual(
            try JSONDecoder().decode(SessionHistoryPage.self, from: Data(history.utf8)).control,
            .user
        )
        for invalid in [
            #"{"history":[],"control":"bogus","nextCursor":null}"#,
            #"{"history":[],"control":"ai"}"#,
        ] {
            XCTAssertThrowsError(
                try JSONDecoder().decode(SessionHistoryPage.self, from: Data(invalid.utf8))
            )
        }
    }

    func testDirectoryPagerFencesQueriesAndReconcilesLiveSearchRows() {
        let pager = SessionDirectoryPager()
        let stale = pager.begin(cached: [summary("cached", updatedAt: "1")])
        pager.applyLive(summary("live", updatedAt: "4"))
        XCTAssertTrue(pager.merge(
            .init(sessions: [summary("server", updatedAt: "3")], nextCursor: "next"),
            generation: stale,
            firstPage: true
        ))
        XCTAssertEqual(pager.snapshot.sessions.map(\.sessionId), ["live", "server"])

        let generation = pager.begin(search: "Ada")
        XCTAssertFalse(pager.merge(
            .init(sessions: [summary("stale", updatedAt: "9")], nextCursor: nil),
            generation: stale,
            firstPage: true
        ))
        pager.applyLive(summary("other", updatedAt: "5"))
        XCTAssertTrue(pager.snapshot.sessions.isEmpty)
        pager.applyLive(summary(
            "matching",
            updatedAt: "6",
            contact: Contact(id: "private", name: "ADA")
        ))
        XCTAssertEqual(pager.snapshot.sessions.map(\.sessionId), ["matching"])
        pager.applyLive(summary("matching", updatedAt: "7"))
        XCTAssertTrue(pager.snapshot.sessions.isEmpty)
        XCTAssertEqual(pager.snapshot.generation, generation)
    }

    func testSearchCorpusAndNormalizationMatchServer() {
        XCTAssertEqual(normalizeSessionSearch("  A\u{2003}\u{2003}B\u{0000}  "), "a b")
        let message = Message(
            id: "message-private",
            text: "Latest reply",
            attachments: [
                Attachment(
                    id: "attachment-private",
                    name: "invoice.PDF",
                    contentType: "x",
                    url: "secret-url"
                )
            ]
        )
        let row = summary(
            "session-private",
            updatedAt: "1",
            subject: "Billing\u{2003}Question",
            contact: Contact(id: "contact-private", name: "Ada Lovelace"),
            lastMessage: message
        )
        for query in ["billing question", "ada", "latest reply", "invoice.pdf"] {
            XCTAssertTrue(sessionSummary(row, matches: query))
        }
        for query in ["session-private", "contact-private", "secret-url"] {
            XCTAssertFalse(sessionSummary(row, matches: query))
        }
    }

    func testHistoryPagerPrependsAndCollapsesLocalAndServerIdentity() {
        let pager = SessionHistoryPager()
        let generation = pager.begin(cached: .init(
            history: [Message(id: "cached")],
            control: .ai
        ))
        pager.applyLive(Message(id: "", localId: "local", status: .sending))
        pager.applyLive(Message(id: "server", localId: "local"))
        XCTAssertTrue(pager.merge(
            .init(history: [Message(id: "new")], control: .user, nextCursor: "older"),
            generation: generation,
            firstPage: true
        ))
        XCTAssertTrue(pager.merge(
            .init(history: [Message(id: "old")], control: .user, nextCursor: nil),
            generation: generation,
            firstPage: false
        ))
        XCTAssertEqual(pager.snapshot.history.map(\.id), ["old", "new", "server"])
        XCTAssertFalse(pager.snapshot.canLoadMore)
    }
}
