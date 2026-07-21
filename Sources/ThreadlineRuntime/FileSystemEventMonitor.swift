import CoreServices
import Foundation

public final class FileSystemEventMonitor: @unchecked Sendable {
    private let paths: [String]
    private let queue: DispatchQueue
    private let debouncer: TrailingDebouncer
    private var stream: FSEventStreamRef?

    public init(
        paths: [String],
        debounceInterval: TimeInterval = 15,
        onChange: @escaping @Sendable () async -> Void
    ) {
        let queue = DispatchQueue(label: "com.ulisses.threadline.fsevents", qos: .utility)
        self.paths = paths
        self.queue = queue
        debouncer = TrailingDebouncer(queue: queue, interval: debounceInterval) {
            Task { await onChange() }
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

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let monitor = Unmanaged<FileSystemEventMonitor>.fromOpaque(info).takeUnretainedValue()
            monitor.scheduleCallback()
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

    private func scheduleCallback() {
        debouncer.schedule()
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
