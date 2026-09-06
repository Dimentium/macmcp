import XCTest
@testable import MacAgentBridge

final class SidecarRecoveryStatusTests: XCTestCase {
    func testMailRestartMarksOnlyMailUnverified() async {
        let status = BridgeStatusSource(status: .connected(mail: true, eventKit: true))
        let observer = SidecarStatusObserver(statusSource: status)
        await status.updateMail(.ready)
        await status.updateCalendar(.ready)
        await status.updateReminders(.ready)

        await observer.handle(.restarting(id: ReaderPolicy.mailSidecarID, attempt: 1))

        let snapshot = await status.snapshot()
        XCTAssertEqual(snapshot.mail, .connectedUnverified)
        XCTAssertEqual(snapshot.mailRestartCount, 1)
        XCTAssertEqual(snapshot.eventKitRestartCount, 0)
        XCTAssertEqual(snapshot.calendar, .ready)
        XCTAssertEqual(snapshot.reminders, .ready)
    }

    func testEventKitRestartMarksOnlyEventKitComponentsUnverified() async {
        let status = BridgeStatusSource(status: .connected(mail: true, eventKit: true))
        let observer = SidecarStatusObserver(statusSource: status)
        await status.updateMail(.ready)
        await status.updateCalendar(.ready)
        await status.updateReminders(.ready)

        await observer.handle(.restarting(id: ReaderPolicy.eventKitSidecarID, attempt: 1))

        let snapshot = await status.snapshot()
        XCTAssertEqual(snapshot.mail, .ready)
        XCTAssertEqual(snapshot.mailRestartCount, 0)
        XCTAssertEqual(snapshot.eventKitRestartCount, 1)
        XCTAssertEqual(snapshot.calendar, .connectedUnverified)
        XCTAssertEqual(snapshot.reminders, .connectedUnverified)
    }
}
