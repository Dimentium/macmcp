import Foundation

enum DiagnosticAvailability: String, Codable, Equatable, Sendable {
    case available
    case notConfigured = "not_configured"
    case unavailable
}

enum TunnelDiagnosticState: String, Codable, Equatable, Sendable {
    case notConfigured = "not_configured"
    case clientUnavailable = "client_unavailable"
    case running
    case unavailable
}

struct MacMCPDiagnosticReport: Codable, Equatable, Sendable {
    struct Configuration: Codable, Equatable, Sendable {
        let availability: DiagnosticAvailability
        let mailAccountCount: Int
        let launchAtLogin: Bool
    }

    struct Bridge: Codable, Equatable, Sendable {
        let availability: DiagnosticAvailability
        let status: BridgeStatus?

        private enum CodingKeys: String, CodingKey {
            case availability
            case status
        }

        init(availability: DiagnosticAvailability, status: BridgeStatus?) {
            self.availability = availability
            self.status = status
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            availability = try container.decode(DiagnosticAvailability.self, forKey: .availability)
            status = try container.decodeIfPresent(BridgeStatus.self, forKey: .status)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(availability, forKey: .availability)
            if let status {
                try container.encode(status, forKey: .status)
            } else {
                try container.encodeNil(forKey: .status)
            }
        }
    }

    struct ClientApprovals: Codable, Equatable, Sendable {
        let availability: DiagnosticAvailability
        let approvedCount: Int
        let approvalPending: Bool
    }

    struct TunnelFailures: Codable, Equatable, Sendable {
        let availability: DiagnosticAvailability
        let recent: [ChatGPTTunnelFailure]
    }

    let schemaVersion: Int
    let product: String
    let version: String
    let configuration: Configuration
    let bridge: Bridge
    let clientApprovals: ClientApprovals
    let loginItem: String
    let tunnel: TunnelDiagnosticState
    let tunnelFailures: TunnelFailures

    func encodedJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}

struct MacMCPDiagnosticCollector {
    typealias BridgeStatusRequest = () throws -> String
    typealias TunnelHealthProbe = (_ clientPath: String, _ runtimeKey: String) async -> Bool

    private let launchConfigurationStore: AppLaunchConfigurationStore
    private let clientApprovalStore: ClientApprovalStore
    private let bridgeStatusRequest: BridgeStatusRequest
    private let loginItemStatus: () -> LoginItemStatus
    private let tunnelHealthProbe: TunnelHealthProbe
    private let tunnelFailureHistoryStore: TunnelFailureHistoryStore
    private let tunnelCredentialStore: any CredentialStore

    init(
        launchConfigurationStore: AppLaunchConfigurationStore = AppLaunchConfigurationStore(),
        clientApprovalStore: ClientApprovalStore = ClientApprovalStore(),
        bridgeStatusRequest: @escaping BridgeStatusRequest = { try LocalBridgeIPC.requestBridgeStatus() },
        loginItemStatus: @escaping () -> LoginItemStatus = { SMAppLoginItemController().status },
        tunnelHealthProbe: @escaping TunnelHealthProbe = ChatGPTTunnelSupervisor.defaultHealthProbe,
        tunnelFailureHistoryStore: TunnelFailureHistoryStore = TunnelFailureHistoryStore(),
        tunnelCredentialStore: any CredentialStore = MigratingCredentialStore.chatGPTTunnel()
    ) {
        self.launchConfigurationStore = launchConfigurationStore
        self.clientApprovalStore = clientApprovalStore
        self.bridgeStatusRequest = bridgeStatusRequest
        self.loginItemStatus = loginItemStatus
        self.tunnelHealthProbe = tunnelHealthProbe
        self.tunnelFailureHistoryStore = tunnelFailureHistoryStore
        self.tunnelCredentialStore = tunnelCredentialStore
    }

    func collect() async -> MacMCPDiagnosticReport {
        let configuration = collectConfiguration()
        let bridge = collectBridge()
        let approvals = await collectApprovals()
        let tunnel = await collectTunnel()
        let tunnelFailures = collectTunnelFailures()

        return MacMCPDiagnosticReport(
            schemaVersion: 1,
            product: AppVersion.name,
            version: AppVersion.version,
            configuration: configuration,
            bridge: bridge,
            clientApprovals: approvals,
            loginItem: loginItemStatus().label,
            tunnel: tunnel,
            tunnelFailures: tunnelFailures
        )
    }

    private func collectConfiguration() -> MacMCPDiagnosticReport.Configuration {
        do {
            guard let configuration = try launchConfigurationStore.readConfiguration() else {
                return .init(
                    availability: .notConfigured,
                    mailAccountCount: 0,
                    launchAtLogin: false
                )
            }
            let launch = try CommandLineInterface.launchConfiguration(arguments: configuration.args)
            return .init(
                availability: .available,
                mailAccountCount: launch.mailAccounts.count,
                launchAtLogin: configuration.launchAtLogin
            )
        } catch {
            return .init(
                availability: .unavailable,
                mailAccountCount: 0,
                launchAtLogin: false
            )
        }
    }

    private func collectBridge() -> MacMCPDiagnosticReport.Bridge {
        do {
            let text = try bridgeStatusRequest()
            let status = try JSONDecoder().decode(BridgeStatus.self, from: Data(text.utf8))
            return .init(availability: .available, status: status)
        } catch {
            return .init(availability: .unavailable, status: nil)
        }
    }

    private func collectApprovals() async -> MacMCPDiagnosticReport.ClientApprovals {
        do {
            let snapshot = try await clientApprovalStore.snapshot()
            return .init(
                availability: .available,
                approvedCount: snapshot.approved.count,
                approvalPending: snapshot.pending != nil
            )
        } catch {
            return .init(availability: .unavailable, approvedCount: 0, approvalPending: false)
        }
    }

    private func collectTunnel() async -> TunnelDiagnosticState {
        guard let configuration = try? launchConfigurationStore.readConfiguration(),
              let tunnel = configuration.chatGPTTunnel
        else {
            return .notConfigured
        }
        guard FileManager.default.isExecutableFile(atPath: tunnel.clientPath) else {
            return .clientUnavailable
        }
        guard var key = try? tunnelCredentialStore.readSecret(
            account: KeychainCredentialStore.chatGPTTunnelAccount
        ), !key.isEmpty else {
            return .unavailable
        }
        defer { key.resetBytes(in: 0..<key.count) }
        return await tunnelHealthProbe(tunnel.clientPath, String(decoding: key, as: UTF8.self)) ? .running : .unavailable
    }

    private func collectTunnelFailures() -> MacMCPDiagnosticReport.TunnelFailures {
        do {
            return .init(availability: .available, recent: try tunnelFailureHistoryStore.read())
        } catch {
            return .init(availability: .unavailable, recent: [])
        }
    }
}
