import Foundation
import MCP

private struct GatewayClientSlot: Sendable {
    let token: UUID
    let client: any SidecarToolClient
}

struct GatewayRoute: Equatable, Sendable {
    let publicName: String
    let sidecarID: String
    let upstreamName: String
}

enum GatewayError: LocalizedError, Equatable {
    case duplicateSidecar(String)
    case duplicateTool(String)
    case duplicateUpstreamTool(String)
    case missingUpstreamTool(String)
    case unknownTool(String)
    case sidecarNotConnected

    var errorDescription: String? {
        switch self {
        case .duplicateSidecar(let id):
            return "Sidecar \(id) is already attached"
        case .duplicateTool(let name):
            return "Gateway tool \(name) is already registered"
        case .duplicateUpstreamTool(let name):
            return "Pinned sidecar advertised a duplicate tool: \(name)"
        case .missingUpstreamTool(let name):
            return "Pinned sidecar does not provide required tool: \(name)"
        case .unknownTool:
            return "Unknown or unavailable tool"
        case .sidecarNotConnected:
            return "Sidecar is not connected"
        }
    }
}

actor GatewayRouter {
    private var clients: [String: GatewayClientSlot] = [:]
    private var routes: [String: GatewayRoute] = [:]
    private var projectedTools: [String: Tool] = [:]

    func attach(
        sidecarID: String,
        client: any SidecarToolClient,
        policy: ReaderPolicy
    ) async throws {
        try Task.checkCancellation()
        guard clients[sidecarID] == nil else {
            throw GatewayError.duplicateSidecar(sidecarID)
        }

        let token = UUID()
        clients[sidecarID] = GatewayClientSlot(token: token, client: client)

        do {
            try await client.connect()
            try ensureStillAttached(sidecarID: sidecarID, token: token)

            var cursor: String?
            var discovered: [Tool] = []
            repeat {
                let page = try await client.listTools(cursor: cursor)
                try ensureStillAttached(sidecarID: sidecarID, token: token)
                discovered.append(contentsOf: page.tools)
                cursor = page.nextCursor
            } while cursor != nil

            var upstreamByName: [String: Tool] = [:]
            for tool in discovered {
                guard upstreamByName[tool.name] == nil else {
                    throw GatewayError.duplicateUpstreamTool(tool.name)
                }
                upstreamByName[tool.name] = tool
            }

            var newRoutes: [String: GatewayRoute] = [:]
            var newTools: [String: Tool] = [:]
            for rule in policy.rules(for: sidecarID) {
                guard let upstream = upstreamByName[rule.upstreamName] else {
                    throw GatewayError.missingUpstreamTool(rule.upstreamName)
                }
                let publicName = rule.publicName
                guard routes[publicName] == nil, newRoutes[publicName] == nil else {
                    throw GatewayError.duplicateTool(publicName)
                }
                newRoutes[publicName] = GatewayRoute(
                    publicName: publicName,
                    sidecarID: sidecarID,
                    upstreamName: rule.upstreamName
                )
                newTools[publicName] = try policy.project(upstream: upstream, using: rule)
            }

            try ensureStillAttached(sidecarID: sidecarID, token: token)
            routes.merge(newRoutes, uniquingKeysWith: { existing, _ in existing })
            projectedTools.merge(newTools, uniquingKeysWith: { existing, _ in existing })
        } catch {
            if clients[sidecarID]?.token == token {
                clients.removeValue(forKey: sidecarID)
                await client.disconnect()
            }
            throw error
        }
    }

    func detach(sidecarID: String) async {
        guard let slot = clients.removeValue(forKey: sidecarID) else { return }
        let names = routes.values
            .filter { $0.sidecarID == sidecarID }
            .map(\.publicName)
        for name in names {
            routes.removeValue(forKey: name)
            projectedTools.removeValue(forKey: name)
        }
        await slot.client.disconnect()
    }

    func tools() -> [Tool] {
        projectedTools.values.sorted { $0.name < $1.name }
    }

    func route(for publicName: String) -> GatewayRoute? {
        routes[publicName]
    }

    func call(
        publicName: String,
        arguments: [String: Value]?,
        policy: ReaderPolicy
    ) async throws -> CallTool.Result {
        let result = try await callRaw(
            publicName: publicName,
            arguments: arguments,
            policy: policy
        )
        return UntrustedContentFilter().filter(result, publicToolName: publicName)
    }

    /// Internal monitor path. It still passes through the exact same static
    /// tool and argument policy, but returns bytes for typed decoding rather
    /// than presenting them to an agent.
    func callRaw(
        publicName: String,
        arguments: [String: Value]?,
        policy: ReaderPolicy
    ) async throws -> CallTool.Result {
        guard let route = routes[publicName], let slot = clients[route.sidecarID] else {
            throw GatewayError.unknownTool(publicName)
        }
        let prepared = try policy.prepareArguments(for: publicName, supplied: arguments)
        return try await slot.client.callTool(name: route.upstreamName, arguments: prepared)
    }

    private func ensureStillAttached(sidecarID: String, token: UUID) throws {
        guard clients[sidecarID]?.token == token else {
            throw GatewayError.sidecarNotConnected
        }
    }
}
