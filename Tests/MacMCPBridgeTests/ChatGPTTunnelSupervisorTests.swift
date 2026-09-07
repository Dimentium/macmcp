import Foundation
import XCTest
@testable import MacMCPBridge

private struct FixedTunnelCredentialStore: CredentialStore {
    func readSecret(account: String) throws -> Data {
        Data("test-runtime-key".utf8)
    }

    func storeSecret(_ secret: Data, account: String) throws {}

    func deleteSecret(account: String) throws {}
}

@MainActor
final class ChatGPTTunnelSupervisorTests: XCTestCase {
    func testDefaultProxyWrapperPathAvoidsSpaces() {
        let homeDirectory = URL(fileURLWithPath: "/Users/test", isDirectory: true)

        let proxyURL = ChatGPTTunnelSupervisor.defaultProxyWrapperURL(homeDirectory: homeDirectory)

        XCTAssertEqual(proxyURL.path, "/Users/test/Library/Caches/macmcp/chatgpt-tunnel-proxy")
        XCTAssertFalse(proxyURL.path.contains(" "))
    }

    func testStartsManagedClientWithPrivateStdioProxy() async throws {
        let directory = try temporaryDirectory()
        let traceURL = directory.appendingPathComponent("trace")
        let clientURL = directory.appendingPathComponent("tunnel-client")
        let socketURL = directory.appendingPathComponent("mcp.sock")
        let bridgeURL = directory.appendingPathComponent("macmcp-bridge")
        let proxyURL = directory.appendingPathComponent("chatgpt-tunnel-proxy")
        let readyURL = directory.appendingPathComponent("ready")
        let tunnelLogStore = TunnelClientLogStore(fileURL: directory.appendingPathComponent("chatgpt-tunnel.log"))

        try Data().write(to: socketURL)
        try "#!/bin/bash\nexit 0\n".write(to: bridgeURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: bridgeURL.path
        )
        try """
        #!/bin/bash
        printf '%s\\n' "$1" >> '\(traceURL.path)'
        printf '%s\\n' '{"level":"info","msg":"tunnel client ready","component":"test"}'
        if [[ "$1" == "run" ]]; then
          touch '\(readyURL.path)'
          while true; do sleep 1; done
        fi
        """.write(to: clientURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: clientURL.path
        )

        let running = expectation(description: "managed client running")
        let supervisor = ChatGPTTunnelSupervisor(
            configuration: ChatGPTTunnelConfiguration(
                tunnelID: "tunnel_0123456789abcdef0123456789abcdef",
                clientPath: clientURL.path,
                profile: "macmcp-local"
            ),
            bridgeExecutableURL: bridgeURL,
            ipcSocketURL: socketURL,
            proxyWrapperURL: proxyURL,
            credentialStore: FixedTunnelCredentialStore(),
            tunnelLogStore: tunnelLogStore,
            healthProbe: { _ in true },
            onStateChanged: { state in
                if state == .running {
                    running.fulfill()
                }
            }
        )

        await supervisor.start()
        await fulfillment(of: [running], timeout: 2)
        try await waitForFile(readyURL)
        await supervisor.stop()

        XCTAssertEqual(try String(contentsOf: traceURL, encoding: .utf8).split(separator: "\n"), ["init", "doctor", "run"])
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: proxyURL.path))
        let proxy = try String(contentsOf: proxyURL, encoding: .utf8)
        XCTAssertTrue(proxy.contains("--stdio-proxy"))
        XCTAssertTrue(proxy.contains(socketURL.path))
        let log = try String(contentsOf: tunnelLogStore.fileURL, encoding: .utf8)
        XCTAssertTrue(log.contains("tunnel client ready"))
        XCTAssertTrue(log.contains("[stdout]"))
    }

    func testHungHealthProbeTimesOutAndDoesNotOverwriteUnavailableState() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clientURL = directory.appendingPathComponent("tunnel-client")
        let socketURL = directory.appendingPathComponent("mcp.sock")
        let bridgeURL = directory.appendingPathComponent("macmcp-bridge")
        let proxyURL = directory.appendingPathComponent("chatgpt-tunnel-proxy")
        let failureHistoryStore = TunnelFailureHistoryStore(
            fileURL: directory.appendingPathComponent("tunnel-failures.json")
        )

        try Data().write(to: socketURL)
        try "#!/bin/bash\nexit 0\n".write(to: bridgeURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: bridgeURL.path
        )
        try """
        #!/bin/bash
        if [[ "$1" == "run" ]]; then
          while true; do sleep 1; done
        fi
        """.write(to: clientURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: clientURL.path
        )

        let unavailable = expectation(description: "health probe timed out")
        let supervisor = ChatGPTTunnelSupervisor(
            configuration: ChatGPTTunnelConfiguration(
                tunnelID: "tunnel_0123456789abcdef0123456789abcdef",
                clientPath: clientURL.path,
                profile: "macmcp-local"
            ),
            bridgeExecutableURL: bridgeURL,
            ipcSocketURL: socketURL,
            proxyWrapperURL: proxyURL,
            credentialStore: FixedTunnelCredentialStore(),
            failureHistoryStore: failureHistoryStore,
            healthProbe: { _ in
                try? await Task.sleep(nanoseconds: 100_000_000)
                return true
            },
            healthProbeTimeoutNanoseconds: 10_000_000,
            onStateChanged: { state in
                if state == .unavailable {
                    unavailable.fulfill()
                }
            }
        )

        await supervisor.start()
        await fulfillment(of: [unavailable], timeout: 1)
        XCTAssertEqual(supervisor.state, .unavailable)
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(supervisor.state, .unavailable)
        let failures = try failureHistoryStore.read()
        XCTAssertEqual(failures.last?.phase, .health)
        XCTAssertEqual(failures.last?.reason, .healthTimedOut)
        await supervisor.stop()
    }

    func testMissingClientPersistsPrerequisiteFailure() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let failureHistoryStore = TunnelFailureHistoryStore(
            fileURL: directory.appendingPathComponent("tunnel-failures.json")
        )
        let supervisor = ChatGPTTunnelSupervisor(
            configuration: ChatGPTTunnelConfiguration(
                tunnelID: "tunnel_0123456789abcdef0123456789abcdef",
                clientPath: directory.appendingPathComponent("missing-client").path,
                profile: "macmcp-local"
            ),
            bridgeExecutableURL: directory.appendingPathComponent("macmcp-bridge"),
            ipcSocketURL: directory.appendingPathComponent("mcp.sock"),
            proxyWrapperURL: directory.appendingPathComponent("chatgpt-tunnel-proxy"),
            credentialStore: FixedTunnelCredentialStore(),
            failureHistoryStore: failureHistoryStore
        )

        await supervisor.start()

        XCTAssertEqual(supervisor.state, .unavailable)
        let failures = try failureHistoryStore.read()
        XCTAssertEqual(failures.last?.phase, .prerequisites)
        XCTAssertEqual(failures.last?.reason, .clientUnavailable)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private func waitForFile(_ url: URL) async throws {
        for _ in 0..<20 {
            if FileManager.default.fileExists(atPath: url.path) { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw NSError(domain: "ChatGPTTunnelSupervisorTests", code: 1)
    }
}
