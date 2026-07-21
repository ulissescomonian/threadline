import Foundation
import OSLog
import ThreadlineRuntime

@main
enum ThreadlineAgentMain {
    private static let logger = Logger(subsystem: "com.ulisses.threadline", category: "agent")

    static func main() async {
        do {
            let configuration = try RuntimeConfiguration.systemDefault()
            let services = try await ApplicationServices.makeDefault(configuration: configuration)
            let monitor = FileSystemEventMonitor(
                paths: [configuration.codexHomeURL.path, configuration.claudeHomeURL.path]
            ) {
                await reconcile(services)
            }
            monitor.start()
            await reconcile(services)

            while !Task.isCancelled {
                try await Task.sleep(for: .seconds(60))
                await reconcile(services)
            }
            monitor.stop()
        } catch {
            logger.error("Agent startup failed: \(error.localizedDescription, privacy: .private(mask: .hash))")
        }
    }

    private static func reconcile(_ services: ApplicationServices) async {
        do {
            try await services.ingestAll()
        } catch {
            logger.error("Ingestion failed: \(error.localizedDescription, privacy: .private(mask: .hash))")
        }

        do {
            try await services.syncNow()
        } catch {
            logger.notice("Sync deferred: \(error.localizedDescription, privacy: .private(mask: .hash))")
        }
    }
}
