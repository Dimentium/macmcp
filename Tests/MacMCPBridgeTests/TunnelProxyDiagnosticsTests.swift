import Foundation
import XCTest
@testable import MacMCPBridge

final class TunnelProxyDiagnosticsTests: XCTestCase {
    func testRecordsOnlyToolCategoryAndResultState() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("chatgpt-tunnel-proxy.log")
        let diagnostics = TunnelProxyDiagnostics(store: TunnelClientLogStore(fileURL: fileURL))

        diagnostics.observeRequest(Data("""
        {"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"macMCP.mail.search","arguments":{"query":"private@example.com"}}}
        """.appending("\n").utf8))
        diagnostics.observeResponse(Data("""
        {"jsonrpc":"2.0","id":7,"result":{"isError":false,"content":[{"type":"text","text":"private message body"}]}}
        """.appending("\n").utf8))

        let log = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(log.contains("tunnel-proxy request mail"))
        XCTAssertTrue(log.contains("tunnel-proxy response mail ok"))
        XCTAssertFalse(log.contains("private@example.com"))
        XCTAssertFalse(log.contains("private message body"))
        XCTAssertFalse(log.contains("\"id\":7"))
    }

    func testDropsMalformedAndNonToolTraffic() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("chatgpt-tunnel-proxy.log")
        let diagnostics = TunnelProxyDiagnostics(store: TunnelClientLogStore(fileURL: fileURL))

        diagnostics.observeRequest(Data("not json\n".utf8))
        diagnostics.observeRequest(Data("{\"jsonrpc\":\"2.0\",\"method\":\"initialize\"}\n".utf8))

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testRecordsToolAndRPCFailuresWithoutResultContent() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("chatgpt-tunnel-proxy.log")
        let diagnostics = TunnelProxyDiagnostics(store: TunnelClientLogStore(fileURL: fileURL))

        diagnostics.observeRequest(Data("""
        {"jsonrpc":"2.0","id":"one","method":"tools/call","params":{"name":"calendar.upcoming","arguments":{}}}
        {"jsonrpc":"2.0","id":"two","method":"tools/call","params":{"name":"reminders.list","arguments":{}}}
        """.appending("\n").utf8))
        diagnostics.observeResponse(Data("""
        {"jsonrpc":"2.0","id":"one","result":{"isError":true,"content":[{"text":"private failure"}]}}
        {"jsonrpc":"2.0","id":"two","error":{"code":-32603,"message":"private rpc failure"}}
        """.appending("\n").utf8))

        let log = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(log.contains("tunnel-proxy response calendar tool-error"))
        XCTAssertTrue(log.contains("tunnel-proxy response reminders rpc-error"))
        XCTAssertFalse(log.contains("private failure"))
        XCTAssertFalse(log.contains("private rpc failure"))
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
