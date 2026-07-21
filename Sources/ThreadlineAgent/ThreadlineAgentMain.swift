import Foundation
import OSLog

/// The main Threadline app owns automatic reconciliation, including menu-bar
/// operation and login launch. This embedded helper intentionally performs no
/// provider or sync work, preventing a second process from duplicating scans.
@main
enum ThreadlineAgentMain {
    static func main() {
        Logger(subsystem: "com.ulisses.threadline", category: "agent").info(
            "ThreadlineAgent exited: automatic reconciliation is owned by the main app"
        )
    }
}
