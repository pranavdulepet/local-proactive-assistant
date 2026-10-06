import Darwin
import Foundation

/// Kernel releases the lock on exit, including crashes. The lock file itself is harmless.
final class HostLock {
    private let descriptor: Int32

    init(fileURL: URL) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        descriptor = open(fileURL.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw HostLockFailure("Could not open the host lock.") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw HostLockFailure("Another assistant host is already running. Stop it before starting this one.")
        }
    }

    deinit { close(descriptor) }
}

private struct HostLockFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
