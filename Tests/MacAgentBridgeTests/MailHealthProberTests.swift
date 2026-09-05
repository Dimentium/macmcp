import Foundation
import MCP
import XCTest
@testable import MacAgentBridge

final class MailHealthProberTests: XCTestCase {
    func testSuccessfulProbeMarksMailReady() async {
        let status = BridgeStatusSource(status: .connected(mail: true, eventKit: false))
        let prober = MailHealthProber(
            statusSource: status,
            callTool: { name, arguments in
                XCTAssertEqual(name, "mail.server_info")
                XCTAssertNil(arguments)
                return CallTool.Result(content: [.text(text: "ok", annotations: nil, _meta: nil)])
            },
            onTimeout: {}
        )

        let succeeded = await prober.probe()
        let snapshot = await status.snapshot()

        XCTAssertTrue(succeeded)
        XCTAssertEqual(snapshot.mail, .ready)
    }

    func testFailedProbeMarksMailUnavailable() async {
        let status = BridgeStatusSource(status: .connected(mail: true, eventKit: false))
        let prober = MailHealthProber(
            statusSource: status,
            callTool: { _, _ in
                CallTool.Result(
                    content: [.text(text: "unavailable", annotations: nil, _meta: nil)],
                    isError: true
                )
            },
            onTimeout: {}
        )

        let succeeded = await prober.probe()
        let snapshot = await status.snapshot()

        XCTAssertFalse(succeeded)
        XCTAssertEqual(snapshot.mail, .unavailable)
    }
}
