import Darwin
import Foundation

enum UnixSocketAddressError: LocalizedError, Equatable {
    case pathTooLong

    var errorDescription: String? {
        switch self {
        case .pathTooLong:
            return "Unix socket path is too long"
        }
    }
}

enum UnixSocketAddress {
    static func withSockAddr<T>(
        path: String,
        _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T
    ) throws -> T {
        guard let pathData = path.data(using: .utf8) else {
            throw UnixSocketAddressError.pathTooLong
        }
        var address = sockaddr_un()
        let sunPathSize = MemoryLayout.size(ofValue: address.sun_path)
        guard pathData.count < sunPathSize else {
            throw UnixSocketAddressError.pathTooLong
        }

        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { rawPath in
            for index in rawPath.indices {
                rawPath[index] = 0
            }
            for (offset, byte) in pathData.enumerated() {
                rawPath[offset] = byte
            }
        }

        return try withUnsafePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                try body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }
}
