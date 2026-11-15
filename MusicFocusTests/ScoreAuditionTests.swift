#if DEBUG
import XCTest
import PDFKit
@testable import MusicFocus

final class ScoreAuditionTests: XCTestCase {
    private let digest = String(repeating: "a", count: 64)
    private func package() -> ScoreAuditionPackage {
        .init(sourceSHA256: digest, title: "Test", notice: "Basic notes only", tempo: 80, duration: 0.8,
              cues: [.init(time: 0, duration: 0.75, page: 1, staff: 1, measure: 1, x: 80, y: 500)],
              audio: wave(), audioWithClicks: wave(), bars: [.init(measure: 1, start: 0, duration: 0.75)])
    }
    private func wave() -> Data {
        let rate = 8_000, samples = 6_400
        var data = Data()
        func text(_ value: String) { data.append(contentsOf: value.utf8) }
        func number<T: FixedWidthInteger>(_ value: T) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        text("RIFF"); number(UInt32(36 + samples * 2)); text("WAVEfmt "); number(UInt32(16))
        number(UInt16(1)); number(UInt16(1)); number(UInt32(rate)); number(UInt32(rate * 2))
        number(UInt16(2)); number(UInt16(16)); text("data"); number(UInt32(samples * 2))
        for index in 0..<samples { number(Int16(sin(Double(index) * 440 * 2 * .pi / Double(rate)) * 600)) }
        return data
    }

    func testPackageRoundTripAndDifferentPDFRejected() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        try JSONEncoder().encode(package()).write(to: url)
        let result = try ScoreAuditionPackage.read(url, digest: digest, pageCount: 4)
        XCTAssertEqual(result.cues.count, 1); XCTAssertEqual(result.audio, package().audio)
        XCTAssertThrowsError(try ScoreAuditionPackage.read(url, digest: String(repeating: "b", count: 64), pageCount: 4))
    }

    func testRejectsInvalidTimingCoordinatesPageAndVersion() {
        var mutations: [(inout ScoreAuditionPackage) -> Void] = [
            { $0.version = 2 }, { $0.duration = .infinity }, { $0.duration = 0 },
            { $0.tempo = .nan }, { $0.audio = Data() }, { $0.audioWithClicks = Data() },
            { $0.cues[0].x = .nan }, { $0.cues[0].y = .infinity },
            { $0.cues[0].page = 0 }, { $0.cues[0].page = 5 }, { $0.cues[0].staff = 17 },
            { $0.cues[0].time = -0.1 }, { $0.cues[0].duration = 10 }, { $0.cues = [] }
        ]
        mutations.append { value in
            var cue = value.cues[0]; cue.time = 0.4; cue.duration = 0.2
            value.cues.insert(cue, at: 0)
        }
        for mutate in mutations {
            var value = package(); mutate(&value)
            XCTAssertThrowsError(try value.validate(digest: digest, pageCount: 4))
        }
    }

    @MainActor
    func testActualAudioStopsAndPracticeGateIsReleased() async throws {
        let suite = UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let focus = FocusManager(historyDefaults: defaults, settingsDefaults: defaults)
        let voice = ScoreVoiceAudio(), player = ScoreAuditionPlayer()
        player.bind(focus: focus, voice: voice); player.load(package())
        for _ in 0..<3 {
            player.seek(0); player.play()
            XCTAssertTrue(focus.isReviewingVoiceNote)
            try await Task.sleep(for: .milliseconds(200))
            player.setRate(0.75); player.setClicks(true)
            try await Task.sleep(for: .milliseconds(200))
            player.pause()
            for _ in 0..<30 where focus.isReviewingVoiceNote { try await Task.sleep(for: .milliseconds(50)) }
            XCTAssertFalse(player.playing); XCTAssertFalse(player.preparing)
            XCTAssertFalse(focus.isReviewingVoiceNote)
            XCTAssertNil(player.error)
        }
        player.seek(0); player.setRate(1); player.play()
        for _ in 0..<60 where focus.isReviewingVoiceNote { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertFalse(focus.isReviewingVoiceNote, "Natural completion must resume measurement")
        XCTAssertFalse(player.playing)
        XCTAssertEqual(player.position, 0.8, accuracy: 0.05)
    }

    @MainActor
    func testCancelledPreparationAndInvalidAudioNeverLeaveGateActive() async throws {
        let suite = UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let focus = FocusManager(historyDefaults: defaults, settingsDefaults: defaults)
        let voice = ScoreVoiceAudio(), player = ScoreAuditionPlayer()
        player.bind(focus: focus, voice: voice); player.load(package())
        player.play(); player.pause(); player.play(); player.pause()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(focus.isReviewingVoiceNote); XCTAssertFalse(player.playing)
        var bad = package(); bad.audio = Data("not audio".utf8)
        player.load(bad); player.play()
        for _ in 0..<40 where focus.isReviewingVoiceNote { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertNotNil(player.error); XCTAssertFalse(focus.isReviewingVoiceNote)
        XCTAssertFalse(player.preparing)
    }

    func testInclusiveReversedAndLastBarLoopBounds() throws {
        var p = package()
        p.cues = [
            .init(time: 0, duration: 0.2, page: 1, staff: 1, measure: 1, x: 80, y: 500),
            .init(time: 0.2, duration: 0.2, page: 1, staff: 2, measure: 1, x: 100, y: 400),
            .init(time: 0.4, duration: 0.25, page: 2, staff: 1, measure: 2, x: 80, y: 500)]
        p.bars = [.init(measure: 1, start: 0, duration: 0.4), .init(measure: 2, start: 0.4, duration: 0.25)]
        let first = try XCTUnwrap(p.loop(from: p.cues[1], through: p.cues[0]))
        XCTAssertEqual(first.start, 0); XCTAssertEqual(first.end, 0.4)
        let reverse = try XCTUnwrap(p.loop(from: p.cues[2], through: p.cues[0]))
        XCTAssertEqual(reverse, p.loop(from: p.cues[0], through: p.cues[2]))
        XCTAssertEqual(reverse.end, 0.65, accuracy: 0.000001, "Exclude rendered reverb tail")
        p.cues[0].time = 0.1; p.cues[0].duration = 0.1
        XCTAssertEqual(p.loop(from: p.cues[0], through: p.cues[0])?.start, 0, "Leading rest belongs in the bar")
        p.bars = nil
        XCTAssertNil(p.loop(from: p.cues[0], through: p.cues[0]), "Never guess rest boundaries in legacy previews")
        XCTAssertFalse(ScoreAuditionLoop(start: .nan, end: 1, firstMeasure: 1, lastMeasure: 1).isValid(for: 2))
    }

    @MainActor
    func testActualLoopRepeatsAndTapOutsideResumesFullScoreWithoutCountingPractice() async throws {
        let suite = UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let focus = FocusManager(historyDefaults: defaults, settingsDefaults: defaults)
        let voice = ScoreVoiceAudio(), player = ScoreAuditionPlayer()
        var p = package()
        p.cues = [.init(time: 0, duration: 0.4, page: 1, staff: 1, measure: 1, x: 80, y: 500),
                  .init(time: 0.4, duration: 0.25, page: 1, staff: 1, measure: 2, x: 100, y: 500)]
        p.bars = [.init(measure: 1, start: 0, duration: 0.4), .init(measure: 2, start: 0.4, duration: 0.25)]
        player.bind(focus: focus, voice: voice); player.load(p)
        player.beginLoopSelection(); player.tap(p.cues[1]); XCTAssertFalse(player.playing)
        player.tap(p.cues[1])
        for _ in 0..<40 where !player.playing && player.error == nil { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertNil(player.error); XCTAssertTrue(player.playing); XCTAssertTrue(player.loopEnabled)
        XCTAssertFalse(player.selectingLoop); XCTAssertTrue(focus.isReviewingVoiceNote)
        var wraps = 0, last = player.visualPosition
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(50))
            let time = player.visualPosition
            if time < last - 0.08 { wraps += 1 }; last = time
            XCTAssertTrue(player.playing); XCTAssertGreaterThanOrEqual(time, 0.4); XCTAssertLessThan(time, 0.65)
        }
        XCTAssertGreaterThanOrEqual(wraps, 3, "Must loop beyond the original audio's end")
        player.setClicks(true); player.setRate(0.75)
        try await Task.sleep(for: .milliseconds(150)); XCTAssertTrue(player.loopEnabled)
        player.pause()
        for _ in 0..<40 where focus.isReviewingVoiceNote { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertFalse(focus.isReviewingVoiceNote)
        player.tap(p.cues[0]); XCTAssertFalse(player.loopEnabled)
        for _ in 0..<80 where focus.isReviewingVoiceNote { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertFalse(player.playing); XCTAssertFalse(focus.isReviewingVoiceNote)
        XCTAssertNil(player.error)
        // Rapid replacement of pending preparations cannot resurrect an old loop.
        for _ in 0..<5 { player.beginLoopSelection(); player.tap(p.cues[1]); player.tap(p.cues[1]); player.pause() }
        player.clearLoop()
        for _ in 0..<80 where focus.isReviewingVoiceNote { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertFalse(player.playing); XCTAssertFalse(player.preparing); XCTAssertNil(player.loop)
        XCTAssertFalse(focus.isReviewingVoiceNote)
    }

    @MainActor
    func testScrubbingOwnsPositionAndResumesOnlyAfterRelease() async throws {
        let suite = UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let focus = FocusManager(historyDefaults: defaults, settingsDefaults: defaults)
        let voice = ScoreVoiceAudio(), player = ScoreAuditionPlayer()
        player.bind(focus: focus, voice: voice); player.load(package())
        player.play()
        for _ in 0..<50 where !player.playing { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(player.playing)
        player.beginScrubbing()
        let revision = player.seekRevision
        for i in 0..<30 { player.seek(Double(i % 6) * 0.1) }
        player.seek(0.3)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(player.scrubbing); XCTAssertFalse(player.playing); XCTAssertFalse(player.preparing)
        XCTAssertEqual(player.position, 0.3, accuracy: 0.000001)
        XCTAssertEqual(player.visualPosition, 0.3, accuracy: 0.000001)
        XCTAssertEqual(player.seekRevision, revision, "Dragging must not repeatedly navigate or restart audio")
        player.endScrubbing()
        for _ in 0..<50 where !player.playing { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(player.playing); XCTAssertEqual(player.seekRevision, revision + 1)
        XCTAssertGreaterThanOrEqual(player.visualPosition, 0.3)
        player.pause()
        player.beginScrubbing(); player.seek(0.5); player.endScrubbing()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(player.playing); XCTAssertEqual(player.visualPosition, 0.5, accuracy: 0.000001)
        player.play(); player.beginScrubbing(); player.seek(0.8); player.endScrubbing()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(player.playing); XCTAssertFalse(player.preparing)
        XCTAssertEqual(player.position, 0.8, accuracy: 0.000001, "Dragging to the end must not restart at zero")
        player.seek(0); player.play(); player.beginScrubbing(); player.seek(0.2)
        player.pause(); player.endScrubbing()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(player.playing, "Close/interruption during dragging must cancel auto-resume")
        XCTAssertFalse(focus.isReviewingVoiceNote)
    }

    @MainActor
    func testScrubbingOutsideLoopDoesNotUseTheOldClipOffset() async throws {
        let player = ScoreAuditionPlayer()
        var p = package()
        p.cues = [.init(time: 0.4, duration: 0.25, page: 1, staff: 1, measure: 2, x: 100, y: 500)]
        p.bars = [.init(measure: 1, start: 0, duration: 0.4), .init(measure: 2, start: 0.4, duration: 0.25)]
        player.load(p); player.beginLoopSelection(); player.tap(p.cues[0]); player.tap(p.cues[0])
        for _ in 0..<80 where !player.playing { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(player.playing)
        player.beginScrubbing(); player.seek(0.5); XCTAssertTrue(player.loopEnabled)
        player.seek(0.1); XCTAssertFalse(player.loopEnabled)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(player.visualPosition, 0.1, accuracy: 0.000001)
        player.endScrubbing()
        for _ in 0..<80 where !player.playing { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(player.playing); XCTAssertNil(player.error)
        XCTAssertLessThan(player.visualPosition, 0.4)
        player.pause()
    }

    @MainActor
    func testPreviewKeepsOriginalPDFAnnotationsAndReaderHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = ScoreLibraryDisk(root: root); _ = try await disk.load()
        let url = root.appendingPathComponent("Score.pdf")
        try UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 600, height: 800)).writePDF(to: url) { $0.beginPage() }
        let doc = try XCTUnwrap(PDFDocument(url: url))
        let annotation = PDFAnnotation(bounds: CGRect(x: 20, y: 500, width: 100, height: 40), forType: .freeText, withProperties: nil)
        annotation.contents = "Original"; doc.page(at: 0)?.addAnnotation(annotation)
        XCTAssertTrue(doc.write(to: url))
        let score = try await disk.importPDF(url), reader = ScoreReaderController()
        await reader.load(score: score, disk: disk)
        reader.editing = true; reader.tool = .select; reader.select("1:0"); reader.setSelectedText("Edited")
        let bytes = try Data(contentsOf: disk.pdfURL(score.id))
        let player = ScoreAuditionPlayer(); player.load(package()); player.seek(0.4); player.setRate(0.5); player.setClicks(true)
        player.beginLoopSelection(); player.tap(package().cues[0]); player.tap(package().cues[0]); player.pause(); player.clearLoop()
        XCTAssertTrue(reader.canUndo); reader.undo(); XCTAssertEqual(reader.selectedText, "Original")
        reader.redo(); XCTAssertEqual(reader.selectedText, "Edited")
        XCTAssertEqual(try Data(contentsOf: disk.pdfURL(score.id)), bytes)
        let flushed = await reader.flush(); XCTAssertTrue(flushed)
    }
    func testPageCacheRetainsPagesLoadsLegacyAndEvictsLeastRecentlyUsed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var one = package(), two = package(), three = package()
        one.title = "page 1"; two.title = "page 2"; three.title = "page 3"
        two.cues[0].page = 2; three.cues[0].page = 3
        let size = try JSONEncoder().encode(one).count
        try one.cache(directory: root, budget: size * 3)
        let oneURL = root.appendingPathComponent(digest + "-p1.json")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: oneURL.path)
        try two.cache(directory: root, budget: size * 3)
        XCTAssertEqual(ScoreAuditionPackage.cached(digest: digest, page: 2, pageCount: 3, directory: root)?.title, "page 2")
        try three.cache(directory: root, budget: size * 2 + 20)
        XCTAssertNil(ScoreAuditionPackage.cached(digest: digest, page: 1, pageCount: 3, directory: root))
        XCTAssertNotNil(ScoreAuditionPackage.cached(digest: digest, page: 2, pageCount: 3, directory: root))
        XCTAssertNotNil(ScoreAuditionPackage.cached(digest: digest, page: 3, pageCount: 3, directory: root))
        try JSONEncoder().encode(one).write(to: root.appendingPathComponent(digest + ".json"))
        XCTAssertEqual(ScoreAuditionPackage.cached(digest: digest, page: 1, pageCount: 3, directory: root)?.title, "page 1")
        XCTAssertThrowsError(try one.cache(directory: root, budget: size - 1))
        XCTAssertNil(ScoreAuditionPackage.cached(digest: digest, page: 4, pageCount: 4, directory: root))
        XCTAssertNil(ScoreAuditionPackage.cached(digest: digest, page: 1, pageCount: 3, directory: root, minimumRevision: 2, performsRepeats: true))
        one.recognitionRevision = 2; one.performsRepeats = true
        try one.cache(directory: root)
        XCTAssertNotNil(ScoreAuditionPackage.cached(digest: digest, page: 1, pageCount: 3, directory: root, minimumRevision: 2, performsRepeats: true))
        XCTAssertNil(ScoreAuditionPackage.cached(digest: digest, page: 1, pageCount: 3, directory: root, minimumRevision: 2, performsRepeats: false))
    }

    @MainActor
    func testPreparedPagesNeverReplaceActivePlaybackLoopOrScrub() async throws {
        let suite = UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let focus = FocusManager(historyDefaults: defaults, settingsDefaults: defaults)
        let history = defaults.data(forKey: "focusSessions")
        let player = ScoreAuditionPlayer(), voice = ScoreVoiceAudio()
        player.bind(focus: focus, voice: voice)
        var original = package(); original.title = "original"
        var prepared = original; prepared.title = "connected"
        prepared.cues[0].time = 0.1; prepared.cues[0].duration = 0.65
        player.load(original); player.seek(0.2); player.setRate(0.5); player.setClicks(true)
        player.offer(prepared, page: 1)
        XCTAssertEqual(player.position, 0.3, accuracy: 0.000001)
        XCTAssertEqual(player.rate, 0.5); XCTAssertTrue(player.clicks)
        player.load(original); player.seek(0); player.play()
        for _ in 0..<80 where !player.playing && player.error == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(player.playing); XCTAssertTrue(focus.isReviewingVoiceNote)
        let revision = player.packageRevision
        player.offer(prepared, page: 1)
        XCTAssertEqual(player.packageRevision, revision); XCTAssertEqual(player.package?.title, "original")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(player.playing); XCTAssertGreaterThan(player.visualPosition, 0)
        player.pause(); player.play()
        XCTAssertEqual(player.package?.title, "connected")
        player.pause()
        player.load(original); player.beginLoopSelection(); player.tap(original.cues[0]); player.tap(original.cues[0]); player.pause()
        let loop = player.loop
        player.offer(prepared, page: 1)
        XCTAssertEqual(player.loop, loop); XCTAssertEqual(player.package?.title, "original")
        player.clearLoop(); player.beginScrubbing(); player.seek(0.25)
        player.offer(prepared, page: 1)
        XCTAssertEqual(player.position, 0.25); XCTAssertEqual(player.package?.title, "original")
        player.endScrubbing(); player.play(); player.pause()
        XCTAssertEqual(player.package?.title, "connected")
        var other = prepared; other.sourceSHA256 = String(repeating: "b", count: 64); other.title = "wrong PDF"
        player.offer(other, page: 1); XCTAssertEqual(player.package?.title, "connected")
        player.unload()
        for _ in 0..<80 where focus.isReviewingVoiceNote { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(focus.isReviewingVoiceNote); XCTAssertNil(player.package)
        XCTAssertEqual(defaults.data(forKey: "focusSessions"), history)
    }

    func testSinglePageRefreshInvalidatesOnlyItsConnectedPreview() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var one = package(), two = package(), joined = package()
        one.notation = .init(pages: [1], configuration: "same", notes: [.init(midi: 60, beat: 0, duration: 1, staff: 1, measure: 1, point: .zero)],
                             bars: [.init(measure: 1, start: 0, duration: 0.75)], marks: [], beats: 1, consistentBars: true)
        two = one; two.cues[0].page = 2; two.notation?.pages = [2]; two.notation?.notes[0].page = 2
        joined.title = "connected"; joined.cues.append(.init(time: 0.4, duration: 0.3, page: 2, staff: 1, measure: 1, x: 80, y: 500))
        try one.cache(directory: root); try two.cache(directory: root); try joined.cache(directory: root)
        XCTAssertEqual(ScoreAuditionPackage.cached(digest: digest, page: 2, pageCount: 2, directory: root)?.title, "connected")
        XCTAssertEqual(ScoreAuditionPackage.cached(digest: digest, page: 2, pageCount: 2, directory: root, singlePage: true)?.cues.count, 1)
        try one.cache(directory: root)
        XCTAssertEqual(ScoreAuditionPackage.cached(digest: digest, page: 2, pageCount: 2, directory: root)?.cues.count, 1)
    }

    @MainActor
    func testPreparedPageChoiceHonorsLeadingRestWithoutChangingActiveLoop() {
        var p = package()
        p.cues = [.init(time: 0.1, duration: 0.2, page: 1, staff: 1, measure: 1, x: 100, y: 500),
                  .init(time: 0.5, duration: 0.2, page: 2, staff: 1, measure: 2, x: 100, y: 500)]
        p.bars = [.init(measure: 1, start: 0, duration: 0.4), .init(measure: 2, start: 0.4, duration: 0.35)]
        let player = ScoreAuditionPlayer(); player.load(p)
        player.followReaderPage(2)
        XCTAssertEqual(player.position, 0.4); XCTAssertEqual(p.followCue(at: player.position)?.page, 2)
        player.followReaderPage(1)
        XCTAssertEqual(player.position, 0); XCTAssertEqual(p.followCue(at: player.position)?.page, 1)
        player.beginLoopSelection(); player.followReaderPage(2)
        XCTAssertEqual(player.position, 0); XCTAssertTrue(player.selectingLoop)
    }

}
#endif
