import Foundation
import XCTest
@testable import MacAgentBridge

final class MonitorStateStoreTests: XCTestCase {
    func testDecodesMailMCPHandleAndAdvancesCheckpoint() async throws {
        let file = temporaryStateFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = try MonitorStateStore(fileURL: file)

        _ = try await store.observe(
            opaqueMessageID: "aWNsb3Vk.SU5CT1g.42.7",
            decision: decision(.normal)
        )
        _ = try await store.observe(
            opaqueMessageID: "aWNsb3Vk.SU5CT1g.42.9",
            decision: decision(.normal)
        )

        let checkpoint = await store.checkpoint(account: "icloud", mailbox: "INBOX")
        XCTAssertEqual(checkpoint?.uidValidity, 42)
        XCTAssertEqual(checkpoint?.highestUID, 9)
    }

    func testNotificationRepeatsOnlyWhenUrgencyChanges() async throws {
        let file = temporaryStateFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = try MonitorStateStore(fileURL: file)
        let id = "aWNsb3Vk.SU5CT1g.42.7"

        let first = try await store.observe(opaqueMessageID: id, decision: decision(.normal))
        let duplicate = try await store.observe(opaqueMessageID: id, decision: decision(.normal))
        let escalated = try await store.observe(opaqueMessageID: id, decision: decision(.immediate))

        XCTAssertTrue(first.shouldNotify)
        XCTAssertFalse(duplicate.shouldNotify)
        XCTAssertTrue(escalated.shouldNotify)
    }

    func testUIDValidityChangeResetsCheckpointEpoch() async throws {
        let file = temporaryStateFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = try MonitorStateStore(fileURL: file)

        _ = try await store.observe(
            opaqueMessageID: "aWNsb3Vk.SU5CT1g.42.100",
            decision: decision(.normal)
        )
        let changed = try await store.observe(
            opaqueMessageID: "aWNsb3Vk.SU5CT1g.43.2",
            decision: decision(.normal)
        )

        XCTAssertTrue(changed.uidValidityChanged)
        let checkpoint = await store.checkpoint(account: "icloud", mailbox: "INBOX")
        XCTAssertEqual(checkpoint?.highestUID, 2)
    }

    func testCorruptStateFailsClosed() throws {
        let file = temporaryStateFile()
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not-json".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        XCTAssertThrowsError(try MonitorStateStore(fileURL: file)) { error in
            XCTAssertEqual(error as? MonitorStateStoreError, .corruptState)
        }
    }

    private func decision(_ urgency: AttentionUrgency) -> AttentionDecision {
        AttentionDecision(
            needsAttention: true,
            categories: [.personal],
            urgency: urgency,
            reasonCode: .likelyHumanSender,
            confidence: 0.7
        )
    }

    private func temporaryStateFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("state.json")
    }
}
