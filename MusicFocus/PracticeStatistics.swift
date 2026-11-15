import Foundation

/// Calendar-day accounting shared by statistics, history and badges.
/// Original sessions remain intact; only the displayed totals are split at midnight.
struct PracticeStatistics {
    struct Day {
        let date: Date
        var focusTime: TimeInterval = 0
        var pauseTime: TimeInterval = 0
        var sessions: [FocusSession] = []
    }

    struct Summary {
        var focusTime: TimeInterval = 0
        var pauseTime: TimeInterval = 0
        var practiceDays: Int = 0
    }

    let calendar: Calendar
    let asOf: Date
    private(set) var days: [Date: Day] = [:]

    init(sessions: [FocusSession] = [], calendar: Calendar = .current, asOf: Date = Date()) {
        self.calendar = calendar
        self.asOf = asOf
        var seen = Set<UUID>()
        for session in sessions {
            // Unfinished history must not accumulate time every time the app is opened.
            guard seen.insert(session.id).inserted, let ended = session.endTime else { continue }
            let end = min(ended, asOf)
            guard end > session.startTime else { continue }
            var cursor = session.startTime
            while cursor < end {
                guard let interval = calendar.dateInterval(of: .day, for: cursor),
                      interval.end > cursor else { break }
                let totals = PracticeTimeAccounting.totals(session, in: interval, asOf: asOf)
                var day = days[interval.start] ?? Day(date: interval.start)
                day.focusTime += totals.focus
                day.pauseTime += totals.pause
                day.sessions.append(session)
                days[interval.start] = day
                cursor = interval.end
            }
        }
    }

    func day(_ date: Date) -> Day {
        let start = calendar.startOfDay(for: date)
        return days[start] ?? Day(date: start)
    }

    var recentWeek: DateInterval {
        let today = calendar.startOfDay(for: asOf)
        let start = calendar.date(byAdding: .day, value: -6, to: today)!
        let end = calendar.date(byAdding: .day, value: 1, to: today)!
        return DateInterval(start: start, end: end)
    }

    func summary(in interval: DateInterval) -> Summary {
        var result = Summary()
        var cursor = calendar.startOfDay(for: interval.start)
        while cursor < interval.end {
            if let day = days[cursor], let dayRange = calendar.dateInterval(of: .day, for: cursor) {
                let focus: TimeInterval
                if interval.start <= dayRange.start && interval.end >= dayRange.end {
                    focus = day.focusTime
                    result.pauseTime += day.pauseTime
                } else {
                    let range = DateInterval(start: max(interval.start, dayRange.start),
                                             end: min(interval.end, dayRange.end))
                    let totals = day.sessions.map { PracticeTimeAccounting.totals($0, in: range, asOf: asOf) }
                    focus = totals.reduce(0) { $0 + $1.focus }
                    result.pauseTime += totals.reduce(0) { $0 + $1.pause }
                }
                result.focusTime += focus
                if focus > 0 { result.practiceDays += 1 }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor), next > cursor else { break }
            cursor = next
        }
        return result
    }

    func month(containing date: Date) -> Summary {
        guard let interval = calendar.dateInterval(of: .month, for: date) else { return Summary() }
        return summary(in: interval)
    }
}

enum PracticeTimeAccounting {
    /// Clip pauses to the session and query interval, and union overlapping pauses.
    /// Intervals are half-open, so an end exactly at midnight does not create another day.
    static func totals(_ session: FocusSession, in requested: DateInterval? = nil,
                       asOf: Date = Date()) -> (focus: TimeInterval, pause: TimeInterval) {
        let start = max(session.startTime, requested?.start ?? session.startTime)
        let end = min(session.endTime ?? asOf, asOf, requested?.end ?? asOf)
        guard start.timeIntervalSinceReferenceDate.isFinite,
              end.timeIntervalSinceReferenceDate.isFinite, end > start else { return (0, 0) }
        let pauses = (session.distractions + (session.unsegmentedSilences ?? [])).compactMap { pause -> DateInterval? in
            let from = max(start, pause.startTime)
            let to = min(end, pause.endTime ?? end)
            return to > from ? DateInterval(start: from, end: to) : nil
        }.sorted { $0.start < $1.start }
        var pauseTime: TimeInterval = 0
        var merged: DateInterval?
        for pause in pauses {
            if let previous = merged, pause.start <= previous.end {
                merged = DateInterval(start: previous.start, end: max(previous.end, pause.end))
            } else {
                pauseTime += merged?.duration ?? 0
                merged = pause
            }
        }
        pauseTime += merged?.duration ?? 0
        return (max(0, end.timeIntervalSince(start) - pauseTime), pauseTime)
    }
}
