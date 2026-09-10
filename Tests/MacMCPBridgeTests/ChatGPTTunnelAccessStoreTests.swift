import Foundation
import XCTest
@testable import MacMCPBridge

final class ChatGPTTunnelAccessStoreTests: XCTestCase {
    func testMissingStateKeepsConfiguredTunnelEnabled() async throws {
        let store = ChatGPTTunnelAccessStore(fileURL: temporaryFileURL())
        let enabled = await store.isEnabled()
        XCTAssertTrue(enabled)
    }

    func testTogglePersistsWithoutDeletingConfiguration() async throws {
        let fileURL = temporaryFileURL()
        let store = ChatGPTTunnelAccessStore(fileURL: fileURL)
        try await store.setEnabled(false)
        let disabled = await store.isEnabled()
        XCTAssertFalse(disabled)

        let reloaded = ChatGPTTunnelAccessStore(fileURL: fileURL)
        let reloadedDisabled = await reloaded.isEnabled()
        XCTAssertFalse(reloadedDisabled)
        try await reloaded.setEnabled(true)
        let reloadedEnabled = await reloaded.isEnabled()
        XCTAssertTrue(reloadedEnabled)
    }

    private func temporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("tunnel-access.json")
    }
}
