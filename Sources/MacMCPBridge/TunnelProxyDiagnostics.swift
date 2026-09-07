import Foundation

/// Records only transport boundaries for the tunnel-owned stdio proxy.
/// Request arguments and MCP result content never enter this diagnostic log.
final class TunnelProxyDiagnostics: @unchecked Sendable {
    private enum Direction: Hashable {
        case request
        case response
    }

    private static let maximumBufferedLineBytes = 16 * 1024
    private static let maximumPendingRequests = 32

    private let store: TunnelClientLogStore
    private let lock = NSLock()
    private var buffers: [Direction: Data] = [:]
    private var requestCategories: [String: String] = [:]

    init(store: TunnelClientLogStore = TunnelClientLogStore(fileURL: TunnelProxyDiagnostics.defaultFileURL())) {
        self.store = store
    }

    static func enabledForCurrentProcess() -> TunnelProxyDiagnostics? {
        guard ProcessInfo.processInfo.environment["MACMCP_TUNNEL_PROXY"] == "1" else {
            return nil
        }
        return TunnelProxyDiagnostics()
    }

    static func defaultFileURL() -> URL {
        MacMCPPaths.logFile("chatgpt-tunnel-proxy.log")
    }

    func connected() {
        store.recordLifecycle("tunnel-proxy connected")
    }

    func disconnected() {
        store.recordLifecycle("tunnel-proxy disconnected")
    }

    func observeRequest(_ data: Data) {
        observe(data, direction: .request)
    }

    func observeResponse(_ data: Data) {
        observe(data, direction: .response)
    }

    private func observe(_ data: Data, direction: Direction) {
        guard !data.isEmpty else { return }
        let events: [String] = lock.withLock {
            var pending = buffers[direction] ?? Data()
            pending.append(data)
            if pending.count > Self.maximumBufferedLineBytes,
               !pending.contains(UInt8(ascii: "\n")) {
                buffers[direction] = Data()
                return ["tunnel-proxy \(label(for: direction)) oversized"]
            }

            var events: [String] = []
            while let newlineIndex = pending.firstIndex(of: UInt8(ascii: "\n")) {
                let line = Data(pending[..<newlineIndex])
                pending.removeSubrange(...newlineIndex)
                guard line.count <= Self.maximumBufferedLineBytes else {
                    events.append("tunnel-proxy \(label(for: direction)) oversized")
                    continue
                }
                if let event = event(for: line, direction: direction) {
                    events.append(event)
                }
            }
            buffers[direction] = pending
            return events
        }
        for event in events {
            store.recordLifecycle(event)
        }
    }

    private func event(for line: Data, direction: Direction) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: line),
              let fields = object as? [String: Any]
        else {
            return nil
        }

        switch direction {
        case .request:
            return requestEvent(fields)
        case .response:
            return responseEvent(fields)
        }
    }

    private func requestEvent(_ fields: [String: Any]) -> String? {
        guard fields["method"] as? String == "tools/call",
              let parameters = fields["params"] as? [String: Any],
              let name = parameters["name"] as? String
        else {
            return nil
        }

        let category = toolCategory(name)
        if let requestID = requestID(from: fields["id"]) {
            if requestCategories.count >= Self.maximumPendingRequests {
                requestCategories.removeAll()
            }
            requestCategories[requestID] = category
        }
        return "tunnel-proxy request \(category)"
    }

    private func responseEvent(_ fields: [String: Any]) -> String? {
        guard let requestID = requestID(from: fields["id"]),
              let category = requestCategories.removeValue(forKey: requestID)
        else {
            return nil
        }
        if fields["error"] != nil {
            return "tunnel-proxy response \(category) rpc-error"
        }
        if let result = fields["result"] as? [String: Any], result["isError"] as? Bool == true {
            return "tunnel-proxy response \(category) tool-error"
        }
        return "tunnel-proxy response \(category) ok"
    }

    private func requestID(from value: Any?) -> String? {
        if let number = value as? NSNumber {
            return "n:\(number.stringValue)"
        }
        guard let text = value as? String,
              text.utf8.count <= 64,
              !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            return nil
        }
        return "s:\(text)"
    }

    private func toolCategory(_ name: String) -> String {
        let normalized = name.lowercased().replacingOccurrences(of: "macmcp.", with: "")
        if normalized == "bridge_status" { return "bridge_status" }
        if normalized.hasPrefix("mail.") { return "mail" }
        if normalized.hasPrefix("calendar.") { return "calendar" }
        if normalized.hasPrefix("reminders.") { return "reminders" }
        return "other"
    }

    private func label(for direction: Direction) -> String {
        direction == .request ? "request" : "response"
    }
}
