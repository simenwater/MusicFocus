import Foundation

/// Context only: practice time is always calculated by the existing pause accounting.
struct ScorePracticeContext: Codable, Equatable {
    var scoreID: UUID
    var title: String
    /// One-based PDF pages. A two-page spread is one context, never two timers.
    var pages: [Int]
    var tempo: ScorePracticeTempo?
}

struct ScorePracticeTempo: Codable, Equatable, Hashable {
    var bpm: Int
    var signature: String
}

struct ScorePracticeInterval: Codable {
    var context: ScorePracticeContext
    var start: Date
    var end: Date
}

struct ScoreReadingVisit: Codable {
    var scoreID: UUID
    var title: String
    var pages: [Int]
    var start: Date
    var end: Date
}

/// Records only context transitions. No audio subscriptions or additional tick timer.
struct ScoreContextTimeline {
    private(set) var context: ScorePracticeContext?
    private var start: Date?

    mutating func change(to next: ScorePracticeContext?, at date: Date,
                         sessionStart: Date?) -> ScorePracticeInterval? {
        guard context != next else { return nil }
        let interval = finish(at: date, sessionStart: sessionStart)
        context = next
        start = sessionStart.map { max($0, date) }
        return interval
    }

    mutating func beginSession(at date: Date) { start = date }

    mutating func finish(at date: Date, sessionStart: Date?) -> ScorePracticeInterval? {
        defer { start = nil }
        guard let context, let sessionStart, let start, date > max(start, sessionStart) else { return nil }
        return ScorePracticeInterval(context: context, start: max(start, sessionStart), end: date)
    }
}

struct ScorePracticeSummary: Identifiable {
    struct Pages: Identifiable {
        var pages: [Int]
        var displayed: TimeInterval = 0
        var practice: TimeInterval = 0
        var metronome: TimeInterval = 0
        var tempos: [ScorePracticeTempo: TimeInterval] = [:]
        var id: String { pages.map(String.init).joined(separator: ",") }
    }
    /// One page across sessions: what was practised, with or without the metronome.
    struct PageDetail {
        struct Entry: Identifiable {
            var id: UUID          // session
            var start: Date       // first moment on this page in that session
            var practice: TimeInterval = 0
            var tempos: [ScorePracticeTempo: TimeInterval] = [:]
            var metronome: TimeInterval { tempos.values.reduce(0, +) }
        }
        var practice: TimeInterval = 0
        var metronome: TimeInterval = 0
        var tempos: [ScorePracticeTempo: TimeInterval] = [:]
        /// Newest first.
        var entries: [Entry] = []
        /// Last instant of effective practice, separate from the session row’s first visit.
        var lastPracticed: Date?
    }

    var id: UUID
    var title: String
    var groups: [Pages] = []
    /// Practice per page; a two-page spread's time is split evenly between its pages.
    var pages: [Int: PageDetail] = [:]
    var practice: TimeInterval { groups.reduce(0) { $0 + $1.practice } }

    /// Detected practice per page for the heatmap. A two-page spread shows both
    /// pages at once, so its time is split evenly; page totals still sum to `practice`.
    var practiceByPage: [Int: TimeInterval] {
        var result: [Int: TimeInterval] = [:]
        for group in groups where !group.pages.isEmpty && group.practice > 0 {
            let share = group.practice / Double(group.pages.count)
            for page in group.pages { result[page, default: 0] += share }
        }
        return result
    }
    var displayed: TimeInterval { groups.reduce(0) { $0 + $1.displayed } }
    var metronome: TimeInterval { groups.reduce(0) { $0 + $1.metronome } }

    private final class PageAccumulator {
        var detail = PageDetail()
        var entries: [UUID: PageDetail.Entry] = [:]
        func finish() -> PageDetail {
            var value = detail
            value.entries = entries.values.sorted { $0.start > $1.start }
            return value
        }
    }

    private final class ScoreAccumulator {
        let title: String
        var groups: [[Int]: Pages] = [:]
        var pages: [Int: PageAccumulator] = [:]
        init(title: String) { self.title = title }
    }

    static func build(sessions: [FocusSession], visits: [ScoreReadingVisit],
                      in range: DateInterval? = nil, asOf: Date = Date()) -> [Self] {
        // Reference accumulators avoid copying a page's growing history for every
        // interval. Page/session dictionaries are flattened and sorted only once.
        var result: [UUID: ScoreAccumulator] = [:]
        func score(_ id: UUID, title: String) -> ScoreAccumulator {
            if let value = result[id] { return value }
            let value = ScoreAccumulator(title: title)
            result[id] = value
            return value
        }
        func add(_ id: UUID, title: String, pages: [Int], displayed: TimeInterval,
                 practice: TimeInterval, tempo: ScorePracticeTempo?) {
            guard !pages.isEmpty, displayed > 0 || practice > 0 else { return }
            let value = score(id, title: title)
            value.groups[pages, default: Pages(pages: pages)].displayed += displayed
            value.groups[pages, default: Pages(pages: pages)].practice += practice
            if let tempo {
                value.groups[pages, default: Pages(pages: pages)].metronome += practice
                value.groups[pages, default: Pages(pages: pages)].tempos[tempo, default: 0] += practice
            }
        }
        for visit in visits {
            guard !Task.isCancelled else { return [] }
            let start = max(visit.start, range?.start ?? visit.start)
            let end = min(visit.end, range?.end ?? asOf, asOf)
            if end > start {
                add(visit.scoreID, title: visit.title, pages: Array(Set(visit.pages.filter { $0 > 0 })).sorted(),
                    displayed: end.timeIntervalSince(start), practice: 0, tempo: nil)
            }
        }
        var seen = Set<UUID>()
        for session in sessions where session.endTime != nil && seen.insert(session.id).inserted {
            guard !Task.isCancelled else { return [] }
            // Defensively trim overlapping stored contexts, so a corrupt interval cannot double-count.
            var previousEnd = session.startTime
            for interval in (session.scoreIntervals ?? []).sorted(by: { $0.start < $1.start }) {
                let start = max(interval.start, previousEnd, range?.start ?? session.startTime)
                let end = min(interval.end, session.endTime!, range?.end ?? asOf, asOf)
                previousEnd = max(previousEnd, interval.end)
                guard end > start else { continue }
                let span = DateInterval(start: start, end: end)
                let seconds = PracticeTimeAccounting.totals(session, in: span, asOf: asOf).focus
                let pages = Array(Set(interval.context.pages.filter { $0 > 0 })).sorted()
                guard seconds > 0, !pages.isEmpty else { continue }
                let context = interval.context
                add(context.scoreID, title: context.title, pages: pages,
                    displayed: 0, practice: seconds, tempo: context.tempo)
                let value = score(context.scoreID, title: context.title)
                let share = seconds / Double(pages.count)
                let last = lastPractice(in: span, session: session)
                for page in pages {
                    let accumulator: PageAccumulator
                    if let existing = value.pages[page] { accumulator = existing }
                    else { accumulator = PageAccumulator(); value.pages[page] = accumulator }
                    accumulator.detail.practice += share
                    if let last { accumulator.detail.lastPracticed = max(accumulator.detail.lastPracticed ?? last, last) }
                    if let tempo = context.tempo {
                        accumulator.detail.metronome += share
                        accumulator.detail.tempos[tempo, default: 0] += share
                    }
                    if accumulator.entries[session.id] == nil {
                        accumulator.entries[session.id] = .init(id: session.id, start: start)
                    }
                    accumulator.entries[session.id]!.start = min(accumulator.entries[session.id]!.start, start)
                    accumulator.entries[session.id]!.practice += share
                    if let tempo = context.tempo { accumulator.entries[session.id]!.tempos[tempo, default: 0] += share }
                }
            }
        }
        return result.map { id, value in
            Self(id: id, title: value.title,
                 groups: value.groups.values.sorted { $0.pages.lexicographicallyPrecedes($1.pages) },
                 pages: value.pages.mapValues { $0.finish() })
        }.sorted { $0.practice == $1.practice ? $0.title.localizedStandardCompare($1.title) == .orderedAscending : $0.practice > $1.practice }
    }

    /// Walk back over trailing pauses, including short unsegmented silences.
    /// Use an instant inside the half-open practice interval: stopping exactly
    /// at midnight must not claim practice on the following day.
    private static func lastPractice(in span: DateInterval, session: FocusSession) -> Date? {
        let pauses = (session.distractions + (session.unsegmentedSilences ?? [])).compactMap { pause -> DateInterval? in
            let start = max(span.start, pause.startTime), end = min(span.end, pause.endTime ?? span.end)
            return end > start ? DateInterval(start: start, end: end) : nil
        }.sorted { $0.start > $1.start }
        var end = span.end
        for pause in pauses {
            // A later-starting pause may be nested inside an earlier, longer one.
            // Skip it rather than stopping the search for a pause covering `end`.
            if pause.end >= end { end = min(end, pause.start) }
        }
        guard end > span.start else { return nil }
        return Date(timeIntervalSinceReferenceDate: end.timeIntervalSinceReferenceDate.nextDown)
    }

}

/// The small practice tag drawn in each page's corner in the reader.
struct ScorePageBadgeInfo: Equatable {
    /// 0 = not practised, 1...7 heatmap level.
    var level: Int
    var text: String
    var accessibilityLabel: String

    static func make(details: [Int: ScorePracticeSummary.PageDetail], pageCount: Int,
                     now: Date = Date(), calendar: Calendar = .current,
                     locale: Locale = AppLocalization.locale) -> [Int: ScorePageBadgeInfo] {
        let maximum = details.values.map(\.practice).max() ?? 0
        var result: [Int: ScorePageBadgeInfo] = [:]
        for page in 1...max(1, pageCount) {
            let pageLabel = "score.pageLabel".localizedFormat(String(page))
            guard let detail = details[page], detail.practice > 0, let last = detail.lastPracticed else {
                let text = "score.notPracticed".localized
                result[page] = .init(level: 0, text: text, accessibilityLabel: "\(pageLabel), \(text)")
                continue
            }
            let day = ScorePracticeFormat.day(last, now: now, calendar: calendar, locale: locale)
            let practice = ScorePracticeFormat.compact(detail.practice, locale: locale)
            var text = "\(day) · \(practice)"
            var spoken = "\(pageLabel), \(day), \(practice)"
            if detail.metronome > 0 {
                let metronome = ScorePracticeFormat.compact(detail.metronome, locale: locale)
                text += "  ♩\(metronome)"
                spoken += ", \("score.withMetronome".localized) \(metronome)"
            }
            result[page] = .init(level: ScorePageHeatmap.level(detail.practice, maximum: maximum),
                                 text: text, accessibilityLabel: spoken)
        }
        return result
    }
}

enum ScorePracticeFormat {
    /// "1h 30m" / "1小时30分钟", "26m"; under a minute rounds up to one minute.
    static func compact(_ seconds: TimeInterval, locale: Locale) -> String {
        let formatter = DateComponentsFormatter()
        var calendar = Calendar.current
        calendar.locale = locale
        formatter.calendar = calendar
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute]
        formatter.zeroFormattingBehavior = .dropAll
        let rounded = max(60, (seconds / 60).rounded() * 60)
        return formatter.string(from: rounded) ?? ""
    }

    /// Today / Yesterday / 3 days ago within a week, otherwise a short date (Oct 26 / 10月26日).
    static func day(_ date: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                           to: calendar.startOfDay(for: now)).day ?? 0
        if (0...6).contains(days) {
            let formatter = RelativeDateTimeFormatter()
            formatter.locale = locale
            formatter.calendar = calendar
            formatter.dateTimeStyle = .named
            formatter.unitsStyle = .full
            return formatter.localizedString(from: DateComponents(day: -days))
        }
        return date.formatted(Date.FormatStyle(date: .omitted, time: .omitted).month(.abbreviated).day().locale(locale))
    }
}

/// Shared by reader tags and statistics. All aggregation runs on this actor,
/// never in a SwiftUI body; only a few recent period/revision snapshots are kept.
actor ScorePracticeSummaryCache {
    struct Key: Hashable {
        var history: Int
        var visits: Int? = nil
        var range: DateInterval? = nil
        var day: Date
    }
    private var values: [Key: [ScorePracticeSummary]] = [:]
    private var order: [Key] = []
    private(set) var buildCount = 0

    func summaries(key: Key, sessions: [FocusSession], visits: [ScoreReadingVisit], asOf: Date) -> [ScorePracticeSummary] {
        guard !Task.isCancelled else { return [] }
        if let cached = values[key] { return cached }
        let result = ScorePracticeSummary.build(sessions: sessions, visits: visits, in: key.range, asOf: asOf)
        guard !Task.isCancelled else { return [] }
        buildCount += 1
        values[key] = result
        order.append(key)
        while order.count > 4 { values.removeValue(forKey: order.removeFirst()) }
        return result
    }
}
