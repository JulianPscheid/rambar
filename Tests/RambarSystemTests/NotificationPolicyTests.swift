import XCTest
@testable import RambarSystem

final class NotificationPolicyTests: XCTestCase {
    func testDisabledBatchAdvancesCursorWithoutDeliveringMessages() {
        let events = [
            StoredEvent(
                ts: 101,
                kind: EventKind.attention,
                payload: #"{"project":"hedy_mobile","footprint":"3221225472","procs":"44"}"#
            ),
            StoredEvent(
                ts: 102,
                kind: EventKind.pressure,
                payload: #"{"to":"warn"}"#
            ),
        ]

        let batch = notificationBatch(events: events, enabled: false)

        XCTAssertEqual(batch.updatedThrough, 102)
        XCTAssertTrue(batch.messages.isEmpty)
    }

    func testPressureWarningIncludesRecentMoverWhenEnabled() throws {
        let event = StoredEvent(
            ts: 201,
            kind: EventKind.pressure,
            payload: #"{"to":"warn","mover_project":"hedy_mobile","mover_delta":"569376768"}"#
        )

        let message = try XCTUnwrap(
            notificationBatch(events: [event], enabled: true).messages.first
        )

        XCTAssertEqual(message.title, "Memory pressure warn")
        XCTAssertEqual(message.body, "Biggest recent mover: hedy_mobile, +543 MB in 10 min")
    }

    func testNormalPressureAndUnrelatedEventsDoNotNotify() {
        let events = [
            StoredEvent(ts: 301, kind: EventKind.pressure, payload: #"{"to":"normal"}"#),
            StoredEvent(ts: 302, kind: EventKind.sessionStarted, payload: "{}"),
        ]

        let batch = notificationBatch(events: events, enabled: true)

        XCTAssertEqual(batch.updatedThrough, 302)
        XCTAssertTrue(batch.messages.isEmpty)
    }

    func testAttentionAndOrphanMessagesRemainAvailableWhenEnabled() {
        let events = [
            StoredEvent(
                ts: 401,
                kind: EventKind.attention,
                payload: #"{"project":"hedy_mobile","footprint":"2684354560","procs":"44"}"#
            ),
            StoredEvent(
                ts: 402,
                kind: EventKind.orphans,
                payload: #"{"count":"3","footprint":"1073741824"}"#
            ),
        ]

        let messages = notificationBatch(events: events, enabled: true).messages

        XCTAssertEqual(messages.map(\.title), ["Session running large", "Agent helpers left behind"])
        XCTAssertEqual(messages[0].body, "hedy_mobile is at 2.5 GB (44 processes)")
        XCTAssertEqual(messages[1].body, "3 processes outlived their session, using 1.0 GB")
    }
}
