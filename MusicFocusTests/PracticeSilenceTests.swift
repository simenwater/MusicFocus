import XCTest
@testable import MusicFocus

final class PracticeSilenceTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_790_000_000)

    private func update(_ evidence: PracticeEvidence, _ time: Double) -> PracticeDetectionUpdate {
        PracticeDetectionUpdate(endTime: time, evaluatedDuration: 0.5,
            decibels: evidence == .silence ? -100 : -72,
            scores: .init(classifications: [:]), evidence: evidence,
            isPracticing: evidence == .music,
            noiseRatio: evidence == .speech || evidence == .noise ? 1 : 0,
            exitedForNoise: evidence == .speech || evidence == .noise)
    }

    @MainActor
    private func manager(delay: Double = 3) -> (FocusManager, UserDefaults, String) {
        let name = "MusicFocus.SilenceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        let manager = FocusManager(historyDefaults: defaults, settingsDefaults: defaults)
        manager.selectSilenceConfirmationDelay(delay)
        manager.isActive = true
        manager.currentSession = FocusSession(startTime: base, distractions: [])
        manager.startDistraction(description: "Waiting", at: base)
        return (manager, defaults, name)
    }

    @MainActor
    private func feed(_ manager: FocusManager, _ evidence: PracticeEvidence, _ time: Double) {
        manager.audioMonitor.receive(update(evidence, time), at: base.addingTimeInterval(time))
    }

    func testEveryDelayConfirmsExactlyAtItsBoundary() {
        for delay in 0...60 {
            var segment = PracticeSilenceSegmentation()
            XCTAssertTrue(segment.consume(update(.music, 1), delay: Double(delay)).isActive)
            let first = segment.consume(update(.silence, 1.5), delay: Double(delay))
            XCTAssertEqual(first.isWaitingForSilence, delay > 0)
            if delay == 0 { XCTAssertFalse(first.isActive); continue }
            for elapsed in stride(from: 0.5, to: Double(delay), by: 0.5) {
                XCTAssertTrue(segment.consume(update(.silence, 1.5 + elapsed), delay: Double(delay)).isWaitingForSilence)
            }
            let end = segment.consume(update(.silence, 1.5 + Double(delay)), delay: Double(delay))
            XCTAssertFalse(end.isActive)
            XCTAssertFalse(end.isWaitingForSilence)
        }
    }

    func testSpeechNoiseAndMissingInputBypassDelay() {
        for evidence in [PracticeEvidence.speech, .noise] {
            for delay in [0.0, 3, 8, 30, 60] {
                var segment = PracticeSilenceSegmentation()
                _ = segment.consume(update(.music, 1), delay: delay)
                _ = segment.consume(update(.silence, 1.5), delay: delay)
                XCTAssertFalse(segment.consume(update(evidence, 2), delay: delay).isActive)
                XCTAssertTrue(segment.consume(update(.music, 2.5), delay: delay).isActive)
            }
        }
        var segment = PracticeSilenceSegmentation()
        XCTAssertFalse(segment.consume(update(.silence, 1), delay: 8).isWaitingForSilence)
        _ = segment.consume(update(.music, 1.5), delay: 8)
        _ = segment.consume(update(.silence, 2), delay: 8)
        XCTAssertFalse(segment.consume(update(.silence, 4), delay: 8).isActive)
    }

    @MainActor
    func testDefaultBoundsPersistenceAndActiveSessionLock() {
        let name = "MusicFocus.SilenceSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let manager = FocusManager(historyDefaults: defaults, settingsDefaults: defaults)
        XCTAssertEqual(manager.silenceConfirmationDelay, 3)
        XCTAssertEqual(manager.audioMonitor.silenceConfirmationDelay, 3)
        for (input, expected) in [(0.0, 0.0), (8, 8), (30, 30), (59.6, 60), (60, 60), (-2, 0), (99, 60), (.nan, 3), (.infinity, 3)] {
            manager.selectSilenceConfirmationDelay(input)
            XCTAssertEqual(manager.silenceConfirmationDelay, expected)
            let reopened = FocusManager(historyDefaults: defaults, settingsDefaults: defaults)
            XCTAssertEqual(reopened.silenceConfirmationDelay, expected)
            XCTAssertEqual(reopened.audioMonitor.silenceConfirmationDelay, expected)
        }
        manager.isActive = true
        manager.selectSilenceConfirmationDelay(8)
        XCTAssertEqual(manager.silenceConfirmationDelay, 3)
        manager.isActive = false
    }

    @MainActor
    func testShortSilenceFreezesTimeWithoutCreatingAnInterruption() throws {
        let (manager, defaults, name) = manager()
        defer { manager.isActive = false; defaults.removePersistentDomain(forName: name) }
        feed(manager, .music, 1)
        feed(manager, .silence, 2)
        XCTAssertNil(manager.currentDistraction)
        XCTAssertNotNil(manager.pendingSilenceStart)
        XCTAssertTrue(manager.audioMonitor.isWaitingForSilence)
        XCTAssertEqual(manager.getFullSessionStats(at: base.addingTimeInterval(2.5)).totalFocusTime, 1)
        feed(manager, .music, 3)
        XCTAssertNil(manager.pendingSilenceStart)
        XCTAssertNil(manager.currentDistraction)
        XCTAssertEqual(manager.currentSession?.distractions.count, 1, "Only initial waiting is a confirmed interruption")
        XCTAssertEqual(manager.currentSession?.unsegmentedSilences?.count, 1)
        XCTAssertEqual(manager.getFullSessionStats(at: base.addingTimeInterval(3)).totalFocusTime, 1)
        XCTAssertEqual(manager.getFullSessionStats(at: base.addingTimeInterval(4)).totalFocusTime, 2)
        var saved = try XCTUnwrap(manager.currentSession)
        saved.endTime = base.addingTimeInterval(4)
        manager.allSessions = [saved]
        let reopened = FocusManager(historyDefaults: defaults, settingsDefaults: defaults)
        XCTAssertEqual(reopened.allSessions.first?.totalFocusTime, 2)
        XCTAssertEqual(reopened.allSessions.first?.unsegmentedSilences?.count, 1)
    }

    @MainActor
    func testLongSilenceBackdatesInterruptionWithoutDoubleCounting() {
        let (manager, defaults, name) = manager()
        defer { manager.isActive = false; defaults.removePersistentDomain(forName: name) }
        feed(manager, .music, 1)
        for time in stride(from: 2.0, through: 4.5, by: 0.5) { feed(manager, .silence, time) }
        XCTAssertNil(manager.currentDistraction)
        XCTAssertEqual(manager.getFullSessionStats(at: base.addingTimeInterval(4.5)).totalFocusTime, 1)
        feed(manager, .silence, 5)
        XCTAssertNil(manager.pendingSilenceStart)
        XCTAssertEqual(manager.currentDistraction?.startTime, base.addingTimeInterval(2))
        XCTAssertEqual(manager.getFullSessionStats(at: base.addingTimeInterval(5)).totalFocusTime, 1)
        feed(manager, .music, 5.5)
        XCTAssertEqual(manager.currentSession?.distractions.count, 2)
        XCTAssertTrue(manager.currentSession?.unsegmentedSilences?.isEmpty ?? true)
        XCTAssertEqual(manager.getFullSessionStats(at: base.addingTimeInterval(6)).totalFocusTime, 1.5)
    }

    @MainActor
    func testZeroDelayIsImmediateAndEightSecondsNeverCountAsPractice() {
        for delay in [0.0, 8.0] {
            let (manager, defaults, name) = manager(delay: delay)
            defer { manager.isActive = false; defaults.removePersistentDomain(forName: name) }
            feed(manager, .music, 1)
            feed(manager, .silence, 2)
            if delay == 0 {
                XCTAssertNotNil(manager.currentDistraction)
                XCTAssertNil(manager.pendingSilenceStart)
            } else {
                for time in stride(from: 2.5, through: 9.5, by: 0.5) {
                    feed(manager, .silence, time)
                    XCTAssertNil(manager.currentDistraction)
                    XCTAssertEqual(manager.getFullSessionStats(at: base.addingTimeInterval(time)).totalFocusTime, 1)
                }
                feed(manager, .silence, 10)
                XCTAssertNotNil(manager.currentDistraction)
            }
            XCTAssertEqual(manager.getFullSessionStats(at: base.addingTimeInterval(10)).totalFocusTime, 1)
        }
    }

    @MainActor
    func testMinuteDelayReconnectsWithoutCountingTheLongPause() throws {
        let (manager, defaults, name) = manager(delay: 60)
        defer { manager.isActive = false; defaults.removePersistentDomain(forName: name) }
        feed(manager, .music, 1)
        for time in stride(from: 2.0, through: 61.0, by: 0.5) {
            feed(manager, .silence, time)
            XCTAssertNil(manager.currentDistraction)
            XCTAssertTrue(manager.audioMonitor.isWaitingForSilence)
            XCTAssertEqual(manager.getFullSessionStats(at: base.addingTimeInterval(time)).totalFocusTime, 1)
        }
        feed(manager, .music, 61.5)
        XCTAssertNil(manager.currentDistraction)
        XCTAssertNil(manager.pendingSilenceStart)
        XCTAssertEqual(manager.currentSession?.distractions.count, 1, "Only the initial waiting interval")
        XCTAssertEqual(manager.currentSession?.unsegmentedSilences?.count, 1)
        XCTAssertEqual(manager.getFullSessionStats(at: base.addingTimeInterval(62.5)).totalFocusTime, 2)
        var saved = try XCTUnwrap(manager.currentSession)
        saved.endTime = base.addingTimeInterval(62.5)
        let restored = try JSONDecoder().decode(FocusSession.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(restored.totalFocusTime, 2)
    }

    @MainActor
    func testMinuteDelayExpiresAndFinalizingStillExcludesWaiting() throws {
        for endEarly in [false, true] {
            let (manager, defaults, name) = manager(delay: 60)
            defer { manager.isActive = false; defaults.removePersistentDomain(forName: name) }
            feed(manager, .music, 1)
            let end = endEarly ? 32.0 : 62.0
            for time in stride(from: 2.0, through: end, by: 0.5) { feed(manager, .silence, time) }
            if !endEarly {
                XCTAssertEqual(manager.currentDistraction?.startTime, base.addingTimeInterval(2))
                XCTAssertFalse(manager.audioMonitor.isWaitingForSilence)
            }
            manager.finishPendingSilence(at: base.addingTimeInterval(end))
            var saved = try XCTUnwrap(manager.currentSession)
            if let distraction = manager.currentDistraction {
                var closed = distraction; closed.endTime = base.addingTimeInterval(end)
                saved.distractions.append(closed)
            }
            saved.endTime = base.addingTimeInterval(end)
            XCTAssertEqual(saved.totalFocusTime, 1)
        }
    }

    func testLongMergedPauseAcrossMonthIsExcludedFromBothMonths() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: 23, minute: 59, second: 30))!
        var session = FocusSession(startTime: start, endTime: start.addingTimeInterval(120), distractions: [])
        session.silenceConfirmationDelay = 60
        session.unsegmentedSilences = [Distraction(startTime: start.addingTimeInterval(10),
            endTime: start.addingTimeInterval(60), description: "Pause")]
        let stats = PracticeStatistics(sessions: [session], calendar: calendar, asOf: start.addingTimeInterval(120))
        XCTAssertEqual(stats.month(containing: start).focusTime, 10)
        XCTAssertEqual(stats.month(containing: session.endTime!).focusTime, 60)
        XCTAssertEqual(session.totalFocusTime, 70)
    }

    @MainActor
    func testSpeechDuringPendingSilenceConfirmsImmediately() {
        let (manager, defaults, name) = manager(delay: 8)
        defer { manager.isActive = false; defaults.removePersistentDomain(forName: name) }
        feed(manager, .music, 1)
        feed(manager, .silence, 2)
        feed(manager, .speech, 2.5)
        XCTAssertFalse(manager.audioMonitor.isWaitingForSilence)
        XCTAssertNil(manager.pendingSilenceStart)
        XCTAssertEqual(manager.currentDistraction?.startTime, base.addingTimeInterval(2))
        XCTAssertEqual(manager.getFullSessionStats(at: base.addingTimeInterval(3)).totalFocusTime, 1)
    }

    @MainActor
    func testFinalizingWhileWaitingPreservesSilentTail() throws {
        let (manager, defaults, name) = manager()
        defer { manager.isActive = false; defaults.removePersistentDomain(forName: name) }
        feed(manager, .music, 1)
        feed(manager, .silence, 2)
        // This is the same settlement performed by endSession before persistence.
        manager.finishPendingSilence(at: base.addingTimeInterval(3))
        var final = try XCTUnwrap(manager.currentSession)
        final.endTime = base.addingTimeInterval(3)
        XCTAssertNil(manager.pendingSilenceStart)
        XCTAssertEqual(final.totalFocusTime, 1)
        XCTAssertEqual(final.distractionTime, 2)
        XCTAssertEqual(final.distractions.count, 1)
    }

    @MainActor
    func testBackgroundInterruptionIncludesPendingSilenceOnlyOnce() {
        let (manager, defaults, name) = manager()
        defer { manager.isActive = false; defaults.removePersistentDomain(forName: name) }
        feed(manager, .music, 1)
        feed(manager, .silence, 2)
        manager.audioMonitor.stopMonitoring()
        manager.startDistraction(description: DistractionType.appSwitch.rawValue, at: base.addingTimeInterval(2.5))
        XCTAssertEqual(manager.currentDistraction?.startTime, base.addingTimeInterval(2))
        XCTAssertNil(manager.pendingSilenceStart)
        XCTAssertEqual(manager.getFullSessionStats(at: base.addingTimeInterval(4)).totalFocusTime, 1)
    }

    @MainActor
    func testShortGapsAcrossMonthAreExcludedFromBothDaysAndBadges() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: 23, minute: 30))!
        var session = FocusSession(startTime: start, endTime: start.addingTimeInterval(3600), distractions: [])
        session.silenceConfirmationDelay = 3
        session.unsegmentedSilences = [Distraction(startTime: start.addingTimeInterval(1799),
            endTime: start.addingTimeInterval(1802), description: "Short silence")]
        let encoded = try JSONEncoder().encode(session)
        let restored = try JSONDecoder().decode(FocusSession.self, from: encoded)
        let stats = PracticeStatistics(sessions: [restored], calendar: calendar, asOf: start.addingTimeInterval(7200))
        XCTAssertEqual(stats.month(containing: start).focusTime, 1799)
        XCTAssertEqual(stats.month(containing: session.endTime!).focusTime, 1798)
        let name = "MusicFocus.SilenceBadgeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let badges = BadgeManager(defaults: defaults)
        badges.reconcile(with: stats)
        XCTAssertTrue(badges.badges.isEmpty)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "silenceConfirmationDelay")
        legacy.removeValue(forKey: "unsegmentedSilences")
        let old = try JSONDecoder().decode(FocusSession.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(old.unsegmentedSilences)
        XCTAssertNil(old.silenceConfirmationDelay)
    }
}
