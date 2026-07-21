import Foundation
import XCTest
@testable import ThreadlineRuntime

@MainActor
final class AutomaticReconciliationSchedulerTests: XCTestCase {
    func testDefaultPolicyUsesFiveMinuteInterval() {
        XCTAssertEqual(
            AutomaticReconciliationScheduler.Policy().interval,
            .seconds(300)
        )
    }

    func testStartImmediatelyRunsStartupOperation() async {
        let probe = SchedulerOperationProbe()
        let scheduler = AutomaticReconciliationScheduler(
            policy: .init(interval: .seconds(10))
        ) { trigger in
            await probe.perform(trigger)
        }

        await scheduler.start()

        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.triggers, [.startup])
        XCTAssertEqual(snapshot.maximumConcurrentOperations, 1)
        await scheduler.stop()
    }

    func testPeriodicOperationRunsAfterConfiguredInterval() async {
        let probe = SchedulerOperationProbe()
        let scheduler = AutomaticReconciliationScheduler(
            policy: .init(interval: .milliseconds(25))
        ) { trigger in
            await probe.perform(trigger)
        }

        await scheduler.start()
        let observedPeriodicRun = await waitUntil {
            await probe.snapshot().triggers.contains(.periodic)
        }
        await scheduler.stop()

        XCTAssertTrue(observedPeriodicRun)
        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.triggers.first, .startup)
        XCTAssertTrue(snapshot.triggers.dropFirst().allSatisfy { $0 == .periodic })
        XCTAssertEqual(snapshot.maximumConcurrentOperations, 1)
    }

    func testRequestsDuringOperationAreCoalescedIntoOneFollowUpRun() async {
        let probe = SchedulerOperationProbe(operationsToBlock: 1)
        let scheduler = AutomaticReconciliationScheduler(
            policy: .init(interval: .seconds(10))
        ) { trigger in
            await probe.perform(trigger)
        }

        let startTask = Task {
            await scheduler.start()
        }
        let startupBegan = await waitUntil {
            await probe.snapshot().triggers == [.startup]
        }
        XCTAssertTrue(startupBegan)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    await scheduler.request(.sourceChange)
                }
            }
        }

        await probe.releaseBlockedOperation()
        await startTask.value

        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.triggers, [.startup, .sourceChange])
        XCTAssertEqual(snapshot.maximumConcurrentOperations, 1)
        await scheduler.stop()
    }

    func testMultiplePeriodicTicksDuringLongOperationProduceOneFollowUpRun() async throws {
        let probe = SchedulerOperationProbe(operationsToBlock: 2)
        let scheduler = AutomaticReconciliationScheduler(
            policy: .init(interval: .milliseconds(20))
        ) { trigger in
            await probe.perform(trigger)
        }

        let startTask = Task {
            await scheduler.start()
        }
        let startupBegan = await waitUntil {
            await probe.snapshot().triggers == [.startup]
        }
        XCTAssertTrue(startupBegan)

        try await Task.sleep(for: .milliseconds(90))
        let snapshotDuringStartup = await probe.snapshot()
        XCTAssertEqual(snapshotDuringStartup.triggers, [.startup])

        await probe.releaseBlockedOperation()
        let followUpBegan = await waitUntil {
            await probe.snapshot().triggers == [.startup, .periodic]
        }
        XCTAssertTrue(followUpBegan)

        await scheduler.stop()
        await probe.releaseBlockedOperation()
        await startTask.value

        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.triggers, [.startup, .periodic])
        XCTAssertEqual(snapshot.maximumConcurrentOperations, 1)
    }

    func testStopCancelsPeriodicWorkAndIgnoresFurtherRequests() async throws {
        let probe = SchedulerOperationProbe()
        let scheduler = AutomaticReconciliationScheduler(
            policy: .init(interval: .milliseconds(25))
        ) { trigger in
            await probe.perform(trigger)
        }

        await scheduler.start()
        await scheduler.stop()
        await scheduler.request(.wake)
        try await Task.sleep(for: .milliseconds(100))

        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.triggers, [.startup])
        XCTAssertEqual(snapshot.maximumConcurrentOperations, 1)
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)

        while clock.now < deadline {
            if await condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(5))
        }

        return await condition()
    }
}

@MainActor
final class TrailingDebouncerTests: XCTestCase {
    func testReschedulingDelaysActionUntilAfterLastEvent() async throws {
        let probe = DebouncerProbe()
        let debouncer = TrailingDebouncer(
            queue: DispatchQueue(label: "TrailingDebouncerTests.reschedule"),
            interval: 0.15
        ) {
            probe.record()
        }

        debouncer.schedule()
        try await Task.sleep(for: .milliseconds(40))
        debouncer.schedule()
        try await Task.sleep(for: .milliseconds(40))
        let lastEventTime = Date().timeIntervalSinceReferenceDate
        debouncer.schedule()

        let didFire = await waitUntil { probe.count == 1 }
        XCTAssertTrue(didFire)
        XCTAssertEqual(probe.count, 1)
        let fireTime = try XCTUnwrap(probe.firstFireTime)
        XCTAssertGreaterThanOrEqual(fireTime - lastEventTime, 0.12)
    }

    func testDeactivateCancelsPendingActionAndRejectsLaterEvents() async throws {
        let probe = DebouncerProbe()
        let debouncer = TrailingDebouncer(
            queue: DispatchQueue(label: "TrailingDebouncerTests.deactivate"),
            interval: 0.03
        ) {
            probe.record()
        }

        debouncer.schedule()
        debouncer.deactivate()
        debouncer.schedule()
        try await Task.sleep(for: .milliseconds(60))

        XCTAssertEqual(probe.count, 0)
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)

        while clock.now < deadline {
            if condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(5))
        }

        return condition()
    }
}

private actor SchedulerOperationProbe {
    struct Snapshot: Sendable {
        var triggers: [AutomaticReconciliationScheduler.Trigger]
        var maximumConcurrentOperations: Int
    }

    private var triggers: [AutomaticReconciliationScheduler.Trigger] = []
    private var activeOperations = 0
    private var maximumConcurrentOperations = 0
    private var operationsToBlock: Int
    private var blockedOperationContinuation: CheckedContinuation<Void, Never>?

    init(operationsToBlock: Int = 0) {
        self.operationsToBlock = operationsToBlock
    }

    func perform(_ trigger: AutomaticReconciliationScheduler.Trigger) async {
        triggers.append(trigger)
        activeOperations += 1
        maximumConcurrentOperations = max(maximumConcurrentOperations, activeOperations)

        if operationsToBlock > 0 {
            operationsToBlock -= 1
            await withCheckedContinuation { continuation in
                blockedOperationContinuation = continuation
            }
        }

        activeOperations -= 1
    }

    func releaseBlockedOperation() {
        blockedOperationContinuation?.resume()
        blockedOperationContinuation = nil
    }

    func snapshot() -> Snapshot {
        Snapshot(
            triggers: triggers,
            maximumConcurrentOperations: maximumConcurrentOperations
        )
    }
}

private final class DebouncerProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedCount = 0
    private var recordedFirstFireTime: TimeInterval?

    var count: Int {
        lock.withLock { recordedCount }
    }

    var firstFireTime: TimeInterval? {
        lock.withLock { recordedFirstFireTime }
    }

    func record() {
        lock.withLock {
            recordedCount += 1
            if recordedFirstFireTime == nil {
                recordedFirstFireTime = Date().timeIntervalSinceReferenceDate
            }
        }
    }
}
