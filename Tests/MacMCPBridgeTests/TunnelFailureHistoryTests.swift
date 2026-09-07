import Foundation
import XCTest
@testable import MacMCPBridge

final class TunnelFailureHistoryTests: XCTestCase {
    func testPersistsBoundedRedactedHistoryWithPrivatePermissions() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("tunnel-failures.json")
        let store = TunnelFailureHistoryStore(fileURL: fileURL, capacity: 2)

        try store.record(.init(
            occurredAt: "2026-09-06T10:00:00Z",
            phase: .initialize,
            reason: .processExited
        ))
        try store.record(.init(
            occurredAt: "2026-09-06T10:01:00Z",
            phase: .doctor,
            reason: .processLaunchFailed
        ))
        try store.record(.init(
            occurredAt: "2026-09-06T10:02:00Z",
            phase: .health,
            reason: .healthTimedOut
        ))

        let failures = try store.read()
        XCTAssertEqual(failures.map(\.phase), [.doctor, .health])
        XCTAssertEqual(failures.map(\.reason), [.processLaunchFailed, .healthTimedOut])
        XCTAssertFalse(try String(contentsOf: fileURL, encoding: .utf8).contains("tunnel_"))

        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)
    }

    func testRejectsUntrustedTimestampText() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("tunnel-failures.json")
        try """
        {"schemaVersion":1,"failures":[{"occurredAt":"reader.private@example.com","phase":"health","reason":"health_timed_out"}]}
        """.write(to: fileURL, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try TunnelFailureHistoryStore(fileURL: fileURL).read()) { error in
            XCTAssertEqual(error as? TunnelFailureHistoryStoreError, .corrupt)
        }
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
