import Foundation

public actor AutomaticReconciliationScheduler {
    public enum Trigger: Sendable, Equatable {
        case startup
        case sourceChange
        case periodic
        case wake
    }

    public struct Policy: Sendable {
        public var interval: Duration

        public init(interval: Duration = .seconds(300)) {
            self.interval = interval
        }
    }

    private let policy: Policy
    private let operation: @Sendable (Trigger) async -> Void
    private var periodicTask: Task<Void, Never>?
    private var isStarted = false
    private var isRunning = false
    private var pendingTrigger: Trigger?

    public init(
        policy: Policy = Policy(),
        operation: @escaping @Sendable (Trigger) async -> Void
    ) {
        self.policy = policy
        self.operation = operation
    }

    public func start() async {
        guard !isStarted else { return }

        isStarted = true
        let interval = policy.interval
        periodicTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }

                guard !Task.isCancelled else { return }
                Task { [weak self] in
                    await self?.request(.periodic)
                }
            }
        }

        await request(.startup)
    }

    public func request(_ trigger: Trigger) async {
        guard isStarted else { return }

        if isRunning {
            pendingTrigger = trigger
            return
        }

        isRunning = true
        var nextTrigger: Trigger? = trigger

        while let currentTrigger = nextTrigger {
            await operation(currentTrigger)

            guard isStarted else {
                pendingTrigger = nil
                break
            }

            nextTrigger = pendingTrigger
            pendingTrigger = nil
        }

        isRunning = false
    }

    public func stop() {
        isStarted = false
        pendingTrigger = nil
        periodicTask?.cancel()
        periodicTask = nil
    }
}
