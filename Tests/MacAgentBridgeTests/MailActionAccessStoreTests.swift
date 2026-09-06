import Foundation
import MCP
import XCTest
@testable import MacAgentBridge

final class MailActionAccessStoreTests: XCTestCase {
    func testAccountsAreReadOnlyByDefaultAndPersistWhenEnabled() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("mail-action-access.json")
        let store = MailActionAccessStore(fileURL: fileURL)

        let initiallyWritable = await store.isWritable(accountID: "gmail")
        XCTAssertFalse(initiallyWritable)
        try await store.setReadOnly(false, for: "gmail")
        let writableAfterEnabling = await store.isWritable(accountID: "gmail")
        XCTAssertTrue(writableAfterEnabling)

        let reloadedStore = MailActionAccessStore(fileURL: fileURL)
        let writableAfterReload = await reloadedStore.isWritable(accountID: "gmail")
        XCTAssertTrue(writableAfterReload)
        try await reloadedStore.setReadOnly(true, for: "gmail")
        let writableAfterDisabling = await reloadedStore.isWritable(accountID: "gmail")
        XCTAssertFalse(writableAfterDisabling)
    }

    func testControllerAppliesBothToggleDirectionsWithoutRestart() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MailActionAccessStore(fileURL: directory.appendingPathComponent("access.json"))
        let account = try MailAccountConfiguration.gmail(address: "reader@example.invalid")
        let controller = MailActionAccessController(accounts: [account], store: store)
        let createArguments: [String: Value] = ["account_id": .string(account.id)]
        let messageArguments: [String: Value] = [
            "message_id": .string("Z21haWw.SU5CT1g.42.7")
        ]

        let initiallyDenied = await controller.deniedMessage(
            for: "mail.create_managed_draft",
            arguments: createArguments
        )
        XCTAssertEqual(initiallyDenied, MailActionAccessController.disabledMessage)

        try await controller.setReadOnly(false, for: account.id)
        let createAllowed = await controller.deniedMessage(
            for: "mail.create_managed_draft",
            arguments: createArguments
        )
        XCTAssertNil(createAllowed)
        let markAllowed = await controller.deniedMessage(
            for: "mail.mark",
            arguments: messageArguments
        )
        XCTAssertNil(markAllowed)

        try await controller.setReadOnly(true, for: account.id)
        let markDenied = await controller.deniedMessage(
            for: "mail.mark",
            arguments: messageArguments
        )
        XCTAssertEqual(markDenied, MailActionAccessController.disabledMessage)
    }

    func testCorruptStateFileFailsClosed() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("mail-action-access.json")
        try Data("not json".utf8).write(to: fileURL)
        let store = MailActionAccessStore(fileURL: fileURL)

        let writable = await store.isWritable(accountID: "gmail")
        XCTAssertFalse(writable)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
