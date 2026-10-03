#if os(iOS)
import Foundation
import HealthKit
import LocalInference

actor PhoneSleepSource {
    private let store = HKHealthStore()
    private let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!

    func requestAccess() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { throw LocalModelFailure("Health data is unavailable on this device.") }
        try await store.requestAuthorization(toShare: [], read: [type])
    }

    func summary(now: Date) async throws -> (record: EvidenceRecord?, coverage: String) {
        guard HKHealthStore.isHealthDataAvailable() else { return (nil, "Health: unavailable.") }
        let start = Calendar.current.date(byAdding: .day, value: -7, to: now)!
        let window = DateInterval(start: start, end: now)
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
        guard !intervals.isEmpty else {
            return (nil, "Health: no readable sleep samples in the last seven days. This may mean no data or denied read access; HealthKit does not disclose read denial.")
        }
        let hours = SleepSummary.hours(intervals: intervals, window: window)
        let range = "\(ISO8601DateFormatter().string(from: start)) through \(ISO8601DateFormatter().string(from: now))"
        return (EvidenceRecord(id: "sleep", source: "health", timestamp: now,
            text: "Recorded asleep time across \(range): \(String(format: "%.1f", hours)) hours total. Overlapping asleep intervals were merged. This is recorded time, not a diagnosis or a measure of sleep quality.",
            locator: "phone-health:sleep-summary-seven-days", trust: "derivedSummary"),
            "Health: derived sleep total only; raw samples stay on this phone. \(capped ? "Partial: 1,000-sample limit reached." : "Visible samples only; missing data is not zero sleep.")")
    }
}
#endif
