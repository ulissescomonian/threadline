import Darwin
import ConversationCore
import Foundation

final class SyncRunLease: @unchecked Sendable {
    private let descriptor: Int32

    init(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        descriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else {
            throw ThreadlineError.unavailable("Threadline could not open its synchronization lock.")
        }
        _ = fchmod(descriptor, mode_t(0o600))
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw ThreadlineError.unavailable(
                "Another Threadline process is already synchronizing this library."
            )
        }
    }

    deinit {
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}
