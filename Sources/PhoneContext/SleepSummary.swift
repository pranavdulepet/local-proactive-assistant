import Foundation

public enum SleepSummary {
    /// Union the asleep intervals so overlapping devices/stages do not double-count time.
    public static func hours(intervals: [DateInterval], window: DateInterval) -> Double {
        let clipped = intervals.compactMap { interval -> DateInterval? in
            let start = max(interval.start, window.start)
            let end = min(interval.end, window.end)
            return end > start ? DateInterval(start: start, end: end) : nil
        }.sorted { $0.start < $1.start }
        var total: TimeInterval = 0
        var current: DateInterval?
        for interval in clipped {
            if let previous = current, interval.start <= previous.end {
                current = DateInterval(start: previous.start, end: max(previous.end, interval.end))
            } else {
                total += current?.duration ?? 0
                current = interval
            }
        }
        return (total + (current?.duration ?? 0)) / 3_600
    }
}
