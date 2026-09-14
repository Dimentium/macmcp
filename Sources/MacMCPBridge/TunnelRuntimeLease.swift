import Darwin
import Foundation

struct TunnelRuntimeLease: Codable, Equatable, Sendable {
    let pid: Int32
    let startedAtMicroseconds: UInt64
    let executablePath: String
    let profile: String
}

struct TunnelRuntimeLeaseStore: Sendable {
    let fileURL: URL

    init(fileURL: URL = MacMCPPaths.applicationSupportFile("chatgpt-tunnel-runtime.json")) {
        self.fileURL = fileURL
    }

    func claim(_ process: Process, executablePath: String, profile: String) throws {
        guard let identity = processIdentity(pid: process.processIdentifier) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let lease = TunnelRuntimeLease(
            pid: process.processIdentifier,
            startedAtMicroseconds: identity.startedAtMicroseconds,
            executablePath: executablePath,
            profile: profile
        )
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        chmod(directory.path, 0o700)
        try JSONEncoder().encode(lease).write(to: fileURL, options: .atomic)
        chmod(fileURL.path, 0o600)
    }

    func release(pid: Int32? = nil) {
        guard let pid else {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        guard let lease = readLease(), lease.pid == pid else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }

    func reclaimIfOwned(executablePath: String, profile: String) async {
        guard let lease = readLease() else { return }
        guard lease.executablePath == executablePath, lease.profile == profile,
              let identity = processIdentity(pid: lease.pid),
              identity.startedAtMicroseconds == lease.startedAtMicroseconds,
              identity.executablePath == executablePath
        else {
            release(pid: lease.pid)
            return
        }
        kill(lease.pid, SIGTERM)
        for _ in 0..<40 where processIdentity(pid: lease.pid) != nil {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if processIdentity(pid: lease.pid) != nil {
            kill(lease.pid, SIGKILL)
        }
        release(pid: lease.pid)
    }

    private func readLease() -> TunnelRuntimeLease? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        do {
            return try JSONDecoder().decode(TunnelRuntimeLease.self, from: Data(contentsOf: fileURL))
        } catch {
            // A corrupt lease cannot establish ownership of any process.
            // Removing it is safe and lets a later run create a fresh lease.
            release()
            return nil
        }
    }

    private func processIdentity(pid: Int32) -> (startedAtMicroseconds: UInt64, executablePath: String)? {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size else { return nil }
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return (UInt64(info.pbi_start_tvsec) * 1_000_000 + UInt64(info.pbi_start_tvusec), String(cString: buffer))
    }
}
