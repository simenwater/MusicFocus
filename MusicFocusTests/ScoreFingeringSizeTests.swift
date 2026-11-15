import XCTest
import PencilKit
import PDFKit
@testable import MusicFocus

final class ScoreFingeringSizeTests: XCTestCase {
    private func replacement(height: CGFloat, x: CGFloat = 100, circled: Bool = false,
                             font: ScoreFingeringFont = .handwritten) throws -> ScoreFingeringReplacement {
        let raw = PKDrawing(strokes: ScoreFingeringTests.digitInk(4, color: .systemPurple))
        let scaled = raw.transformed(using: CGAffineTransform(scaleX: height / raw.bounds.height, y: height / raw.bounds.height))
        let positioned = scaled.transformed(using: CGAffineTransform(translationX: x - scaled.bounds.midX, y: 200 - scaled.bounds.midY))
        let ring = circled ? ScoreFingeringTests.circle(around: positioned.bounds, color: .systemRed) : nil
        let drawing = try XCTUnwrap(ScoreFingeringBeautifier.render(digit: 4, from: positioned.strokes, circle: ring, font: font))
        return .init(sourceIDs: Set(positioned.strokes.map(\.fingeringID)), drawing: drawing, digit: 4, circled: circled, font: font)
    }

    func testDifferentHandwrittenSizesKeepOneHeightWithoutStretchingOrMoving() throws {
        for font in ScoreFingeringFont.allCases {
            let originals = try [CGFloat(19), 8, 50, 4, 30].enumerated().map { index, height in
                try replacement(height: height, x: 100 + CGFloat(index) * 100, circled: index % 2 == 1, font: font)
            }
            let results = ScoreFingeringSizing.apply(originals, height: nil)
            let anchor = ScoreFingeringSizing.digitBounds(originals[0]).height
            for (before, after) in zip(originals, results) {
                let a = ScoreFingeringSizing.digitBounds(before), b = ScoreFingeringSizing.digitBounds(after)
                XCTAssertEqual(b.height, anchor, accuracy: 0.01)
                XCTAssertEqual(a.width / a.height, b.width / b.height, accuracy: 0.001)
                // Page render bounds round to points; the uniform transform itself
                // fixes the original whole-mark center exactly.
                XCTAssertEqual(after.drawing.bounds.midX, before.drawing.bounds.midX, accuracy: 0.6)
                XCTAssertEqual(after.drawing.bounds.midY, before.drawing.bounds.midY, accuracy: 0.6)
                XCTAssertEqual(after.drawing.strokes.map { $0.ink.color }, before.drawing.strokes.map { $0.ink.color })
                if before.circled {
                    let transform = try XCTUnwrap(after.drawing.strokes.last?.transform)
                    XCTAssertEqual(transform.a, transform.d, accuracy: 0.00001)
                }
            }
        }
    }

    func testLateCircleAndInvalidStoredSizesDoNotResizeAnExistingDigit() throws {
        var old = try replacement(height: 30, circled: true)
        old.preservesDigitSize = true
        let fresh = try replacement(height: 8)
        let result = ScoreFingeringSizing.apply([old, fresh], height: nil)
        XCTAssertEqual(result[0].drawing, old.drawing)
        XCTAssertEqual(result[1].drawing, fresh.drawing, "A late circle must not capture the size for future new digits")
        for invalid in [Double.nan, .infinity, 0, -1, 100_000] {
            XCTAssertEqual(ScoreFingeringSizing.apply([fresh], height: invalid)[0].drawing, fresh.drawing)
        }
    }

    @MainActor
    func testSizeModeMigrationAndExplicitDefault() throws {
        let name = "FingeringModes-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(ScoreFingeringSizing.mode(in: defaults), .first)
        defaults.set(false, forKey: ScoreFingeringSizing.enabledKey)
        XCTAssertEqual(ScoreFingeringSizing.mode(in: defaults), .handwritten)
        defaults.set(true, forKey: ScoreFingeringSizing.enabledKey)
        let reader = ScoreReaderController(inkDefaults: defaults)
        XCTAssertEqual(reader.fingeringSizeMode, .first)
        XCTAssertEqual(reader.fixedFingeringHeight, 12)
        reader.setFingeringSizeMode(.fixed)
        reader.setFixedFingeringHeight(18)
        let reopened = ScoreReaderController(inkDefaults: defaults)
        XCTAssertEqual(reopened.fingeringSizeMode, .fixed)
        XCTAssertEqual(reopened.fixedFingeringHeight, 18)
        reopened.setFixedFingeringHeight(.nan)
        XCTAssertEqual(reopened.fixedFingeringHeight, 18)
        reopened.setFixedFingeringHeight(100)
        XCTAssertEqual(reopened.fixedFingeringHeight, 48)
        for font in ScoreFingeringFont.allCases {
            let inputs = try [CGFloat(4), 19, 50].map { try replacement(height: $0, circled: true, font: font) }
            let outputs = ScoreFingeringSizing.apply(inputs, height: 18)
            for output in outputs {
                let digit = ScoreFingeringSizing.digitBounds(output)
                let ring = ScoreFingeringSizing.inkBounds([try XCTUnwrap(output.drawing.strokes.last)])
                XCTAssertEqual(digit.height, 18, accuracy: 0.01)
                XCTAssertLessThan(ring.height, digit.height * 1.6)
                XCTAssertGreaterThan(ring.height, digit.height)
                XCTAssertEqual(ring.midX, digit.midX, accuracy: 0.05)
                XCTAssertEqual(ring.midY, digit.midY, accuracy: 0.05)
            }
        }
    }

    @MainActor
    func testSizeIsPerScorePersistsAndResetDoesNotRewriteOldNotes() async throws {
        let device = try await ScoreSyncFixture.Device(pdf: ScoreSyncFixture.pdf(pages: 1))
        defer { device.cleanUp() }
        let suite = "FixedFingering-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let recognition: ScoreFingeringRecognition = { strokes, fresh in
            let raw = strokes.filter { fresh.contains($0.fingeringID) }
            let ring = raw.first(where: ScoreFingeringBeautifier.isCircle)
            let digits = raw.filter { $0.fingeringID != ring?.fingeringID }
            guard let drawing = ScoreFingeringBeautifier.render(digit: 4, from: digits, circle: ring) else { return [] }
            return [.init(sourceIDs: Set(raw.map(\.fingeringID)), drawing: drawing, digit: 4, circled: ring != nil)]
        }
        let reader = ScoreReaderController(inkDefaults: defaults, fingeringRecognition: recognition)
        await reader.load(score: device.score, disk: device.disk)
        let view = ScorePDFViewport(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
        reader.attach(view); reader.editing = true; reader.tool = .fingering
        defer { reader.detach() }
        let page = try XCTUnwrap(reader.document?.page(at: 0))
        let canvas = try XCTUnwrap(reader.pdfView(view, overlayViewFor: page) as? ScorePageOverlay).canvas
        func write(height: CGFloat, x: CGFloat, circled: Bool = false) async throws {
            let raw = PKDrawing(strokes: ScoreFingeringTests.digitInk(4, color: .systemBlue))
            let small = raw.transformed(using: CGAffineTransform(scaleX: height / raw.bounds.height, y: height / raw.bounds.height))
            let positioned = small.transformed(using: CGAffineTransform(translationX: x - small.bounds.midX, y: 300 - small.bounds.midY))
            let strokes = positioned.strokes + (circled ? [ScoreFingeringTests.circle(around: positioned.bounds, color: .systemRed)] : [])
            let count = reader.syncSnapshot().fingerings[1]?.count ?? 0
            reader.canvasViewDidBeginUsingTool(canvas)
            canvas.drawing = PKDrawing(strokes: canvas.drawing.strokes + strokes)
            reader.canvasViewDrawingDidChange(canvas); reader.canvasViewDidEndUsingTool(canvas)
            try await scoreSyncWait { (reader.syncSnapshot().fingerings[1]?.count ?? 0) > count }
        }
        XCTAssertEqual(reader.fingeringSizeMode, .first)
        XCTAssertNil(reader.fingeringHeight)
        try await write(height: 19, x: 100)
        let anchor = try XCTUnwrap(reader.fingeringHeight)
        try await write(height: 8, x: 220)
        try await write(height: 45, x: 350, circled: true)
        let marks = try XCTUnwrap(reader.syncSnapshot().fingerings[1])
        for mark in marks {
            let drawing = PKDrawing(strokes: try XCTUnwrap(mark.strokes(in: canvas.drawing)))
            let replacement = ScoreFingeringReplacement(sourceIDs: [], drawing: drawing, digit: mark.digit, circled: mark.circled)
            XCTAssertEqual(ScoreFingeringSizing.digitBounds(replacement).height, anchor, accuracy: 0.6)
        }
        let clean = canvas.drawing
        reader.undo(); XCTAssertEqual(canvas.drawing.strokes.count, clean.strokes.count - (try XCTUnwrap(marks.last?.strokeIDs.count)))
        reader.redo(); XCTAssertEqual(canvas.drawing.strokes.map(\.fingeringID), clean.strokes.map(\.fingeringID))
        let oldIDs = canvas.drawing.strokes.map(\.fingeringID)
        reader.resetFingeringSize()
        XCTAssertNil(reader.fingeringHeight)
        XCTAssertEqual(canvas.drawing.strokes.map(\.fingeringID), oldIDs)
        try await write(height: 35, x: 470)
        let newSize = try XCTUnwrap(reader.fingeringHeight)
        XCTAssertGreaterThan(newSize, anchor * 1.5)
        XCTAssertEqual(Array(canvas.drawing.strokes.prefix(oldIDs.count)).map(\.fingeringID), oldIDs)
        reader.setFingeringSizeMode(.handwritten)
        try await write(height: 7, x: 540)
        XCTAssertEqual(reader.fingeringHeight, newSize)
        let last = try XCTUnwrap(reader.syncSnapshot().fingerings[1]?.last)
        let lastInk = PKDrawing(strokes: try XCTUnwrap(last.strokes(in: canvas.drawing)))
        XCTAssertLessThan(lastInk.bounds.height, newSize / 2)
        reader.setFingeringSizeMode(.fixed)
        reader.setFixedFingeringHeight(12)
        try await write(height: 40, x: 300, circled: true)
        let fixed = try XCTUnwrap(reader.syncSnapshot().fingerings[1]?.last)
        let fixedInk = PKDrawing(strokes: try XCTUnwrap(fixed.strokes(in: canvas.drawing)))
        XCTAssertEqual(ScoreFingeringSizing.inkBounds(Array(fixedInk.strokes.dropLast())).height, 12, accuracy: 0.1)
        XCTAssertEqual(reader.fingeringHeight, newSize, "Explicit default must not replace the learned per-score size")
        reader.setFingeringSizeMode(.first)
        let saved = await reader.flush(); XCTAssertTrue(saved)
        let reopened = ScoreReaderController(inkDefaults: defaults)
        await reopened.load(score: device.score, disk: device.disk)
        XCTAssertEqual(reopened.fingeringHeight, newSize)
        XCTAssertEqual(reopened.fingeringSizeMode, .first)
        XCTAssertEqual(reopened.syncSnapshot().drawings, reader.syncSnapshot().drawings)
        let another = try await ScoreSyncFixture.Device(pdf: ScoreSyncFixture.pdf(pages: 1))
        defer { another.cleanUp() }
        let otherReader = ScoreReaderController(inkDefaults: defaults)
        await otherReader.load(score: another.score, disk: another.disk)
        XCTAssertNil(otherReader.fingeringHeight)
        let exportURL = await reader.export()
        let output = try XCTUnwrap(exportURL)
        defer { try? FileManager.default.removeItem(at: output.deletingLastPathComponent()) }
        let exported = try XCTUnwrap(PDFDocument(url: output)?.page(at: 0))
        XCTAssertEqual(exported.annotations.count, canvas.drawing.strokes.count)
        XCTAssertTrue(exported.annotations.allSatisfy { $0.type == "Ink" && !($0.paths?.isEmpty ?? true) })
    }
}
