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
        public var seriousThermalMultiplier: Double
        public var criticalThermalMultiplier: Double
        public var jitterFraction: Double

        public init(
            interval: Duration = .seconds(300),
            seriousThermalMultiplier: Double = 2,
            criticalThermalMultiplier: Double = 4,
            jitterFraction: Double = 0.1
        ) {
            self.interval = interval
            self.seriousThermalMultiplier = seriousThermalMultiplier
            self.criticalThermalMultiplier = criticalThermalMultiplier
            self.jitterFraction = jitterFraction
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
        periodicTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    guard let self else { return }
                    try await Task.sleep(for: await self.nextPeriodicDelay())
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
            pendingTrigger = coalescedTrigger(pendingTrigger, with: trigger)
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

    private func nextPeriodicDelay() -> Duration {
        let multiplier: Double = switch ProcessInfo.processInfo.thermalState {
        case .serious: policy.seriousThermalMultiplier
        case .critical: policy.criticalThermalMultiplier
        case .nominal, .fair: 1
        @unknown default: 1
        }
        let jitter = Double.random(in: 0...max(0, policy.jitterFraction))
        let components = policy.interval.components
        let base = Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
        return .seconds(max(0.001, base * multiplier * (1 + jitter)))
    }

    private func coalescedTrigger(_ existing: Trigger?, with incoming: Trigger) -> Trigger {
        guard let existing else { return incoming }
        return priority(of: incoming) >= priority(of: existing) ? incoming : existing
    }

    private func priority(of trigger: Trigger) -> Int {
        switch trigger {
        case .sourceChange: 4
        case .wake: 3
        case .startup: 2
        case .periodic: 1
        }
    }
}
