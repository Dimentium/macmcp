import Foundation
import XCTest
@testable import MacMCPBridge

final class TunnelClientLogTests: XCTestCase {
    func testRedactsSecretsAndRendersUsefulTunnelFields() throws {
        let entry = try XCTUnwrap(TunnelClientLogRedactor.entry(
            source: .stdout,
            data: Data("""
            {"level":"info","msg":"delivered Bearer sk-supersecret for tunnel_abcdef","component":"dispatcher","request_kind":"json_rpc","channel":"main","status_code":200,"payload":"subject: private@example.com"}
            """.utf8),
            date: Date(timeIntervalSince1970: 0)
        ))
        let text = String(decoding: entry, as: UTF8.self)
        XCTAssertTrue(text.contains("INFO [stdout] [dispatcher]"))
        XCTAssertTrue(text.contains("request_kind=json_rpc"))
        XCTAssertTrue(text.contains("status_code=200"))
        XCTAssertFalse(text.contains("sk-supersecret"))
        XCTAssertFalse(text.contains("tunnel_abcdef"))
        XCTAssertFalse(text.contains("private@example.com"))
        XCTAssertFalse(text.contains("payload"))
    }

    func testDropsRoutineStartupNoise() {
        let entry = TunnelClientLogRedactor.entry(
            source: .stdout,
            data: Data("{\"level\":\"info\",\"msg\":\"OnStart hook executed\"}".utf8),
            date: Date(timeIntervalSince1970: 0)
        )

        XCTAssertNil(entry)
    }

    func testDropsRawAndUnparseableTunnelOutput() {
        XCTAssertNil(TunnelClientLogRedactor.entry(
            source: .stderr,
            data: Data("bridge failed for reader@example.com with Bearer sk-secret".utf8),
            date: Date(timeIntervalSince1970: 0)
        ))
        XCTAssertNil(TunnelClientLogRedactor.entry(
            source: .stdout,
            data: Data("{not valid json}".utf8),
            date: Date(timeIntervalSince1970: 0)
        ))
    }

    func testKeepsOnlyAllowlistedFieldsFromStructuredTunnelOutput() throws {
        let entry = try XCTUnwrap(TunnelClientLogRedactor.entry(
            source: .stderr,
            data: Data("""
            {"level":"error","msg":"tunnel call failed","component":"dispatcher","error":"connection reset","client_instance_id":"private-client","stacktrace":{"path":"/private/path","token":"secret"}}
            """.utf8),
            date: Date(timeIntervalSince1970: 0)
        ))
        let text = String(decoding: entry, as: UTF8.self)

        XCTAssertTrue(text.contains("ERROR [stderr] [dispatcher] tunnel call failed error=connection reset"))
        XCTAssertFalse(text.contains("private-client"))
        XCTAssertFalse(text.contains("stacktrace"))
        XCTAssertFalse(text.contains("/private/path"))
        XCTAssertFalse(text.contains("secret"))
    }

    func testRotatesAtConfiguredLimitAndKeepsPrivateFiles() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("chatgpt-tunnel.log")
        let store = TunnelClientLogStore(fileURL: fileURL, maximumBytes: 180, archivedFileCount: 2)

        store.recordLifecycle("first record with enough content to rotate at a small test limit")
        store.recordLifecycle("second record with enough content to rotate at a small test limit")
        store.recordLifecycle("third record with enough content to rotate at a small test limit")

        let current = try String(contentsOf: fileURL, encoding: .utf8)
        let archive = try String(contentsOf: directory.appendingPathComponent("chatgpt-tunnel.1.log"), encoding: .utf8)
        XCTAssertTrue(current.contains("third record"))
        XCTAssertTrue(archive.contains("second record"))
        XCTAssertLessThanOrEqual(try fileSize(fileURL), 180)
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)
    }

    func testCaptureWritesOnlyStructuredTunnelOutput() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("chatgpt-tunnel.log")
        let store = TunnelClientLogStore(fileURL: fileURL)
        let capture = TunnelClientLogCapture(store: store)

        capture.standardOutput.fileHandleForWriting.write(Data("{\"level\":\"info\",\"msg\":\"request delivered\",\"status_code\":200}\n".utf8))
        capture.standardError.fileHandleForWriting.write(Data("bridge failed for reader@example.com\n".utf8))
        capture.standardOutput.fileHandleForWriting.closeFile()
        capture.standardError.fileHandleForWriting.closeFile()
        capture.finish()

        let text = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(text.contains("request delivered"))
        XCTAssertFalse(text.contains("[stderr]"))
        XCTAssertFalse(text.contains("reader@example.com"))
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func fileSize(_ fileURL: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        return try XCTUnwrap(attributes[.size] as? NSNumber).intValue
    }
}
