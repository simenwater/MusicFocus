#if DEBUG && MUSICFOCUS_HOMR
import XCTest
import PDFKit
import AVFoundation
import Network
@testable import MusicFocus

final class ScoreRecognitionTests: XCTestCase {
    func testPolyphonyRestsDottedTupletsAndPitch() throws {
        let symbols: [ScoreRecognitionSymbol] = [
            .init(rhythm: "note_8", pitch: "D5"), .init(rhythm: "chord"),
            .init(rhythm: "note_4", pitch: "D3", position: "lower"),
            .init(rhythm: "note_16", pitch: "C5"), .init(rhythm: "note_16", pitch: "B4", lift: "b"),
            .init(rhythm: "rest_4", position: "upper"), .init(rhythm: "chord"),
            .init(rhythm: "note_4", pitch: "E3", position: "lower"), .init(rhythm: "barline"),
            .init(rhythm: "note_4.", pitch: "C4", lift: "#")
        ]
        let result = try ScoreRecognitionTimeline.convert(symbols)
        XCTAssertEqual(result.notes.map(\.midi), [74, 50, 72, 70, 52, 61])
        XCTAssertEqual(result.notes.map(\.beat), [0, 0, 0.5, 0.75, 1, 2])
        XCTAssertEqual(result.duration, 3.5, accuracy: 0.001)
        XCTAssertEqual(ScoreRecognitionSymbol(rhythm: "note_12").duration, 1.0/3, accuracy: 0.00001)
        XCTAssertEqual(ScoreRecognitionSymbol(rhythm: "note_4..").duration, 1.75)
    }
    func testRasterExcludesPDFAnnotationsAndMapsCoordinates() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 600, height: 800)).writePDF(to: url) { context in
            context.beginPage(); UIColor.black.setFill(); context.cgContext.fill(CGRect(x: 40, y: 50, width: 100, height: 60))
        }
        let before = try ScoreRecognitionRaster.read(url, page: 1)
        let doc = PDFDocument(url: url)!
        let ink = PDFAnnotation(bounds: CGRect(x: 300, y: 300, width: 150, height: 150), forType: .square, withProperties: nil)
        ink.interiorColor = .red; doc.page(at: 0)!.addAnnotation(ink); XCTAssertTrue(doc.write(to: url))
        let after = try ScoreRecognitionRaster.read(url, page: 1)
        XCTAssertEqual(before.pixels, after.pixels, "PDF annotation appearance must not enter OMR")
        let point = CGPoint(x: 60 * 3.2, y: 70 * 3.2)
        XCTAssertLessThan(after.sample(x: point.x, y: point.y), 10)
        let pdf = point.applying(after.pixelToPDF)
        XCTAssertEqual(pdf.x, 60, accuracy: 0.01); XCTAssertEqual(pdf.y, 730, accuracy: 0.01)
    }
    func testColorSuppressionOnlyChangesRecognitionCopyAndKeepsBlackNotation() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 600, height: 800)).writePDF(to: url) { context in
            context.beginPage()
            UIColor.black.setFill(); context.cgContext.fill(CGRect(x: 40, y: 50, width: 80, height: 80))
            UIColor.blue.setFill(); context.cgContext.fill(CGRect(x: 240, y: 50, width: 80, height: 80))
            UIColor.red.setFill(); context.cgContext.fill(CGRect(x: 440, y: 50, width: 80, height: 80))
        }
        let bytes = try Data(contentsOf: url)
        let original = try ScoreRecognitionRaster.read(url, page: 1)
        let filtered = try ScoreRecognitionRaster.read(url, page: 1, ignoreColoredMarks: true)
        XCTAssertLessThan(filtered.sample(x: 80 * 3.2, y: 90 * 3.2), 10)
        for x in [280.0, 480.0] {
            XCTAssertLessThan(original.sample(x: x * 3.2, y: 90 * 3.2), 230)
            XCTAssertGreaterThan(filtered.sample(x: x * 3.2, y: 90 * 3.2), 245)
        }
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertEqual(filtered.pixelToPDF, original.pixelToPDF)
    }

    func testRotatedCroppedPageRasterMatchesPDFCoordinates() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 600, height: 800)).writePDF(to: url) { context in
            context.beginPage(); UIColor.black.setFill()
            context.cgContext.fill(CGRect(x: 140, y: 150, width: 40, height: 40))
        }
        let doc = PDFDocument(url: url)!, page = doc.page(at: 0)!
        page.setBounds(CGRect(x: 50, y: 100, width: 500, height: 650), for: .cropBox)
        for rotation in [0, 90, 180, 270] {
            page.rotation = rotation; XCTAssertTrue(doc.write(to: url))
            let raster = try ScoreRecognitionRaster.read(url, page: 1)
            let expectedPDFPoint = CGPoint(x: 160, y: 630)
            let pixel = expectedPDFPoint.applying(raster.pixelToPDF.inverted())
            XCTAssertLessThan(raster.sample(x: pixel.x, y: pixel.y), 10, "Rotation \(rotation)")
        }
    }
    struct DiagnosticRow: Codable { var page: Int; var row: Int; var part: Int; var symbols: [ScoreRecognitionSymbol]; var opticalRhythmCorrections: Int? = nil }
    struct RhythmCheck: Codable { var measure: Int; var staff: Int; var onsets: [Double]; var durations: [Double]; var grouped: Bool? = nil }
    struct AbsentPitch: Codable { var measure: Int; var staff: Int; var midi: Int }
    struct PitchCheck: Codable { var measure: Int; var staff: Int; var chords: [[Int]] }
    struct Sample: Codable {
        var title: String; var path: String?; var scoreID: String?; var pages: [Int]; var layout: Int
        var expectFailure: Bool?; var ignoreColoredMarks: Bool?
        var expectedBarBeats: [Double]?; var rhythmChecks: [RhythmCheck]?; var absentPitches: [AbsentPitch]?
        var expectInconsistentBars: Bool? = nil
        var pitchChecks: [PitchCheck]? = nil
    }
    @MainActor
    private func verifyRealPlayback(_ package: ScoreAuditionPackage, check: RhythmCheck) async throws {
        let suite = UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let focus = FocusManager(historyDefaults: defaults, settingsDefaults: defaults)
        let history = defaults.data(forKey: "focusSessions")
        let voice = ScoreVoiceAudio(), player = ScoreAuditionPlayer()
        player.bind(focus: focus, voice: voice); player.load(package)
        let cues = package.cues.filter { $0.measure == check.measure && $0.staff == check.staff }
        let first = try XCTUnwrap(cues.first), tapped = cues[cues.count / 2]
        player.tap(tapped)
        for _ in 0..<100 where !player.playing && player.error == nil { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertNil(player.error); XCTAssertTrue(player.playing); XCTAssertTrue(focus.isReviewingVoiceNote)
        XCTAssertEqual(player.position, tapped.time, accuracy: 0.3, "Tap must start at the selected note")
        player.pause()
        player.beginLoopSelection(); player.tap(first); player.tap(first)
        for _ in 0..<100 where !player.playing && player.error == nil { try await Task.sleep(for: .milliseconds(25)) }
        let loop = try XCTUnwrap(player.loop)
        XCTAssertTrue(player.loopEnabled); XCTAssertNil(player.error)
        var previous = player.visualPosition, wraps = 0
        for _ in 0..<Int(ceil((loop.duration + 0.3) / 0.05)) {
            try await Task.sleep(for: .milliseconds(50))
            let time = player.visualPosition
            XCTAssertTrue(player.playing); XCTAssertGreaterThanOrEqual(time, loop.start)
            XCTAssertLessThan(time, loop.end)
            if time < previous - 0.1 { wraps += 1 }; previous = time
        }
        XCTAssertGreaterThanOrEqual(wraps, 1, "Real recognized audio must wrap inside the selected bar")
        player.pause()
        for _ in 0..<100 where focus.isReviewingVoiceNote { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertFalse(player.playing); XCTAssertFalse(focus.isReviewingVoiceNote)
        XCTAssertEqual(defaults.data(forKey: "focusSessions"), history)
    }
    func testRealLibraryPages() async throws {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let manifest = ProcessInfo.processInfo.environment["SCORE_RECOGNITION_MANIFEST"].map { URL(fileURLWithPath: $0) } ?? documents.appendingPathComponent(ProcessInfo.processInfo.environment["SCORE_RECOGNITION_MANIFEST_NAME"] ?? "native-recognition-fixtures.json")
        guard FileManager.default.fileExists(atPath: manifest.path) else { throw XCTSkip("Real-score manifest not supplied") }
        await MainActor.run { UIApplication.shared.isIdleTimerDisabled = true }
        if ProcessInfo.processInfo.environment["SCORE_REQUIRE_OFFLINE"] == "1" {
            let monitor = NWPathMonitor(), checked = expectation(description: "Physical device has no network route")
            monitor.pathUpdateHandler = { path in
                print("OFFLINE PATH", path.status, "interfaces", path.availableInterfaces.map(\.name))
                XCTAssertEqual(path.status, .unsatisfied, "Offline recognition must be tested with networking actually disconnected")
                monitor.pathUpdateHandler = nil; monitor.cancel(); checked.fulfill()
            }
            monitor.start(queue: DispatchQueue(label: "MusicFocus.offline-test"))
            await fulfillment(of: [checked], timeout: 10)
        }
        let samples = try JSONDecoder().decode([Sample].self, from: Data(contentsOf: manifest))
        let reportRoot = documents.appendingPathComponent("NativeRecognitionValidation")
        try FileManager.default.createDirectory(at: reportRoot, withIntermediateDirectories: true)
        var reports: [[String: Any]] = []
        for (index, sample) in samples.enumerated() {
            let source: URL
            if let path = sample.path { source = URL(fileURLWithPath: path) }
            else { source = ScoreLibraryDisk(root: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ScoreLibrary")).pdfURL(UUID(uuidString: sample.scoreID!)!) }
            let hash = try ScoreLibraryDisk.sha256(of: source), started = Date()
            do {
                let package = try await ScoreRecognizer.shared.recognize(.init(url: source, digest: hash, title: sample.title, pages: sample.pages, layout: ScoreRecognitionLayout(rawValue: sample.layout)!, ignoreColoredMarks: sample.ignoreColoredMarks ?? false), diagnostics: reportRoot.appendingPathComponent("notes-\(index).json")) { _, _ in }
                XCTAssertNotEqual(sample.expectFailure, true)
                XCTAssertGreaterThan(package.cues.count, 4)
                if sample.expectInconsistentBars == true {
                    XCTAssertEqual(package.notation?.consistentBars,false)
                    XCTAssertNil(package.bars, "Unaligned parts must not expose invented loop bounds")
                    let cue = try XCTUnwrap(package.cues.first)
                    XCTAssertNil(package.loop(from:cue,through:cue))
                }
                XCTAssertEqual(try ScoreLibraryDisk.sha256(of: source), hash)
                let batches = try JSONDecoder().decode([DiagnosticRow].self, from: Data(contentsOf: reportRoot.appendingPathComponent("notes-\(index).json.symbols.json")))
                var plainRows: [String: Double] = [:]
                var rhythmCorrections = 0
                for batch in batches {
                    let plain = try ScoreRecognitionTimeline.convert(batch.symbols, options: .init(enabled: false))
                    rhythmCorrections += plain.correctedRhythms + (batch.opticalRhythmCorrections ?? 0)
                    let key = "\(batch.page):\(batch.row)"
                    plainRows[key] = max(plainRows[key] ?? 0, plain.duration)
                }
                XCTAssertEqual(package.duration, plainRows.values.reduce(0,+) * 0.75 + 0.45, accuracy: 0.001,
                               "Ornaments must not stretch bars or shift the accompaniment/metronome")
                let performed = try JSONDecoder().decode([ScoreRecognizedNote].self, from: Data(contentsOf: reportRoot.appendingPathComponent("notes-\(index).json")))
                for check in sample.pitchChecks ?? [] {
                    let notes=performed.filter{$0.measure==check.measure && $0.staff==check.staff && $0.decoration==nil}
                    let chords=Dictionary(grouping:notes,by:\.beat).sorted{$0.key<$1.key}.map{$0.value.map(\.midi).sorted()}
                    XCTAssertEqual(chords,check.chords,"\(sample.title), bar \(check.measure): inline clef pitches")
                }
                if let expected = sample.expectedBarBeats {
                    let bars = try XCTUnwrap(package.bars, sample.title)
                    XCTAssertEqual(bars.count, expected.count, sample.title)
                    for (bar, beats) in zip(bars, expected) { XCTAssertEqual(bar.duration / 0.75, beats, accuracy: 0.000001, "\(sample.title), bar \(bar.measure)") }
                }
                for absent in sample.absentPitches ?? [] {
                    XCTAssertFalse(performed.contains { $0.measure == absent.measure && $0.staff == absent.staff && $0.midi == absent.midi }, "A graphical meter must not sound as an extra high note")
                }
                for check in sample.rhythmChecks ?? [] {
                    let bar = try XCTUnwrap(package.bars?.first { $0.measure == check.measure })
                    let notes = performed.filter { $0.measure == check.measure && $0.staff == check.staff && $0.decoration == nil }.sorted { $0.beat < $1.beat }
                    let checked = check.grouped == true
                        ? Dictionary(grouping: notes, by: \.beat).values.compactMap { $0.min { $0.duration < $1.duration } }.sorted { $0.beat < $1.beat }
                        : notes
                    XCTAssertEqual(checked.count, check.onsets.count, "\(sample.title), bar \(check.measure)")
                    XCTAssertEqual(checked.count, check.durations.count, sample.title)
                    for (note, expected) in zip(checked, check.onsets) { XCTAssertEqual(note.beat - bar.start / 0.75, expected, accuracy: 0.000001, "\(sample.title), bar \(check.measure)") }
                    for (note, expected) in zip(checked, check.durations) { XCTAssertEqual(note.duration, expected, accuracy: 0.000001, "\(sample.title), bar \(check.measure)") }
                }
                for bar in package.bars ?? [] {
                    guard let cue = package.cues.first(where: { $0.measure == bar.measure }) else { continue }
                    let loop = try XCTUnwrap(package.loop(from: cue, through: cue))
                    XCTAssertEqual(loop.start, bar.start, accuracy: 0.000001)
                    XCTAssertEqual(loop.end, bar.end, accuracy: 0.000001)
                    if let next = package.cues.first(where: { $0.measure == bar.measure + 1 }) {
                        XCTAssertEqual(package.loop(from: cue, through: next), package.loop(from: next, through: cue))
                    }
                }
                let grace = batches.flatMap(\.symbols).filter(\.isGrace).count
                let marked = batches.flatMap(\.symbols).filter { $0.duration > 0 && $0.midi != nil && ScoreRecognitionOrnaments.ornament($0) != nil }.count
                let performedDecorations = Dictionary(grouping: performed.filter { $0.decoration != nil }, by: { $0.decoration! }).mapValues(\.count)
                // Inspect decoded PCM without opening the hardware audio session.
                let audioURL = reportRoot.appendingPathComponent("audio-check.m4a")
                for data in [package.audio, package.audioWithClicks!] {
                    try data.write(to: audioURL)
                    let audio = try AVAudioFile(forReading: audioURL)
                    XCTAssertEqual(Double(audio.length) / audio.processingFormat.sampleRate, package.duration, accuracy: 0.2)
                }
                try FileManager.default.removeItem(at: audioURL)
                let pageBounds = PDFDocument(url: source)!
                XCTAssertTrue(package.cues.allSatisfy { pageBounds.page(at: $0.page - 1)!.bounds(for: .cropBox).contains(CGPoint(x: $0.x, y: $0.y)) })
                try JSONEncoder().encode(package).write(to: reportRoot.appendingPathComponent("sample-\(index).json"))
                let recognitionSeconds = Date().timeIntervalSince(started)
                if let check = sample.rhythmChecks?.first { try await verifyRealPlayback(package, check: check) }
                reports.append(["title": sample.title, "pages": sample.pages, "seconds": recognitionSeconds, "notes": package.cues.count, "duration": package.duration, "success": true, "recognizedGraceNotes": grace, "recognizedOrnamentMarks": marked, "performedDecorationNotes": performedDecorations, "correctedRhythms": rhythmCorrections, "checkedRhythmBars": sample.rhythmChecks?.count ?? 0, "checkedRealPlayback": sample.rhythmChecks?.isEmpty == false])
            } catch {
                reports.append(["title": sample.title, "seconds": Date().timeIntervalSince(started), "error": error.localizedDescription, "expectedFailure": sample.expectFailure ?? false])
                if sample.expectFailure != true { XCTFail("\(sample.title): \(error)") }
            }
            try JSONSerialization.data(withJSONObject: reports, options: [.prettyPrinted, .sortedKeys]).write(to: reportRoot.appendingPathComponent("report.json"), options: .atomic)
        }
    }
    func testRealPageCacheComposition() async throws {
        await MainActor.run { UIApplication.shared.isIdleTimerDisabled = true }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let manifest = docs.appendingPathComponent("cross-page-baseline.json")
        guard FileManager.default.fileExists(atPath: manifest.path) else { throw XCTSkip("Supply real library pages") }
        let samples = try JSONDecoder().decode([Sample].self, from: Data(contentsOf: manifest))
        let disk = ScoreLibraryDisk(root: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ScoreLibrary"))
        let root = docs.appendingPathComponent("NativeRecognitionValidation")
        var report: [[String: Any]] = []
        for (index,sample) in samples.enumerated() {
            let url = disk.pdfURL(UUID(uuidString: sample.scoreID!)!), hash = try ScoreLibraryDisk.sha256(of: url)
            var result: ScoreAuditionPackage?
            for page in sample.pages {
                result = try await ScoreRecognizer.shared.recognize(.init(url: url, digest: hash, title: sample.title, pages: [page],
                    layout: ScoreRecognitionLayout(rawValue: sample.layout)!, repeats: true, connectCachedPages: true)) { _,_ in }
                XCTAssertEqual(try ScoreLibraryDisk.sha256(of: url), hash)
            }
            let package = try XCTUnwrap(result), notation = try XCTUnwrap(package.notation)
            XCTAssertEqual(notation.pages, sample.pages)
            let plan = ScoreRecognitionRepeats.plan(count: notation.bars.count, marks: notation.marks, startsAtBeginning: notation.pages.first == 1)
            let expected = plan.order.reduce(0.0) { $0 + notation.bars[$1 - 1].duration } + 0.45
            XCTAssertEqual(package.duration, expected, accuracy: 0.0001)
            XCTAssertTrue(package.performsRepeats == true)
            if index == 0 {
                XCTAssertEqual(plan.order, Array(1...16) + Array(1...12) + Array(17...36)); XCTAssertFalse(plan.omitted)
            }
            if index == 1 {
                let merged = ScoreRecognitionTies.merge(notation.notes)
                XCTAssertNotNil(merged.first { $0.midi == 91 && $0.beat < 42 && $0.beat + $0.duration > 42 })
            }
            try JSONEncoder().encode(package).write(to: root.appendingPathComponent("connected-\(index).json"), options: .atomic)
            report.append(["title":sample.title,"pages":notation.pages,"duration":package.duration,"cues":package.cues.count,"repeatOrder":plan.order,"incompleteRepeats":plan.omitted])
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys]).write(to: root.appendingPathComponent("connected-report.json"), options: .atomic)
        }
    }

}
#endif
