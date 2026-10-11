#if os(iOS)
import Foundation
@preconcurrency import HealthKit
import LocalInference
import PhoneSync

public actor PhoneActivitySource {
    private let store = HKHealthStore()
    private let quantities: [HKQuantityTypeIdentifier] = [.stepCount, .activeEnergyBurned, .appleExerciseTime]

    public init() {}

    /// Completion means the authorization sheet was handled, not that read access was granted.
    public func requestAccess() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { throw LocalModelFailure("Health data is unavailable on this device.") }
        let types = Set(quantities.compactMap { HKQuantityType.quantityType(forIdentifier: $0) as HKObjectType? })
        try await store.requestAuthorization(toShare: [], read: types)
    }

    public func digest(now: Date = Date()) async throws -> PhoneActivityDigest {
        guard HKHealthStore.isHealthDataAvailable() else { throw LocalModelFailure("Health data is unavailable on this device.") }
        try Task.checkCancellation()
        let start = Calendar.current.startOfDay(for: now)
        async let steps = total(.stepCount, unit: .count(), start: start, end: now)
        async let energy = total(.activeEnergyBurned, unit: .kilocalorie(), start: start, end: now)
        async let exercise = total(.appleExerciseTime, unit: .minute(), start: start, end: now)
        let values = await (steps, energy, exercise)
        try Task.checkCancellation()
        let failures: [PhoneActivityQuantity] = [
            values.0.failed ? .steps : nil, values.1.failed ? .activeEnergy : nil, values.2.failed ? .exerciseTime : nil,
        ].compactMap { $0 }
        return PhoneActivityDigest(start: start, end: now, steps: values.0.value,
            activeEnergyKilocalories: values.1.value, exerciseMinutes: values.2.value, failedQuantities: failures)
    }

    private func total(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit, start: Date, end: Date) async -> ActivityTotal {
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { return ActivityTotal(value: nil, failed: true) }
        let read = HealthActivityRead(store: store, type: type, unit: unit, start: start, end: end)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { read.start($0) }
        } onCancel: { read.cancel() }
    }
}

private struct ActivityTotal: Sendable {
    let value: Double?
    let failed: Bool
}

/// HealthKit callbacks, cancellation and the deadline can race. The lock protects one continuation and query.
private final class HealthActivityRead: @unchecked Sendable {
    private let lock = NSLock()
    private let store: HKHealthStore
    private let type: HKQuantityType
    private let unit: HKUnit
    private let startDate: Date
    private let endDate: Date
    private var continuation: CheckedContinuation<ActivityTotal, Never>?
    private var query: HKStatisticsQuery?
    private var deadline: Task<Void, Never>?
    private var finished = false

    init(store: HKHealthStore, type: HKQuantityType, unit: HKUnit, start: Date, end: Date) {
        self.store = store; self.type = type; self.unit = unit; startDate = start; endDate = end
    }

    func start(_ continuation: CheckedContinuation<ActivityTotal, Never>) {
        lock.lock()
        guard !finished else { lock.unlock(); continuation.resume(returning: ActivityTotal(value: nil, failed: true)); return }
        self.continuation = continuation
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: [.strictStartDate, .strictEndDate])
        let query = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate, options: .cumulativeSum) { [self] _, statistics, error in
            guard error == nil else { finish(ActivityTotal(value: nil, failed: true)); return }
            let value = statistics?.sumQuantity()?.doubleValue(for: unit)
            if let value, !value.isFinite || value < 0 { finish(ActivityTotal(value: nil, failed: true)); return }
            finish(ActivityTotal(value: value, failed: false))
        }
        self.query = query
        deadline = Task { [self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            cancel()
        }
        store.execute(query)
        lock.unlock()
    }

    func cancel() { finish(ActivityTotal(value: nil, failed: true)) }

    private func finish(_ result: ActivityTotal) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = continuation, query = query, deadline = deadline
        self.continuation = nil; self.query = nil; self.deadline = nil
        lock.unlock()
        deadline?.cancel()
        if let query { store.stop(query) }
        continuation?.resume(returning: result)
    }
}
#endif
