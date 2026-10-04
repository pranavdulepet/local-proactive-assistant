#if os(iOS)
import Foundation
@preconcurrency import HealthKit
import LocalInference
import PhoneSync

actor PhoneSleepSource {
    private let store = HKHealthStore()
    private let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!
    private var observer: HKObserverQuery?

    func requestAccess() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { throw LocalModelFailure("Health data is unavailable on this device.") }
        try await store.requestAuthorization(toShare: [], read: [type])
    }

    func startUpdates(_ handler: @escaping @Sendable () async -> Void) async -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else { return false }
        if let observer { store.stop(observer) }
        let query = HKObserverQuery(sampleType: type, predicate: nil) { _, completion, error in
            guard error == nil else { completion(); return }
            let delivery = HealthDeliveryCompletion(completion)
            Task { await handler(); delivery.finish() }
        }
        observer = query
        store.execute(query)
        return await withCheckedContinuation { continuation in
            store.enableBackgroundDelivery(for: type, frequency: .daily) { success, _ in
                continuation.resume(returning: success)
            }
        }
    }

    func stopUpdates() {
        if let observer { store.stop(observer); self.observer = nil }
        store.disableBackgroundDelivery(for: type) { _, _ in }
    }

    func digests(now: Date) async throws -> [PhoneSleepDigest] {
        guard HKHealthStore.isHealthDataAvailable() else { return [] }
        let start = now.addingTimeInterval(-168 * 3600)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: now)
        let (intervals, capped): ([DateInterval], Bool) = try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: 1_001,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]) { _, samples, error in
                if let error { continuation.resume(throwing: error); return }
                let asleep: Set<Int> = [HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue, HKCategoryValueSleepAnalysis.asleepCore.rawValue, HKCategoryValueSleepAnalysis.asleepDeep.rawValue, HKCategoryValueSleepAnalysis.asleepREM.rawValue]
                let intervals = (samples ?? []).prefix(1_000).compactMap { sample -> DateInterval? in
                    guard let sample = sample as? HKCategorySample, asleep.contains(sample.value), sample.endDate > sample.startDate else { return nil }
                    return DateInterval(start: sample.startDate, end: sample.endDate)
                }
                continuation.resume(returning: (intervals, (samples?.count ?? 0) > 1_000))
            }
            store.execute(query)
        }
        return [24, 168].map { hours in
            let window = DateInterval(start: now.addingTimeInterval(-Double(hours) * 3600), end: now)
            let readable = intervals.contains { $0.start < window.end && $0.end > window.start }
            return PhoneSleepDigest(windowHours: hours, start: window.start, end: now,
                recordedMinutes: readable ? SleepSummary.hours(intervals: intervals, window: window) * 60 : nil,
                sampleLimitReached: capped)
        }
    }

    func summary(now: Date) async throws -> (record: EvidenceRecord?, coverage: String) {
        let items = try await digests(now: now)
        guard let item = items.first(where: { $0.windowHours == 168 }), let minutes = item.recordedMinutes else {
            return (nil, "Health: no readable sleep samples in the last seven days. This may mean no data or denied read access; HealthKit does not disclose read denial.")
        }
        return (EvidenceRecord(id: "sleep", source: "health", timestamp: now,
            text: "Recorded asleep time across the last seven days: \(String(format: "%.1f", minutes / 60)) hours total. Overlapping asleep intervals were merged. This is recorded time, not a diagnosis or a measure of sleep quality.",
            locator: "phone-health:sleep-summary-seven-days", trust: "derivedSummary"),
            "Health: derived sleep total only; raw samples stay on this phone. \(item.sampleLimitReached ? "Partial: 1,000-sample limit reached." : "Visible samples only; missing data is not zero sleep.")")
    }
}
// HealthKit's completion may run on any queue; ownership is transferred to one task.
private final class HealthDeliveryCompletion: @unchecked Sendable {
    private let completion: () -> Void
    init(_ completion: @escaping () -> Void) { self.completion = completion }
    func finish() { completion() }
}
#endif
