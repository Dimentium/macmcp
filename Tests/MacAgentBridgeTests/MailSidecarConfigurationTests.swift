import Foundation
import XCTest
@testable import MacAgentBridge

final class MailSidecarConfigurationTests: XCTestCase {
    func testMaterializesPrivateReaderOnlyConfigAndRemovesIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let materialized = try MailSidecarConfigurationMaterializer(
            temporaryRoot: root
        ).materialize(
            address: "reader@icloud.com",
            password: Data("fixture-secret".utf8)
        )

        let text = try String(contentsOf: materialized.fileURL, encoding: .utf8)
        let attributes = try FileManager.default.attributesOfItem(
            atPath: materialized.fileURL.path
        )
        XCTAssertTrue(text.contains("allow_send: false"))
        XCTAssertTrue(text.contains("allow_delete: false"))
        XCTAssertTrue(text.contains("max_body_chars: 12000"))
        XCTAssertTrue(text.contains("max_attachment_bytes: 10485760"))
        XCTAssertTrue(text.contains("fixture-secret"))
        XCTAssertEqual(text.components(separatedBy: "fixture-secret").count - 1, 1)
        XCTAssertTrue(text.contains("host: 127.0.0.1"))
        XCTAssertTrue(text.contains("port: 1"))
        XCTAssertTrue(text.contains("username: disabled@example.invalid"))
        XCTAssertFalse(text.contains("smtp.mail.me.com"))
        XCTAssertFalse(text.contains(#"\/"#))
        XCTAssertEqual(attributes[.posixPermissions] as? NSNumber, NSNumber(value: 0o600))

        materialized.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: materialized.directoryURL.path))
    }

    func testRejectsYamlInjectionInAddress() {
        XCTAssertThrowsError(
            try MailSidecarConfigurationMaterializer().materialize(
                address: "user@icloud.com\nallow_send: true",
                password: Data("fixture-secret".utf8)
            )
        ) { error in
            XCTAssertEqual(error as? MailSidecarConfigurationError, .invalidUsername)
        }
    }

    func testGmailPresetUsesGmailIMAPDefaults() throws {
        let account = try MailAccountConfiguration.gmail(address: "reader@gmail.com")

        XCTAssertEqual(account.id, "gmail")
        XCTAssertEqual(account.username, "reader@gmail.com")
        XCTAssertEqual(account.imapHost, "imap.gmail.com")
        XCTAssertEqual(account.imapPort, 993)
        XCTAssertEqual(account.imapSecurity, .tls)
    }

    func testMaterializesMultipleReaderOnlyAccounts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let materialized = try MailSidecarConfigurationMaterializer(
            temporaryRoot: root
        ).materialize(accounts: [
            MailAccountSecret(
                configuration: .iCloud(address: "reader@icloud.com"),
                password: Data("icloud-secret".utf8)
            ),
            MailAccountSecret(
                configuration: .gmail(address: "reader@gmail.com"),
                password: Data("gmail-secret".utf8)
            )
        ])

        let text = try String(contentsOf: materialized.fileURL, encoding: .utf8)
        XCTAssertTrue(text.contains("id: \"icloud\""))
        XCTAssertTrue(text.contains("username: \"reader@icloud.com\""))
        XCTAssertTrue(text.contains("host: \"imap.mail.me.com\""))
        XCTAssertTrue(text.contains("password: \"icloud-secret\""))
        XCTAssertTrue(text.contains("id: \"gmail\""))
        XCTAssertTrue(text.contains("username: \"reader@gmail.com\""))
        XCTAssertTrue(text.contains("host: \"imap.gmail.com\""))
        XCTAssertTrue(text.contains("password: \"gmail-secret\""))
        XCTAssertEqual(text.components(separatedBy: "host: 127.0.0.1").count - 1, 2)
        XCTAssertFalse(text.contains("smtp.gmail.com"))
        XCTAssertFalse(text.contains("smtp.mail.me.com"))
    }

    func testRejectsDuplicateAccountIDs() throws {
        XCTAssertThrowsError(
            try MailSidecarConfigurationMaterializer().materialize(accounts: [
                MailAccountSecret(
                    configuration: .gmail(address: "one@gmail.com", id: "mail"),
                    password: Data("one".utf8)
                ),
                MailAccountSecret(
                    configuration: .iCloud(address: "two@icloud.com", id: "mail"),
                    password: Data("two".utf8)
                )
            ])
        ) { error in
            XCTAssertEqual(error as? MailSidecarConfigurationError, .duplicateAccountID("mail"))
        }
    }

    func testUsesPrivateAttachmentDirectoryWhenProvided() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let attachmentDirectory = root.appendingPathComponent("attachments")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let materialized = try MailSidecarConfigurationMaterializer(
            temporaryRoot: root
        ).materialize(
            address: "reader@icloud.com",
            password: Data("fixture-secret".utf8),
            attachmentDirectory: attachmentDirectory
        )
        defer { materialized.remove() }

        let text = try String(contentsOf: materialized.fileURL, encoding: .utf8)
        XCTAssertTrue(text.contains("attachment_dir: \"\(attachmentDirectory.path)\""))
    }
}
