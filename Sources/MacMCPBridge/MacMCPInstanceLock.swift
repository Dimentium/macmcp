import Darwin
import Foundation

/// Holds the per-user exclusive lock for the menu-bar runtime.
///
/// The descriptor uses close-on-exec so sidecars and tunnel-client cannot
/// accidentally keep the lock after the menu-bar process exits.
final class MacMCPInstanceLock {
    static func defaultFileURL() -> URL {
        MacMCPPaths.applicationSupportFile("menu-bar.lock")
    }

    static func acquire(fileURL: URL = defaultFileURL()) throws -> MacMCPInstanceLock? {
        let fileManager = FileManager.default
        let directoryURL = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)

        let descriptor = open(fileURL.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            let error = errno
            close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO)
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let error = errno
            close(descriptor)
            if error == EWOULDBLOCK || error == EAGAIN {
                return nil
            }
            throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO)
        }
        return MacMCPInstanceLock(fileDescriptor: descriptor)
    }

    private let fileDescriptor: Int32

    private init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }

    deinit {
        flock(fileDescriptor, LOCK_UN)
        close(fileDescriptor)
    }
}
