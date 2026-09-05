import XCTest
@testable import MacAgentBridge

final class SidecarStatusObserverTests: XCTestCase {
    func testMailTerminationMarksOnlyMailUnavailable() async {
        let status = BridgeStatusSource(status: .connected(mail: true, eventKit: true))
        let observer = SidecarStatusObserver(statusSource: status)

        await observer.handle(.stopped(id: ReaderPolicy.mailSidecarID, status: 1))
        let snapshot = await status.snapshot()

        XCTAssertEqual(snapshot.mail, .unavailable)
        XCTAssertEqual(snapshot.calendar, .connectedUnverified)
        XCTAssertEqual(snapshot.reminders, .connectedUnverified)
    }

    func testEventKitFailureMarksCalendarAndRemindersUnavailable() async {
        let status = BridgeStatusSource(status: .connected(mail: true, eventKit: true))
        let observer = SidecarStatusObserver(statusSource: status)

        await observer.handle(.failed(id: ReaderPolicy.eventKitSidecarID, reason: "restart_limit_reached"))
        let snapshot = await status.snapshot()

        XCTAssertEqual(snapshot.mail, .connectedUnverified)
        XCTAssertEqual(snapshot.calendar, .unavailable)
        XCTAssertEqual(snapshot.reminders, .unavailable)
    }
}
