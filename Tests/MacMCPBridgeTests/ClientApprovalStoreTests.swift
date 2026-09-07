import XCTest
@testable import MacMCPBridge

final class ClientApprovalStoreTests: XCTestCase {
    func testUnknownSameUserClientRequiresApprovalAndCanBeApproved() async throws {
        let fileURL = try temporaryStoreURL()
        let identity = LocalClientIdentity(
            uid: 501,
            pid: 123,
            executablePath: "/Applications/Codex.app/Contents/MacOS/Codex",
            executableSHA256: "abc123"
        )
        let store = ClientApprovalStore(fileURL: fileURL, expectedUID: 501)

        let firstDecision = try await store.authorize(identity, now: Date(timeIntervalSince1970: 10))
        let pending = try await store.snapshot().pending

        XCTAssertEqual(firstDecision, .approvalRequired)
        XCTAssertEqual(pending, identity)

        let approved = try await store.approvePending(now: Date(timeIntervalSince1970: 20))
        let secondDecision = try await store.authorize(identity, now: Date(timeIntervalSince1970: 30))
        let snapshot = try await store.snapshot()

        XCTAssertEqual(approved?.displayName, "Codex")
        XCTAssertEqual(secondDecision, .approved)
        XCTAssertNil(snapshot.pending)
        XCTAssertEqual(snapshot.approved.count, 1)
        XCTAssertEqual(snapshot.approved[0].lastSeenAt, Date(timeIntervalSince1970: 30))
    }

    func testDifferentUserClientIsRejectedAndNotStoredAsPending() async throws {
        let fileURL = try temporaryStoreURL()
        let identity = LocalClientIdentity(uid: 502, pid: 123, executablePath: "/tmp/client")
        let store = ClientApprovalStore(fileURL: fileURL, expectedUID: 501)

        let decision = try await store.authorize(identity)
        let snapshot = try await store.snapshot()

        XCTAssertEqual(decision, .rejected)
        XCTAssertNil(snapshot.pending)
        XCTAssertTrue(snapshot.approved.isEmpty)
    }

    func testRevokesApprovedClient() async throws {
        let fileURL = try temporaryStoreURL()
        let identity = LocalClientIdentity(uid: 501, executablePath: "/tmp/client")
        let store = ClientApprovalStore(fileURL: fileURL, expectedUID: 501)

        _ = try await store.authorize(identity)
        let pendingApproval = try await store.approvePending()
        let approved = try XCTUnwrap(pendingApproval)
        try await store.revoke(fingerprint: approved.fingerprint)

        let snapshot = try await store.snapshot()
        let decision = try await store.authorize(identity)
        XCTAssertTrue(snapshot.approved.isEmpty)
        XCTAssertEqual(decision, .approvalRequired)
    }

    func testApprovingNewHashReplacesOldGrantForSameExecutable() async throws {
        let fileURL = try temporaryStoreURL()
        let oldIdentity = LocalClientIdentity(uid: 501, executablePath: "/tmp/client", executableSHA256: "old")
        let newIdentity = LocalClientIdentity(uid: 501, executablePath: "/tmp/client", executableSHA256: "new")
        let store = ClientApprovalStore(fileURL: fileURL, expectedUID: 501)

        _ = try await store.authorize(oldIdentity)
        _ = try await store.approvePending()
        _ = try await store.authorize(newIdentity)
        _ = try await store.approvePending()

        let snapshot = try await store.snapshot()
        XCTAssertEqual(snapshot.approved.map(\.identity.executableSHA256), ["new"])
    }

    func testApprovingAppOwnedTunnelProxyDoesNotRequirePendingApproval() async throws {
        let fileURL = try temporaryStoreURL()
        let identity = LocalClientIdentity(
            uid: 501,
            executablePath: "/Applications/MacMCP.app/Contents/MacOS/MacMCP",
            executableSHA256: "current"
        )
        let store = ClientApprovalStore(fileURL: fileURL, expectedUID: 501)

        let approved = try await store.approveAppOwnedTunnelProxy(
            identity,
            now: Date(timeIntervalSince1970: 10)
        )
        let decision = try await store.authorize(identity, now: Date(timeIntervalSince1970: 20))
        let snapshot = try await store.snapshot()

        XCTAssertEqual(approved?.fingerprint, identity.fingerprint)
        XCTAssertEqual(decision, .approved)
        XCTAssertNil(snapshot.pending)
        XCTAssertEqual(snapshot.approved.count, 1)
        XCTAssertEqual(snapshot.approved[0].lastSeenAt, Date(timeIntervalSince1970: 20))
    }

    func testAuthorizingCurrentHashRemovesStaleGrantForSameExecutable() async throws {
        let fileURL = try temporaryStoreURL()
        let oldIdentity = LocalClientIdentity(uid: 501, executablePath: "/tmp/client", executableSHA256: "old")
        let currentIdentity = LocalClientIdentity(uid: 501, executablePath: "/tmp/client", executableSHA256: "current")
        let store = ClientApprovalStore(fileURL: fileURL, expectedUID: 501)
        try writeLegacyPayload(
            fileURL: fileURL,
            approved: [
                approvedClient(identity: oldIdentity, approvedAt: 10, lastSeenAt: 20),
                approvedClient(identity: currentIdentity, approvedAt: 30, lastSeenAt: 30)
            ]
        )

        let decision = try await store.authorize(currentIdentity, now: Date(timeIntervalSince1970: 40))
        let snapshot = try await store.snapshot()

        XCTAssertEqual(decision, .approved)
        XCTAssertEqual(snapshot.approved.map(\.identity.executableSHA256), ["current"])
        XCTAssertEqual(snapshot.approved[0].lastSeenAt, Date(timeIntervalSince1970: 40))
    }

    private func temporaryStoreURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("approved-clients.json")
    }

    private func approvedClient(
        identity: LocalClientIdentity,
        approvedAt: TimeInterval,
        lastSeenAt: TimeInterval
    ) -> ApprovedClient {
        ApprovedClient(
            fingerprint: identity.fingerprint,
            displayName: identity.displayName,
            identity: identity,
            approvedAt: Date(timeIntervalSince1970: approvedAt),
            lastSeenAt: Date(timeIntervalSince1970: lastSeenAt)
        )
    }

    private func writeLegacyPayload(fileURL: URL, approved: [ApprovedClient]) throws {
        struct LegacyPayload: Codable {
            let schemaVersion: Int
            let approved: [ApprovedClient]
            let pending: LocalClientIdentity?
        }

        let payload = LegacyPayload(schemaVersion: 1, approved: approved, pending: nil)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(payload).write(to: fileURL)
    }
}
