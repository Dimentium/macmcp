import Darwin
import Dispatch
import Foundation
import MCP

enum LocalBridgeIPC {
    static func defaultSocketURL() -> URL {
        LocalUserPaths.homeDirectoryURL()
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("mac-agent-bridge", isDirectory: true)
            .appendingPathComponent("mcp.sock")
    }

    static func requestBridgeStatus(socketPath: String = defaultSocketURL().path) throws -> String {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw LocalBridgeIPCClientError.unavailable
        }
        defer { close(fd) }

        do {
            try configureRequestTimeout(fd)
            try UnixSocketAddress.withSockAddr(path: socketPath) { address, length in
                guard connect(fd, address, length) == 0 else {
                    throw LocalBridgeIPCClientError.unavailable
                }
            }
            try writeJSONLine(bridgeStatusRequest(), to: fd)
            let response = try readJSONLine(from: fd)
            let text = try bridgeStatusText(from: response)
            let status = try JSONDecoder().decode(BridgeStatus.self, from: Data(text.utf8))
            return try status.encodedJSON()
        } catch let error as LocalBridgeIPCClientError {
            throw error
        } catch {
            throw LocalBridgeIPCClientError.invalidResponse
        }
    }

    private static func configureRequestTimeout(_ fd: Int32) throws {
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        var suppressSIGPIPE: Int32 = 1
        let length = socklen_t(MemoryLayout<timeval>.size)
        let optionLength = socklen_t(MemoryLayout<Int32>.size)
        guard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, length) == 0,
              setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, length) == 0,
              setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &suppressSIGPIPE, optionLength) == 0
        else {
            throw LocalBridgeIPCClientError.unavailable
        }
    }

    private static func bridgeStatusRequest() -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": [
                "name": "bridge_status",
                "arguments": [:]
            ]
        ]
    }

    private static func writeJSONLine(_ object: [String: Any], to fd: Int32) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(UInt8(ascii: "\n"))
        try data.withUnsafeBytes { rawBuffer in
            guard var base = rawBuffer.baseAddress else { return }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let written = write(fd, base, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw LocalBridgeIPCClientError.unavailable
                }
                if written == 0 {
                    throw LocalBridgeIPCClientError.unavailable
                }
                base += written
                remaining -= written
            }
        }
    }

    private static func readJSONLine(from fd: Int32) throws -> [String: Any] {
        var line = Data()
        var byte = [UInt8](repeating: 0, count: 1)
        while line.count < 1_048_576 {
            let count = read(fd, &byte, 1)
            if count < 0 {
                if errno == EINTR { continue }
                throw LocalBridgeIPCClientError.unavailable
            }
            if count == 0 {
                throw LocalBridgeIPCClientError.unavailable
            }
            if byte[0] == UInt8(ascii: "\n") {
                let object = try JSONSerialization.jsonObject(with: line)
                guard let dictionary = object as? [String: Any] else {
                    throw LocalBridgeIPCClientError.invalidResponse
                }
                return dictionary
            }
            line.append(byte[0])
        }
        throw LocalBridgeIPCClientError.invalidResponse
    }

    private static func bridgeStatusText(from response: [String: Any]) throws -> String {
        if response["error"] != nil {
            throw LocalBridgeIPCClientError.invalidResponse
        }
        guard
            let result = response["result"] as? [String: Any],
            let content = result["content"] as? [[String: Any]],
            let first = content.first,
            first["type"] as? String == "text",
            let text = first["text"] as? String
        else {
            throw LocalBridgeIPCClientError.invalidResponse
        }
        return text
    }
}

enum LocalBridgeIPCServerError: LocalizedError, Equatable {
    case socketFailed
    case bindFailed
    case listenFailed

    var errorDescription: String? {
        switch self {
        case .socketFailed:
            return "Unable to create local MCP IPC socket"
        case .bindFailed:
            return "Unable to bind local MCP IPC socket"
        case .listenFailed:
            return "Unable to listen on local MCP IPC socket"
        }
    }
}

struct LocalBridgeIPCLimits: Equatable, Sendable {
    let maximumFrameBytes: Int
    let maximumActiveClients: Int
    let maximumConcurrentRequests: Int
    let requestTimeout: TimeInterval

    init(
        maximumFrameBytes: Int = 256 * 1024,
        maximumActiveClients: Int = 64,
        maximumConcurrentRequests: Int = 8,
        requestTimeout: TimeInterval = 30
    ) {
        self.maximumFrameBytes = max(1, maximumFrameBytes)
        self.maximumActiveClients = max(1, maximumActiveClients)
        self.maximumConcurrentRequests = max(1, maximumConcurrentRequests)
        self.requestTimeout = max(0.001, requestTimeout)
    }
}

enum LocalBridgeIPCClientError: LocalizedError, Equatable {
    case unavailable
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "MacMCP app-owned runtime is not available"
        case .invalidResponse:
            return "MacMCP app-owned runtime returned an invalid status response"
        }
    }
}

private struct JSONRPCMessage: Decodable {
    let id: Value?
    let method: String
    let params: Value?
}

private struct JSONRPCErrorObject: Encodable {
    let code: Int
    let message: String
}

private struct JSONRPCResponse: Encodable {
    let jsonrpc = "2.0"
    let id: Value?
    let result: Value?
    let error: JSONRPCErrorObject?
}

final class LocalBridgeIPCServer: @unchecked Sendable {
    typealias IdentityProvider = @Sendable (Int32) throws -> LocalClientIdentity

    private let socketURL: URL
    private let tools: [Tool]
    private let toolNames: Set<String>
    private let router: GatewayRouter
    private let policy: ReaderPolicy
    private let statusSource: BridgeStatusSource
    private let attachmentReader: AttachmentTextReader?
    private let mailActionAccess: MailActionAccessController?
    private let clientApprovalStore: ClientApprovalStore
    private let identityProvider: IdentityProvider
    private let onClientApprovalChanged: (@Sendable () -> Void)?
    private let limits: LocalBridgeIPCLimits
    private let requestLimiter: DispatchSemaphore
    private let lock = NSLock()
    private var listenerFD: Int32 = -1
    private var clientFDs: Set<Int32> = []
    private var acceptTask: Task<Void, Never>?

    init(
        socketURL: URL,
        tools: [Tool],
        router: GatewayRouter,
        policy: ReaderPolicy,
        statusSource: BridgeStatusSource,
        attachmentReader: AttachmentTextReader? = nil,
        mailActionAccess: MailActionAccessController? = nil,
        clientApprovalStore: ClientApprovalStore = ClientApprovalStore(),
        identityProvider: @escaping IdentityProvider = { try LocalClientIdentity.localPeer(fd: $0) },
        onClientApprovalChanged: (@Sendable () -> Void)? = nil,
        limits: LocalBridgeIPCLimits = LocalBridgeIPCLimits()
    ) {
        self.socketURL = socketURL
        self.tools = tools
        self.toolNames = Set(tools.map(\.name))
        self.router = router
        self.policy = policy
        self.statusSource = statusSource
        self.attachmentReader = attachmentReader
        self.mailActionAccess = mailActionAccess
        self.clientApprovalStore = clientApprovalStore
        self.identityProvider = identityProvider
        self.onClientApprovalChanged = onClientApprovalChanged
        self.limits = limits
        self.requestLimiter = DispatchSemaphore(value: limits.maximumConcurrentRequests)
    }

    func start() throws {
        try FileManager.default.createDirectory(
            at: socketURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        chmod(socketURL.deletingLastPathComponent().path, 0o700)
        try? FileManager.default.removeItem(at: socketURL)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw LocalBridgeIPCServerError.socketFailed
        }

        do {
            try UnixSocketAddress.withSockAddr(path: socketURL.path) { address, length in
                guard bind(fd, address, length) == 0 else {
                    throw LocalBridgeIPCServerError.bindFailed
                }
            }
            chmod(socketURL.path, 0o600)
            guard listen(fd, Int32(limits.maximumActiveClients)) == 0 else {
                throw LocalBridgeIPCServerError.listenFailed
            }
        } catch {
            close(fd)
            try? FileManager.default.removeItem(at: socketURL)
            throw error
        }

        lock.withLock {
            listenerFD = fd
        }
        acceptTask = Task.detached { [weak self] in
            await self?.acceptLoop(fd: fd)
        }
    }

    func stop() async {
        let fd: Int32 = lock.withLock {
            let fd = listenerFD
            listenerFD = -1
            return fd
        }
        if fd >= 0 {
            shutdown(fd, SHUT_RDWR)
            close(fd)
        }
        acceptTask?.cancel()
        acceptTask = nil

        let clients: [Int32] = lock.withLock {
            let clients = Array(clientFDs)
            clientFDs.removeAll()
            return clients
        }
        for client in clients {
            shutdown(client, SHUT_RDWR)
            close(client)
        }
        try? FileManager.default.removeItem(at: socketURL)
    }

    private func acceptLoop(fd: Int32) async {
        while !Task.isCancelled {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                break
            }
            configureClientSocket(client)
            let accepted = lock.withLock {
                guard clientFDs.count < limits.maximumActiveClients else { return false }
                clientFDs.insert(client)
                return true
            }
            guard accepted else {
                shutdown(client, SHUT_RDWR)
                close(client)
                continue
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.handleClient(fd: client)
            }
        }
    }

    private func configureClientSocket(_ fd: Int32) {
        var suppressSIGPIPE: Int32 = 1
        let length = socklen_t(MemoryLayout<Int32>.size)
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &suppressSIGPIPE, length)
    }

    // A stdio MCP client can hold a connection open indefinitely between requests.
    // Keep those blocking reads off Swift's cooperative executor.
    private func handleClient(fd: Int32) {
        defer {
            _ = lock.withLock {
                clientFDs.remove(fd)
            }
            close(fd)
        }

        let identity: LocalClientIdentity
        do {
            identity = try identityProvider(fd)
        } catch {
            return
        }

        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBufferPointer { pointer in
                read(fd, pointer.baseAddress, pointer.count)
            }
            if count == 0 { return }
            if count < 0 {
                if errno == EINTR { continue }
                return
            }
            pending.append(buffer, count: count)
            guard pending.count <= limits.maximumFrameBytes else { return }
            while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                let frame = pending[..<newline]
                pending = pending[(newline + 1)...]
                guard !frame.isEmpty else { continue }
                if let response = responseSynchronously(for: Data(frame), identity: identity) {
                    guard writeLine(response, to: fd) else { return }
                }
            }
        }
    }

    private func responseSynchronously(for frame: Data, identity: LocalClientIdentity) -> Data? {
        guard requestLimiter.wait(timeout: .now()) == .success else {
            return resourceErrorResponse(
                for: frame,
                code: -32004,
                message: "MacMCP local IPC is busy"
            )
        }
        let result = LocalBridgeIPCResponseBox()
        let completed = DispatchSemaphore(value: 0)
        let requestLimiter = requestLimiter
        Task { [weak self] in
            defer {
                requestLimiter.signal()
                completed.signal()
            }
            result.set(await self?.response(for: frame, identity: identity))
        }
        guard completed.wait(timeout: .now() + limits.requestTimeout) == .success else {
            return resourceErrorResponse(
                for: frame,
                code: -32003,
                message: "MacMCP local IPC request timed out"
            )
        }
        return result.value()
    }

    private func resourceErrorResponse(for frame: Data, code: Int, message: String) -> Data? {
        let id = (try? JSONDecoder().decode(JSONRPCMessage.self, from: frame))?.id
        return try? JSONEncoder().encode(JSONRPCResponse(
            id: id,
            result: nil,
            error: JSONRPCErrorObject(code: code, message: message)
        ))
    }

    private func response(for frame: Data, identity: LocalClientIdentity) async -> Data? {
        do {
            let message = try JSONDecoder().decode(JSONRPCMessage.self, from: frame)
            if message.id == nil {
                return nil
            }
            do {
                let result = try await handle(method: message.method, params: message.params, identity: identity)
                return try encodeResponse(id: message.id, result: result, error: nil)
            } catch let error as LocalBridgeJSONRPCError {
                return try? encodeResponse(
                    id: message.id,
                    result: nil,
                    error: JSONRPCErrorObject(code: error.code, message: error.message)
                )
            }
        } catch let error as LocalBridgeJSONRPCError {
            return try? encodeResponse(
                id: error.id,
                result: nil,
                error: JSONRPCErrorObject(code: error.code, message: error.message)
            )
        } catch {
            return try? encodeResponse(
                id: nil,
                result: nil,
                error: JSONRPCErrorObject(code: -32603, message: "Local MCP request failed")
            )
        }
    }

    private func handle(method: String, params: Value?, identity: LocalClientIdentity) async throws -> Value {
        switch method {
        case "initialize":
            return .object([
                "protocolVersion": .string("2024-11-05"),
                "capabilities": .object(["tools": .object([:])]),
                "serverInfo": .object([
                    "name": .string(AppVersion.name),
                    "version": .string(AppVersion.version)
                ])
            ])
        case "ping":
            return .object([:])
        case "tools/list":
            return try Value(ListTools.Result(tools: tools))
        case "tools/call":
            let parameters = try decodeParams(CallTool.Parameters.self, from: params)
            let publicName = canonicalToolName(parameters.name)
            guard toolNames.contains(publicName) else {
                throw LocalBridgeJSONRPCError.unavailableTool
            }
            let result: CallTool.Result
            if publicName == "bridge_status" {
                result = await bridgeStatusResult(arguments: parameters.arguments)
            } else {
                try await requireApprovedClient(identity)
                if publicName == AttachmentTextReader.publicToolName {
                    guard let attachmentReader else {
                        throw LocalBridgeJSONRPCError.unavailableTool
                    }
                    result = await attachmentReader.read(arguments: parameters.arguments)
                } else {
                    if ReaderPolicy.mailActionToolNames.contains(publicName) {
                        guard let mailActionAccess else {
                            return try Value(CallTool.Result(
                                content: [.text(text: MailActionAccessController.disabledMessage, annotations: nil, _meta: nil)],
                                isError: true
                            ))
                        }
                        if let denial = await mailActionAccess.deniedMessage(
                            for: publicName,
                            arguments: parameters.arguments
                        ) {
                            return try Value(CallTool.Result(
                                content: [.text(text: denial, annotations: nil, _meta: nil)],
                                isError: true
                            ))
                        }
                    }
                    result = try await router.call(
                        publicName: publicName,
                        arguments: parameters.arguments,
                        policy: policy
                    )
                }
            }
            return try Value(result)
        default:
            throw LocalBridgeJSONRPCError.methodNotFound
        }
    }

    private func canonicalToolName(_ requestedName: String) -> String {
        let chatGPTPrefix = "macmcp."
        guard requestedName.lowercased().hasPrefix(chatGPTPrefix) else {
            return requestedName
        }
        return String(requestedName.dropFirst(chatGPTPrefix.count))
    }

    private func requireApprovedClient(_ identity: LocalClientIdentity) async throws {
        switch try await clientApprovalStore.authorize(identity) {
        case .approved:
            return
        case .approvalRequired:
            onClientApprovalChanged?()
            throw LocalBridgeJSONRPCError.clientApprovalRequired
        case .rejected:
            throw LocalBridgeJSONRPCError.clientRejected
        }
    }

    private func bridgeStatusResult(arguments: [String: Value]?) async -> CallTool.Result {
        guard arguments?.isEmpty ?? true else {
            return CallTool.Result(
                content: [.text(text: "bridge_status accepts no arguments", annotations: nil, _meta: nil)],
                isError: true
            )
        }
        do {
            let status = await statusSource.snapshot()
            let structuredContent: Value? = try Value(status)
            return CallTool.Result(
                content: [.text(text: try status.encodedJSON(), annotations: nil, _meta: nil)],
                structuredContent: structuredContent
            )
        } catch {
            return CallTool.Result(
                content: [.text(text: "Unable to encode status", annotations: nil, _meta: nil)],
                isError: true
            )
        }
    }

    private func decodeParams<T: Decodable>(_ type: T.Type, from value: Value?) throws -> T {
        guard let value else {
            throw LocalBridgeJSONRPCError.invalidParams
        }
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func encodeResponse(
        id: Value?,
        result: Value?,
        error: JSONRPCErrorObject?
    ) throws -> Data {
        try JSONEncoder().encode(JSONRPCResponse(id: id, result: result, error: error))
    }

    private func writeLine(_ data: Data, to fd: Int32) -> Bool {
        var message = data
        message.append(UInt8(ascii: "\n"))
        return message.withUnsafeBytes { rawBuffer in
            guard var base = rawBuffer.baseAddress else { return true }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let written = write(fd, base, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                if written == 0 { return false }
                base += written
                remaining -= written
            }
            return true
        }
    }
}

private struct LocalBridgeJSONRPCError: Error {
    let id: Value?
    let code: Int
    let message: String

    static let invalidParams = LocalBridgeJSONRPCError(
        id: nil,
        code: -32602,
        message: "Invalid MCP request parameters"
    )

    static let methodNotFound = LocalBridgeJSONRPCError(
        id: nil,
        code: -32601,
        message: "Unknown MCP method"
    )

    static let unavailableTool = LocalBridgeJSONRPCError(
        id: nil,
        code: -32601,
        message: "Reader tool is unavailable"
    )

    static let clientApprovalRequired = LocalBridgeJSONRPCError(
        id: nil,
        code: -32001,
        message: "Client approval required in MacMCP"
    )

    static let clientRejected = LocalBridgeJSONRPCError(
        id: nil,
        code: -32002,
        message: "Local MCP client rejected"
    )
}

private final class LocalBridgeIPCResponseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Data?

    func set(_ value: Data?) {
        lock.withLock {
            storedValue = value
        }
    }

    func value() -> Data? {
        lock.withLock { storedValue }
    }
}
