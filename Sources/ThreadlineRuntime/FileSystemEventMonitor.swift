import CoreServices
import Foundation

/// A bounded, coalesced view of source filesystem changes. Paths are passed to
/// ingestion for routing only and must never be logged verbatim.
public struct SourceFileSystemChanges: Sendable, Equatable {
    public struct Event: Sendable, Equatable {
        public let path: String
        public let flags: UInt32

        public init(path: String, flags: UInt32) {
            self.path = path
            self.flags = flags
        }
    }

    public let events: [Event]

    public init(events: [Event]) {
        // FSEvents may report several notifications for the same file during a
        // write. Keep the latest flags and cap the handoff to avoid turning an
        // event storm into unbounded memory use.
        var latest: [String: UInt32] = [:]
        for event in events.suffix(Self.maximumEvents) {
            latest[event.path] = event.flags
        }
        self.events = latest.map { Event(path: $0.key, flags: $0.value) }
    }

    public var paths: [String] { events.map(\.path) }
    public var isEmpty: Bool { events.isEmpty }

    private static let maximumEvents = 512
}

public final class FileSystemEventMonitor: @unchecked Sendable {
    private let paths: [String]
    private let queue: DispatchQueue
    private let debouncer: TrailingDebouncer
    private let changeBuffer: SourceChangeBuffer
    private var stream: FSEventStreamRef?

    public init(
        paths: [String],
        debounceInterval: TimeInterval = 45,
        onChange: @escaping @Sendable (SourceFileSystemChanges) async -> Void
    ) {
        let queue = DispatchQueue(label: "com.ulisses.threadline.fsevents", qos: .utility)
        self.paths = paths
        self.queue = queue
        let changeBuffer = SourceChangeBuffer()
        self.changeBuffer = changeBuffer
        debouncer = TrailingDebouncer(queue: queue, interval: debounceInterval) {
            let changes = changeBuffer.take()
            guard !changes.isEmpty else { return }
            Task { await onChange(changes) }
        }
    }

    deinit {
        stop()
    }

    public func start() {
        guard stream == nil, !paths.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, eventCount, eventPaths, eventFlags, _ in
            guard let info else { return }
            let monitor = Unmanaged<FileSystemEventMonitor>.fromOpaque(info).takeUnretainedValue()
            monitor.scheduleCallback(
                count: eventCount,
                paths: eventPaths,
                flags: eventFlags
            )
        }

        guard let stream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.75,
            UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        ) else { return }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        debouncer.activate()
        FSEventStreamStart(stream)
    }

    public func stop() {
        debouncer.deactivate()
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func scheduleCallback(
        count: Int,
        paths: UnsafeMutableRawPointer,
        flags: UnsafePointer<FSEventStreamEventFlags>
    ) {
        let reportedPaths = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as NSArray
        var events: [SourceFileSystemChanges.Event] = []
        events.reserveCapacity(min(count, 512))
        for index in 0..<count {
            guard let path = reportedPaths[index] as? String else { continue }
            events.append(.init(path: path, flags: flags[index]))
        }
        changeBuffer.append(events)
        debouncer.schedule()
    }
}

private final class SourceChangeBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pendingChanges: [SourceFileSystemChanges.Event] = []

    func append(_ events: [SourceFileSystemChanges.Event]) {
        lock.withLock {
            pendingChanges.append(contentsOf: events)
            if pendingChanges.count > 512 {
                pendingChanges.removeFirst(pendingChanges.count - 512)
            }
        }
    }

    func take() -> SourceFileSystemChanges {
        lock.withLock {
            let changes = SourceFileSystemChanges(events: pendingChanges)
            pendingChanges.removeAll(keepingCapacity: true)
            return changes
        }
    }
}

final class TrailingDebouncer: @unchecked Sendable {
    private let queue: DispatchQueue
    private let interval: TimeInterval
    private let action: @Sendable () -> Void
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var pendingWorkItem: DispatchWorkItem?
    private var isActive = true

    init(
        queue: DispatchQueue,
        interval: TimeInterval,
        action: @escaping @Sendable () -> Void
    ) {
        self.queue = queue
        self.interval = interval
        self.action = action
    }

    func activate() {
        lock.withLock {
            isActive = true
        }
    }

    func schedule() {
        lock.lock()
        guard isActive else {
            lock.unlock()
            return
        }

        generation &+= 1
        let scheduledGeneration = generation
        pendingWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.fire(generation: scheduledGeneration)
        }
        pendingWorkItem = workItem
        lock.unlock()

        queue.asyncAfter(deadline: .now() + interval, execute: workItem)
    }

    func cancel() {
        lock.withLock {
            generation &+= 1
            pendingWorkItem?.cancel()
            pendingWorkItem = nil
        }
    }

    func deactivate() {
        lock.withLock {
            isActive = false
            generation &+= 1
            pendingWorkItem?.cancel()
            pendingWorkItem = nil
        }
    }

    private func fire(generation scheduledGeneration: UInt64) {
        let shouldRun = lock.withLock {
            guard isActive,
                  generation == scheduledGeneration,
                  pendingWorkItem?.isCancelled == false
            else { return false }

            pendingWorkItem = nil
            return true
        }

        if shouldRun {
            action()
        }
    }
}
