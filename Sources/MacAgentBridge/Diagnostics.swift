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
    }

    struct ClientApprovals: Codable, Equatable, Sendable {
        let availability: DiagnosticAvailability
        let approvedCount: Int
        let approvalPending: Bool
    }

    let schemaVersion: Int
    let product: String
    let version: String
    let configuration: Configuration
    let bridge: Bridge
    let clientApprovals: ClientApprovals
    let loginItem: String
    let tunnel: TunnelDiagnosticState

    func encodedJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}

struct MacMCPDiagnosticCollector {
    typealias BridgeStatusRequest = () throws -> String
    typealias TunnelHealthProbe = (_ clientPath: String) async -> Bool

    private let launchConfigurationStore: AppLaunchConfigurationStore
    private let clientApprovalStore: ClientApprovalStore
    private let bridgeStatusRequest: BridgeStatusRequest
    private let loginItemStatus: () -> LoginItemStatus
    private let tunnelHealthProbe: TunnelHealthProbe

    init(
        launchConfigurationStore: AppLaunchConfigurationStore = AppLaunchConfigurationStore(),
        clientApprovalStore: ClientApprovalStore = ClientApprovalStore(),
        bridgeStatusRequest: @escaping BridgeStatusRequest = { try LocalBridgeIPC.requestBridgeStatus() },
        loginItemStatus: @escaping () -> LoginItemStatus = { SMAppLoginItemController().status },
        tunnelHealthProbe: @escaping TunnelHealthProbe = ChatGPTTunnelSupervisor.defaultHealthProbe
    ) {
        self.launchConfigurationStore = launchConfigurationStore
        self.clientApprovalStore = clientApprovalStore
        self.bridgeStatusRequest = bridgeStatusRequest
        self.loginItemStatus = loginItemStatus
        self.tunnelHealthProbe = tunnelHealthProbe
    }

    func collect() async -> MacMCPDiagnosticReport {
        let configuration = collectConfiguration()
        let bridge = collectBridge()
        let approvals = await collectApprovals()
        let tunnel = await collectTunnel()

        return MacMCPDiagnosticReport(
            schemaVersion: 1,
            product: AppVersion.name,
            version: AppVersion.version,
            configuration: configuration,
            bridge: bridge,
            clientApprovals: approvals,
            loginItem: loginItemStatus().label,
            tunnel: tunnel
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
        return await tunnelHealthProbe(tunnel.clientPath) ? .running : .unavailable
    }
}
