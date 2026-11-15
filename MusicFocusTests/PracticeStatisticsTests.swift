import XCTest
@testable import MusicFocus

final class PracticeStatisticsTests: XCTestCase {
    private func calendar(_ zone: String = "Asia/Shanghai") -> Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(identifier: zone)!
        return result
    }

    private func date(_ value: String, in calendar: Calendar? = nil) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = calendar ?? self.calendar()
        formatter.timeZone = formatter.calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: value)!
    }

    private func session(_ start: String, _ end: String, pauses: [(String, String)] = [],
                         in calendar: Calendar? = nil) -> FocusSession {
        FocusSession(startTime: date(start, in: calendar), endTime: date(end, in: calendar),
            distractions: pauses.map {
                Distraction(startTime: date($0.0, in: calendar), endTime: date($0.1, in: calendar), description: "Pause")
            })
    }

    private func isolatedDefaults() -> (UserDefaults, String) {
        let name = "MusicFocus.StatisticsTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    func testMidnightAndMonthSplitSubtractPausesOnTheCorrectDay() {
        let item = session("2026-09-30 23:50:00", "2026-10-01 00:20:00",
            pauses: [("2026-09-30 23:55:00", "2026-10-01 00:05:00")])
        let stats = PracticeStatistics(sessions: [item], calendar: calendar(), asOf: date("2026-10-02 12:00:00"))
        let september = stats.month(containing: item.startTime)
        let october = stats.month(containing: item.endTime!)
        XCTAssertEqual(september.focusTime, 300)
        XCTAssertEqual(september.pauseTime, 300)
        XCTAssertEqual(october.focusTime, 900)
        XCTAssertEqual(october.pauseTime, 300)
        XCTAssertEqual(september.practiceDays, 1)
        XCTAssertEqual(october.practiceDays, 1)
        XCTAssertEqual(september.focusTime + october.focusTime, 1200)
        XCTAssertEqual(stats.day(item.endTime!).sessions.first?.startTime, item.startTime,
                       "Editing must retain the complete original session, not a destructive day slice")
    }

    func testExactMidnightDoesNotCreateAnExtraDay() {
        let item = session("2026-12-31 23:00:00", "2027-01-01 00:00:00")
        let stats = PracticeStatistics(sessions: [item], calendar: calendar(), asOf: date("2027-01-02 12:00:00"))
        XCTAssertEqual(stats.days.count, 1)
        XCTAssertEqual(stats.month(containing: item.startTime).focusTime, 3600)
        XCTAssertEqual(stats.month(containing: item.endTime!).focusTime, 0)
    }

    func testCrossYearAndLeapDayUseCalendarDays() {
        let year = session("2025-12-31 23:50:00", "2026-01-01 00:10:00")
        let leap = session("2024-02-28 23:50:00", "2024-03-01 00:10:00")
        let stats = PracticeStatistics(sessions: [year, leap], calendar: calendar(), asOf: date("2026-01-02 12:00:00"))
        XCTAssertEqual(stats.day(date("2026-01-01 12:00:00")).focusTime, 600)
        XCTAssertEqual(stats.day(date("2024-02-29 12:00:00")).focusTime, 86400)
        XCTAssertEqual(stats.month(containing: leap.startTime).practiceDays, 2)
        XCTAssertEqual(stats.month(containing: date("2024-03-01 12:00:00")).focusTime, 600)
    }

    func testDaylightSavingDaysAre23And25Hours() {
        let zone = calendar("Europe/Paris")
        for (start, end, hours) in [("2026-03-29 00:00:00", "2026-03-30 00:00:00", 23),
                                  ("2026-10-25 00:00:00", "2026-10-26 00:00:00", 25)] {
            let item = session(start, end, in: zone)
            let stats = PracticeStatistics(sessions: [item], calendar: zone, asOf: date("2026-10-27 00:00:00", in: zone))
            XCTAssertEqual(stats.days.count, 1)
            XCTAssertEqual(stats.day(item.startTime).focusTime, Double(hours * 3600))
        }
    }

    func testTimeZoneChangeReassignsTheSameSessionWithoutChangingItsDuration() {
        let item = session("2026-10-01 00:10:00", "2026-10-01 00:40:00")
        let now = date("2026-10-02 12:00:00")
        let shanghai = PracticeStatistics(sessions: [item], calendar: calendar(), asOf: now)
        let paris = PracticeStatistics(sessions: [item], calendar: calendar("Europe/Paris"), asOf: now)
        XCTAssertEqual(shanghai.calendar.component(.day, from: shanghai.days.keys.first!), 1)
        XCTAssertEqual(paris.calendar.component(.day, from: paris.days.keys.first!), 30)
        XCTAssertEqual(shanghai.days.values.first?.focusTime, paris.days.values.first?.focusTime)
    }

    func testRecentSevenDaysClipsTheFirstDayAndExcludesFutureAndOldRecords() {
        let items = [session("2026-10-14 23:50:00", "2026-10-15 00:10:00"),
                     session("2026-10-14 12:00:00", "2026-10-14 13:00:00"),
                     session("2026-10-21 09:00:00", "2026-10-21 09:00:20"),
                     session("2026-10-22 09:00:00", "2026-10-22 10:00:00")]
        let stats = PracticeStatistics(sessions: items, calendar: calendar(), asOf: date("2026-10-21 12:00:00"))
        let week = stats.summary(in: stats.recentWeek)
        XCTAssertEqual(week.focusTime, 620)
        XCTAssertEqual(week.practiceDays, 2)
    }

    func testSubMinutePracticeCountsButOnlyPausedDaysDoNotCountAsPracticeDays() {
        let items = [session("2026-10-01 10:00:00", "2026-10-01 10:00:20"),
                     session("2026-10-02 10:00:00", "2026-10-02 10:10:00",
                        pauses: [("2026-10-02 10:00:00", "2026-10-02 10:10:00")])]
        let stats = PracticeStatistics(sessions: items, calendar: calendar(), asOf: date("2026-10-03 12:00:00"))
        let month = stats.month(containing: items[0].startTime)
        XCTAssertEqual(month.focusTime, 20)
        XCTAssertEqual(month.pauseTime, 600)
        XCTAssertEqual(month.practiceDays, 1)
        XCTAssertEqual(stats.day(items[1].startTime).sessions.count, 1)
    }

    func testOverlappingAndOutOfBoundsPausesCannotDoubleCountOrMakeTotalsNegative() {
        let item = session("2026-10-01 10:00:00", "2026-10-01 10:10:00", pauses: [
            ("2026-10-01 09:59:00", "2026-10-01 10:03:00"),
            ("2026-10-01 10:02:00", "2026-10-01 10:05:00"),
            ("2026-10-01 10:08:00", "2026-10-01 10:12:00"),
            ("2026-10-01 10:07:00", "2026-10-01 10:06:00")])
        let totals = PracticeTimeAccounting.totals(item, asOf: date("2026-10-02 00:00:00"))
        XCTAssertEqual(totals.focus, 180)
        XCTAssertEqual(totals.pause, 420)
    }

    func testMalformedUnfinishedAndDuplicateRecordsDoNotInflateStatistics() {
        let valid = session("2026-10-01 10:00:00", "2026-10-01 10:30:00")
        var unfinished = valid
        unfinished.id = UUID()
        unfinished.endTime = nil
        let reversed = session("2026-10-01 11:00:00", "2026-10-01 10:00:00")
        let zero = session("2026-10-01 12:00:00", "2026-10-01 12:00:00")
        let stats = PracticeStatistics(sessions: [valid, valid, unfinished, reversed, zero],
            calendar: calendar(), asOf: date("2026-10-02 12:00:00"))
        XCTAssertEqual(stats.day(valid.startTime).focusTime, 1800)
        XCTAssertEqual(stats.day(valid.startTime).sessions.count, 1)
    }

    @MainActor
    func testEveryBadgeThresholdIncludesTheExactBoundary() {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let manager = BadgeManager(defaults: defaults)
        let levels = BadgeLevel.allCases
        for (index, level) in levels.enumerated() {
            let threshold = level.timeRange.lowerBound
            XCTAssertEqual(manager.calculateBadge(practiceTime: threshold), level)
            XCTAssertEqual(manager.calculateBadge(practiceTime: threshold - 1 / 60), index == 0 ? nil : levels[index - 1])
            XCTAssertEqual(manager.calculateBadge(practiceTime: threshold + 1 / 60), level)
        }
        XCTAssertNil(manager.calculateBadge(practiceTime: -.infinity))
        XCTAssertNil(manager.calculateBadge(practiceTime: .infinity))
        XCTAssertNil(manager.calculateBadge(practiceTime: .nan))
    }

    @MainActor
    func testCrossMidnightAwardsBothDaysAndDoesNotDuplicateOnRebuild() {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let manager = BadgeManager(defaults: defaults)
        let item = session("2026-09-30 23:30:00", "2026-10-01 01:00:00")
        let stats = PracticeStatistics(sessions: [item], calendar: calendar(), asOf: date("2026-10-02 12:00:00"))
        manager.reconcile(with: stats)
        XCTAssertEqual(manager.badges.map(\.level), [.bronze, .silver])
        let ids = manager.badges.map(\.id)
        manager.reconcile(with: stats)
        XCTAssertEqual(manager.badges.map(\.id), ids)
        XCTAssertEqual(BadgeManager(defaults: defaults).badges, manager.badges)
    }

    @MainActor
    func testDeletingHistoryDowngradesAndRemovesBadgesAndPersistsImmediately() throws {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let now = date("2026-10-02 12:00:00")
        let manager = FocusManager(historyDefaults: defaults, calendar: calendar(), now: { now })
        let first = session("2026-10-01 10:00:00", "2026-10-01 10:30:00")
        let second = session("2026-10-01 11:00:00", "2026-10-01 11:30:00")
        manager.allSessions = [first, second]
        XCTAssertEqual(manager.badgeManager.badges.first?.level, .silver)
        manager.allSessions.removeAll { $0.id == second.id }
        XCTAssertEqual(manager.badgeManager.badges.first?.level, .bronze)
        let saved = try XCTUnwrap(defaults.data(forKey: "focusSessions"))
        XCTAssertEqual(try JSONDecoder().decode([FocusSession].self, from: saved).count, 1)
        let restored = FocusManager(historyDefaults: defaults, calendar: calendar(), now: { now })
        XCTAssertEqual(restored.getTotalFocusTimeForDate(first.startTime), 1800)
        manager.clearAllSessions()
        XCTAssertTrue(manager.badgeManager.badges.isEmpty)
        XCTAssertTrue(BadgeManager(defaults: defaults).badges.isEmpty)
    }

    @MainActor
    func testRolloverRefreshAndCrossDayDeletionUseOriginalSessionIDs() {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        var now = date("2026-10-01 23:59:59")
        let manager = FocusManager(historyDefaults: defaults, calendar: calendar(), now: { now })
        let item = session("2026-09-24 23:50:00", "2026-09-25 00:10:00")
        manager.allSessions = [item]
        XCTAssertEqual(manager.practiceStatistics.summary(in: manager.practiceStatistics.recentWeek).focusTime, 600)
        now = date("2026-10-02 00:00:01")
        NotificationCenter.default.post(name: .NSCalendarDayChanged, object: nil)
        XCTAssertEqual(manager.practiceStatistics.summary(in: manager.practiceStatistics.recentWeek).focusTime, 0)
        XCTAssertEqual(manager.deleteSessionsForDate(item.endTime!), 1)
        XCTAssertTrue(manager.allSessions.isEmpty)
    }

    @MainActor
    func testUnreadableHistoryDoesNotErasePreviouslySavedBadges() {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let old = BadgeManager(defaults: defaults)
        old.addBadge(Badge(level: .silver, date: date("2026-10-01 12:00:00")))
        let damaged = Data("invalid history".utf8)
        defaults.set(damaged, forKey: "focusSessions")
        let manager = FocusManager(historyDefaults: defaults)
        XCTAssertEqual(manager.badgeManager.badges, old.badges)
        XCTAssertEqual(defaults.data(forKey: "focusSessions"), damaged)
    }

    @MainActor
    func testRebuildRepairsLegacyBadgeAndNeverAwardsPauseTime() {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let old = BadgeManager(defaults: defaults)
        old.addBadge(Badge(level: .king, date: date("2026-10-01 12:00:00")))
        let item = session("2026-10-01 10:00:00", "2026-10-01 12:00:00",
                           pauses: [("2026-10-01 10:00:00", "2026-10-01 11:30:00")])
        old.reconcile(with: PracticeStatistics(sessions: [item], calendar: calendar(), asOf: date("2026-10-02 12:00:00")))
        XCTAssertEqual(old.badges.map(\.level), [.bronze])
    }

    @MainActor
    func testOlderHistorySurvivesWeeklyRolloverMonthChangeAndRestart() throws {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        var now = date("2026-10-29 21:00:00") // Thursday
        let original = session("2026-10-29 19:00:00", "2026-10-29 19:30:00")
        let manager = FocusManager(historyDefaults: defaults, settingsDefaults: defaults, calendar: calendar(), now: { now })
        manager.allSessions = [original]
        for day in ["2026-11-05 21:00:00", "2026-12-01 12:00:00", "2027-01-01 12:00:00"] {
            now = date(day)
            NotificationCenter.default.post(name: .NSCalendarDayChanged, object: nil)
            XCTAssertEqual(manager.practiceStatistics.summary(in: manager.practiceStatistics.recentWeek).focusTime, 0)
            XCTAssertEqual(manager.getTotalFocusTimeForDate(original.startTime), 1800)
            XCTAssertEqual(manager.practiceStatistics.month(containing: original.startTime).focusTime, 1800)
            let reopened = FocusManager(historyDefaults: defaults, settingsDefaults: defaults, calendar: calendar(), now: { now })
            XCTAssertEqual(reopened.allSessions.map(\.id), [original.id])
            XCTAssertEqual(reopened.getTotalFocusTimeForDate(original.startTime), 1800)
        }
        manager.allSessions.append(session("2027-01-01 10:00:00", "2027-01-01 10:10:00"))
        let saved = try JSONDecoder().decode([FocusSession].self, from: XCTUnwrap(defaults.data(forKey: "focusSessions")))
        XCTAssertEqual(saved.count, 2)
        XCTAssertEqual(saved.first?.id, original.id)
    }

    func testTenThousandRecordsBuildOnceAndRepeatedMonthQueriesStayCheap() {
        let base = date("2020-01-01 10:00:00")
        let items = (0..<10_000).map { index in
            let start = base.addingTimeInterval(Double(index) * 7200)
            return FocusSession(startTime: start, endTime: start.addingTimeInterval(1800), distractions: [])
        }
        let start = ProcessInfo.processInfo.systemUptime
        let stats = PracticeStatistics(sessions: items, calendar: calendar(), asOf: date("2026-10-21 12:00:00"))
        let built = ProcessInfo.processInfo.systemUptime
        var checksum = 0.0
        for _ in 0..<1000 { checksum += stats.month(containing: base).focusTime }
        let ended = ProcessInfo.processInfo.systemUptime
        XCTAssertEqual(stats.days.values.reduce(0) { $0 + $1.sessions.count }, items.count)
        XCTAssertGreaterThan(checksum, 0)
        let report = "STATISTICS_BENCHMARK records=10000 buildMS=\((built-start)*1000) monthQueries=1000 queryMS=\((ended-built)*1000)"
        print(report)
        let attachment = XCTAttachment(string: report)
        attachment.name = "Statistics performance"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertLessThan(ended - built, 2, "Month lookups must use cached days rather than rescan 10,000 sessions")
    }
}
