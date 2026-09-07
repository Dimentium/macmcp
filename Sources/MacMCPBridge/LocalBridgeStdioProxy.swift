import Darwin
import Foundation

enum LocalBridgeStdioProxy {
    static func run(socketPath: String) -> Int32 {
        signal(SIGPIPE, SIG_IGN)
        let diagnostics = TunnelProxyDiagnostics.enabledForCurrentProcess()
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            writeStderr("Unable to create local MCP proxy socket")
            return 1
        }

        do {
            try UnixSocketAddress.withSockAddr(path: socketPath) { address, length in
                guard connect(fd, address, length) == 0 else {
                    throw POSIXError(.init(rawValue: errno) ?? .EIO)
                }
            }
        } catch {
            close(fd)
            writeStderr("MacMCP app-owned runtime is not available")
            return 1
        }

        let group = DispatchGroup()
        diagnostics?.connected()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            copy(from: STDIN_FILENO, to: fd, observer: diagnostics?.observeRequest)
            shutdown(fd, SHUT_WR)
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            copy(from: fd, to: STDOUT_FILENO, observer: diagnostics?.observeResponse)
            group.leave()
        }
        group.wait()
        diagnostics?.disconnected()
        close(fd)
        return 0
    }

    private static func copy(
        from input: Int32,
        to output: Int32,
        observer: ((Data) -> Void)? = nil
    ) {
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = buffer.withUnsafeMutableBufferPointer { pointer in
                read(input, pointer.baseAddress, pointer.count)
            }
            if count == 0 { return }
            if count < 0 {
                if errno == EINTR { continue }
                return
            }
            observer?(Data(buffer.prefix(count)))
            var written = 0
            while written < count {
                let next = buffer.withUnsafeBytes { rawBuffer in
                    write(output, rawBuffer.baseAddress! + written, count - written)
                }
                if next < 0 {
                    if errno == EINTR { continue }
                    return
                }
                if next == 0 { return }
                written += next
            }
        }
    }

    private static func writeStderr(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
