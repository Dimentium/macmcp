import CryptoKit
import Darwin
import Foundation

struct LocalClientIdentity: Codable, Equatable, Sendable {
    let transport: String
    let uid: UInt32
    let pid: Int32?
    let executablePath: String?
    let executableSHA256: String?

    init(
        transport: String = "local-ipc",
        uid: UInt32,
        pid: Int32? = nil,
        executablePath: String? = nil,
        executableSHA256: String? = nil
    ) {
        self.transport = transport
        self.uid = uid
        self.pid = pid
        self.executablePath = executablePath
        self.executableSHA256 = executableSHA256
    }

    var fingerprint: String {
        [
            transport,
            String(uid),
            executablePath ?? "unknown-path",
            executableSHA256 ?? "unknown-sha256"
        ].joined(separator: ":")
    }

    var displayName: String {
        if let executablePath {
            return URL(fileURLWithPath: executablePath).lastPathComponent
        }
        if let pid {
            return "pid \(pid)"
        }
        return "uid \(uid)"
    }

    static func localPeer(fd: Int32) throws -> LocalClientIdentity {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0 else {
            throw ClientApprovalError.peerIdentityUnavailable
        }

        let pid = peerPID(fd: fd)
        let path = pid.flatMap { executablePath(pid: $0) }
        return LocalClientIdentity(
            uid: UInt32(uid),
            pid: pid,
            executablePath: path,
            executableSHA256: path.flatMap { sha256(filePath: $0) }
        )
    }

    static func currentProcess() -> LocalClientIdentity? {
        let pid = Int32(getpid())
        let path = executablePath(pid: pid)
        return LocalClientIdentity(
            uid: UInt32(geteuid()),
            pid: pid,
            executablePath: path,
            executableSHA256: path.flatMap { sha256(filePath: $0) }
        )
    }

    private static func peerPID(fd: Int32) -> Int32? {
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0 else {
            return nil
        }
        return pid > 0 ? Int32(pid) : nil
    }

    private static func executablePath(pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let count = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard count > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func sha256(filePath: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)) else {
            return nil
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct ApprovedClient: Codable, Equatable, Sendable {
    let fingerprint: String
    let displayName: String
    let identity: LocalClientIdentity
    let approvedAt: Date
    var lastSeenAt: Date
}

struct ClientApprovalSnapshot: Codable, Equatable, Sendable {
    let approved: [ApprovedClient]
    let pending: LocalClientIdentity?
}

enum ClientApprovalDecision: Equatable, Sendable {
    case approved
    case approvalRequired
    case rejected
}

enum ClientApprovalError: LocalizedError, Equatable {
    case peerIdentityUnavailable

    var errorDescription: String? {
        switch self {
        case .peerIdentityUnavailable:
            return "Local MCP client identity is unavailable"
        }
    }
}

actor ClientApprovalStore {
    private struct Payload: Codable {
        let schemaVersion: Int
        var approved: [ApprovedClient]
        var pending: LocalClientIdentity?
    }

    private let fileURL: URL
    private let expectedUID: UInt32

    init(
        fileURL: URL = ClientApprovalStore.defaultFileURL(),
        expectedUID: UInt32 = UInt32(geteuid())
    ) {
        self.fileURL = fileURL
        self.expectedUID = expectedUID
    }

    static func defaultFileURL() -> URL {
        LocalUserPaths.homeDirectoryURL()
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("mac-agent-bridge", isDirectory: true)
            .appendingPathComponent("approved-clients.json")
    }

    func authorize(_ identity: LocalClientIdentity, now: Date = Date()) throws -> ClientApprovalDecision {
        guard identity.uid == expectedUID else {
            return .rejected
        }

        var payload = try load()
        if let index = payload.approved.firstIndex(where: { $0.fingerprint == identity.fingerprint }) {
            payload.approved[index].lastSeenAt = now
            let approvedClient = payload.approved[index]
            payload.approved.removeAll {
                $0.fingerprint != approvedClient.fingerprint &&
                $0.identity.sameLocalExecutable(as: identity)
            }
            try save(payload)
            return .approved
        }

        payload.pending = identity
        try save(payload)
        return .approvalRequired
    }

    func approvePending(now: Date = Date()) throws -> ApprovedClient? {
        var payload = try load()
        guard let pending = payload.pending, pending.uid == expectedUID else {
            payload.pending = nil
            try save(payload)
            return nil
        }

        let client = ApprovedClient(
            fingerprint: pending.fingerprint,
            displayName: pending.displayName,
            identity: pending,
            approvedAt: now,
            lastSeenAt: now
        )
        payload.approved.removeAll {
            $0.fingerprint == client.fingerprint || $0.identity.sameLocalExecutable(as: pending)
        }
        payload.approved.append(client)
        payload.pending = nil
        try save(payload)
        return client
    }

    func approveAppOwnedTunnelProxy(
        _ identity: LocalClientIdentity,
        now: Date = Date()
    ) throws -> ApprovedClient? {
        guard identity.uid == expectedUID,
              identity.executablePath != nil,
              identity.executableSHA256 != nil
        else {
            return nil
        }

        var payload = try load()
        if let index = payload.approved.firstIndex(where: { $0.fingerprint == identity.fingerprint }) {
            payload.approved[index].lastSeenAt = now
            let approved = payload.approved[index]
            try save(payload)
            return approved
        }

        let client = ApprovedClient(
            fingerprint: identity.fingerprint,
            displayName: identity.displayName,
            identity: identity,
            approvedAt: now,
            lastSeenAt: now
        )
        payload.approved.removeAll { $0.identity.sameLocalExecutable(as: identity) }
        payload.approved.append(client)
        try save(payload)
        return client
    }

    func revoke(fingerprint: String) throws {
        var payload = try load()
        payload.approved.removeAll { $0.fingerprint == fingerprint }
        try save(payload)
    }

    func snapshot() throws -> ClientApprovalSnapshot {
        let payload = try load()
        return ClientApprovalSnapshot(
            approved: payload.approved.sorted { $0.displayName < $1.displayName },
            pending: payload.pending
        )
    }

    private func load() throws -> Payload {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return Payload(schemaVersion: 1, approved: [], pending: nil)
        }
        let data = try Data(contentsOf: fileURL)
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard payload.schemaVersion == 1 else {
            return Payload(schemaVersion: 1, approved: [], pending: nil)
        }
        return payload
    }

    private func save(_ payload: Payload) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        chmod(fileURL.deletingLastPathComponent().path, 0o700)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)
        try data.write(to: fileURL, options: [.atomic])
        chmod(fileURL.path, 0o600)
    }
}

private extension LocalClientIdentity {
    func sameLocalExecutable(as other: LocalClientIdentity) -> Bool {
        transport == other.transport &&
        uid == other.uid &&
        executablePath != nil &&
        executablePath == other.executablePath
    }
}
