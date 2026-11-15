import XCTest
import PencilKit
import PDFKit
@testable import MusicFocus

final class ScoreFingeringUndoBoundaryTests: XCTestCase {
    private static let convert: ScoreFingeringRecognition = { strokes, _ in
        let ring = strokes.first(where: ScoreFingeringBeautifier.isCircle)
        let digits = strokes.filter { $0.fingeringID != ring?.fingeringID }
        guard let drawing = ScoreFingeringBeautifier.render(digit: 1, from: digits, circle: ring) else { return [] }
        return [.init(sourceIDs: Set(strokes.map(\.fingeringID)), drawing: drawing, digit: 1, circled: ring != nil)]
    }

    @MainActor
    private final class Fixture {
        let device: ScoreSyncFixture.Device
        let reader: ScoreReaderController
        let view: ScorePDFViewport
        let canvas: ScoreCanvas
        let defaults: UserDefaults
        let suite = "FingeringUndoBoundary-" + UUID().uuidString

        init(recognition: @escaping ScoreFingeringRecognition) async throws {
            device = try await ScoreSyncFixture.Device(pdf: ScoreSyncFixture.pdf(pages: 1))
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            reader = ScoreReaderController(inkDefaults: defaults, fingeringRecognition: recognition)
            await reader.load(score: device.score, disk: device.disk)
            view = ScorePDFViewport(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
            reader.attach(view); reader.editing = true; reader.tool = .pen
            let page = try XCTUnwrap(reader.document?.page(at: 0))
            canvas = try XCTUnwrap(reader.pdfView(view, overlayViewFor: page) as? ScorePageOverlay).canvas
        }
        func write(_ strokes: [PKStroke]) {
            reader.canvasViewDidBeginUsingTool(canvas)
            canvas.drawing = PKDrawing(strokes: canvas.drawing.strokes + strokes)
            reader.canvasViewDrawingDidChange(canvas)
            reader.canvasViewDidEndUsingTool(canvas)
        }
        func converted() async throws {
            try await scoreSyncWait { self.reader.syncSnapshot().fingerings[1]?.isEmpty == false }
        }
        func close() {
            reader.detach(); defaults.removePersistentDomain(forName: suite); device.cleanUp()
        }
    }

    @MainActor
    func testUndoKeepsEarlierPenMonolineAndHighlighterNotes() async throws {
        let f = try await Fixture(recognition: Self.convert)
        defer { f.close() }
        let notes = [ScoreSyncFixture.stroke(300), ScoreSyncFixture.stroke(350), ScoreSyncFixture.stroke(400)]
        f.write([notes[0]])
        f.reader.tool = .monoline; f.write([notes[1]])
        f.reader.tool = .marker; f.write([notes[2]])
        f.reader.tool = .fingering; f.write(ScoreFingeringTests.digitInk(1))
        try await f.converted()
        let clean = f.canvas.drawing
        f.reader.undo()
        XCTAssertEqual(f.canvas.drawing.strokes.map(\.fingeringID), notes.map(\.fingeringID))
        // Older notes retain their own undo/redo boundaries.
        f.reader.undo()
        XCTAssertEqual(f.canvas.drawing.strokes.map(\.fingeringID), notes.dropLast().map(\.fingeringID))
        f.reader.redo(); f.reader.redo()
        XCTAssertEqual(f.canvas.drawing.strokes.map(\.fingeringID), clean.strokes.map(\.fingeringID))
        let saved = await f.reader.flush(); XCTAssertTrue(saved)
        let reopened = ScoreReaderController(inkDefaults: f.defaults)
        await reopened.load(score: f.device.score, disk: f.device.disk)
        let persisted = try PKDrawing(data: XCTUnwrap(reopened.syncSnapshot().drawings[1]))
        XCTAssertEqual(persisted.strokes.map(\.fingeringID), clean.strokes.map(\.fingeringID))
        let exportedURL = await f.reader.export()
        let exported = try XCTUnwrap(exportedURL)
        defer { try? FileManager.default.removeItem(at: exported.deletingLastPathComponent()) }
        let page = try XCTUnwrap(PDFDocument(url: exported)?.page(at: 0))
        XCTAssertEqual(page.annotations.count, clean.strokes.count)
        XCTAssertTrue(page.annotations.allSatisfy { $0.type == "Ink" && !($0.paths?.isEmpty ?? true) })
    }

    @MainActor
    func testUndoneBrushCannotReturnInLateCallbackOrNextPenStroke() async throws {
        for oldTool in [ScoreInkTool.pen, .monoline, .marker] {
            let f = try await Fixture(recognition: Self.convert)
            defer { f.close() }
            f.reader.tool = oldTool
            let a = ScoreSyncFixture.stroke(100), b = ScoreSyncFixture.stroke(200), c = ScoreSyncFixture.stroke(300)
            f.write([a]); f.write([b])
            let stale = f.canvas.drawing
            f.reader.undo()
            XCTAssertEqual(f.canvas.drawing.strokes.map(\.fingeringID), [a.fingeringID])
            // The old PencilKit renderer finishes after Undo has replaced its drawing.
            f.canvas.drawing = stale; f.reader.canvasViewDrawingDidChange(f.canvas)
            XCTAssertEqual(f.canvas.drawing.strokes.map(\.fingeringID), [a.fingeringID])
            f.reader.tool = .pen
            // A stale canvas buffer can also surface with the next fresh stroke.
            f.reader.canvasViewDidBeginUsingTool(f.canvas)
            f.canvas.drawing = PKDrawing(strokes: [a, b, c])
            f.reader.canvasViewDrawingDidChange(f.canvas); f.reader.canvasViewDidEndUsingTool(f.canvas)
            XCTAssertEqual(f.canvas.drawing.strokes.map(\.fingeringID), [a.fingeringID, c.fingeringID])
            XCTAssertFalse(f.reader.canRedo, "A new stroke replaces the undone branch")
            f.reader.undo(); XCTAssertEqual(f.canvas.drawing.strokes.map(\.fingeringID), [a.fingeringID])
            f.reader.redo(); XCTAssertEqual(f.canvas.drawing.strokes.map(\.fingeringID), [a.fingeringID, c.fingeringID])
            let saved = await f.reader.flush(); XCTAssertTrue(saved)
            let reloaded = ScoreReaderController()
            await reloaded.load(score: f.device.score, disk: f.device.disk)
            let persisted = try PKDrawing(data: XCTUnwrap(reloaded.syncSnapshot().drawings[1]))
            XCTAssertEqual(persisted.strokes.map(\.fingeringID), [a.fingeringID, c.fingeringID])
        }
    }

    @MainActor
    func testLateStrokeRefinementIsPartOfOneUndoStep() async throws {
        let f = try await Fixture(recognition: Self.convert)
        defer { f.close() }
        let a = ScoreSyncFixture.stroke(100), b = ScoreSyncFixture.stroke(200)
        f.write([a]); f.write([b])
        let refined = PKDrawing(strokes: [b]).transformed(using: CGAffineTransform(translationX: 0.2, y: 0.2))
        let final = PKDrawing(strokes: [a] + refined.strokes)
        f.canvas.drawing = final; f.reader.canvasViewDrawingDidChange(f.canvas)
        f.reader.undo()
        XCTAssertEqual(f.canvas.drawing.strokes.map(\.fingeringID), [a.fingeringID], "One tap removes the whole second stroke")
        f.reader.redo()
        // PencilKit may canonicalize its archive when a drawing is assigned;
        // verify the actual strokes and refinement, not archive byte encoding.
        XCTAssertEqual(f.canvas.drawing.strokes.map(\.fingeringID), final.strokes.map(\.fingeringID))
        for (actual, expected) in zip(f.canvas.drawing.strokes, final.strokes) {
            XCTAssertEqual(actual.transform.tx, expected.transform.tx, accuracy: 0.00001)
            XCTAssertEqual(actual.transform.ty, expected.transform.ty, accuracy: 0.00001)
        }
        XCTAssertEqual(f.canvas.drawing.strokes.map { $0.path.count }, final.strokes.map { $0.path.count })
    }

    @MainActor
    func testUndoBeforePenUpAndLateEndCannotBringBackInk() async throws {
        let f = try await Fixture(recognition: Self.convert)
        defer { f.close() }
        let a = ScoreSyncFixture.stroke(100), b = ScoreSyncFixture.stroke(200)
        f.write([a])
        f.reader.canvasViewDidBeginUsingTool(f.canvas)
        f.canvas.drawing = PKDrawing(strokes: [a,b]); f.reader.canvasViewDrawingDidChange(f.canvas)
        f.reader.undo()
        XCTAssertEqual(f.canvas.drawing.strokes.map(\.fingeringID), [a.fingeringID])
        f.reader.canvasViewDidEndUsingTool(f.canvas)
        f.canvas.drawing = PKDrawing(strokes: [a,b]); f.reader.canvasViewDrawingDidChange(f.canvas)
        XCTAssertEqual(f.canvas.drawing.strokes.map(\.fingeringID), [a.fingeringID])
        f.reader.undo(); XCTAssertTrue(f.canvas.drawing.strokes.isEmpty)
    }

    @MainActor
    func testUndoEraserRejectsItsLateEmptySnapshot() async throws {
        let f = try await Fixture(recognition: Self.convert)
        defer { f.close() }
        let a = ScoreSyncFixture.stroke(100)
        f.write([a]); f.reader.tool = .eraser
        f.reader.canvasViewDidBeginUsingTool(f.canvas); f.canvas.drawing = PKDrawing()
        f.reader.canvasViewDrawingDidChange(f.canvas); f.reader.canvasViewDidEndUsingTool(f.canvas)
        f.reader.undo()
        f.canvas.drawing = PKDrawing(); f.reader.canvasViewDrawingDidChange(f.canvas)
        XCTAssertEqual(f.canvas.drawing.strokes.map(\.fingeringID), [a.fingeringID])
        f.reader.redo(); XCTAssertTrue(f.canvas.drawing.strokes.isEmpty)
    }

    @MainActor
    func testEmptyTapDoesNotCreateUndoAndCanStillReceiveItsFinalInk() async throws {
        let f = try await Fixture(recognition: Self.convert)
        defer { f.close() }
        f.reader.canvasViewDidBeginUsingTool(f.canvas)
        f.reader.canvasViewDidEndUsingTool(f.canvas)
        XCTAssertFalse(f.reader.canUndo)
        let a = ScoreSyncFixture.stroke(100)
        f.canvas.drawing = PKDrawing(strokes: [a])
        f.reader.canvasViewDrawingDidChange(f.canvas)
        f.reader.undo(); XCTAssertTrue(f.canvas.drawing.strokes.isEmpty)
        XCTAssertFalse(f.reader.canUndo)
        f.reader.redo(); XCTAssertEqual(f.canvas.drawing.strokes.map(\.fingeringID), [a.fingeringID])
    }

    @MainActor
    func testFastNextStrokeConsumesInkDeliveredAfterPenUp() async throws {
        let f = try await Fixture(recognition: Self.convert)
        defer { f.close() }
        let a = ScoreSyncFixture.stroke(100), b = ScoreSyncFixture.stroke(200), c = ScoreSyncFixture.stroke(300)
        f.write([a])
        f.reader.canvasViewDidBeginUsingTool(f.canvas)
        f.reader.canvasViewDidEndUsingTool(f.canvas)
        // The renderer has the final second stroke, but its delegate notification
        // is still queued when the user starts the third stroke.
        f.canvas.drawing = PKDrawing(strokes: [a, b])
        f.write([c])
        XCTAssertEqual(f.canvas.drawing.strokes.map(\.fingeringID), [a.fingeringID, b.fingeringID, c.fingeringID])
        f.reader.undo()
        XCTAssertEqual(f.canvas.drawing.strokes.map(\.fingeringID), [a.fingeringID, b.fingeringID])
        f.reader.undo()
        XCTAssertEqual(f.canvas.drawing.strokes.map(\.fingeringID), [a.fingeringID])
    }

    @MainActor
    func testToolChangeAndFlushFinishPendingInputExactlyOnce() async throws {
        let f = try await Fixture(recognition: Self.convert)
        defer { f.close() }
        let a = ScoreSyncFixture.stroke(100), b = ScoreSyncFixture.stroke(200)
        f.reader.tool = .marker
        f.reader.canvasViewDidBeginUsingTool(f.canvas)
        f.canvas.drawing = PKDrawing(strokes: [a])
        f.reader.tool = .pen // No didChange/end yet; changing the tool commits A.
        f.reader.canvasViewDidEndUsingTool(f.canvas)
        f.reader.canvasViewDidBeginUsingTool(f.canvas)
        f.canvas.drawing = PKDrawing(strokes: [a,b])
        let saved = await f.reader.flush(); XCTAssertTrue(saved)
        let stored = try await f.device.disk.drawings(f.device.score.id)
        let persisted = try PKDrawing(data: XCTUnwrap(stored[1]))
        XCTAssertEqual(persisted.strokes.map(\.fingeringID), [a.fingeringID, b.fingeringID])
        f.reader.undo(); XCTAssertEqual(f.canvas.drawing.strokes.map(\.fingeringID), [a.fingeringID])
        f.reader.undo(); XCTAssertTrue(f.canvas.drawing.strokes.isEmpty)
        XCTAssertFalse(f.reader.canUndo)
    }

    @MainActor
    func testFinalPathRefinementCanChangeLegacyContentIdentity() async throws {
        let f = try await Fixture(recognition: Self.convert)
        defer { f.close() }
        let a = ScoreSyncFixture.stroke(100), b = ScoreSyncFixture.stroke(200)
        f.write([a]); f.write([b])
        let points = b.path.map { point in
            PKStrokePoint(location: CGPoint(x: point.location.x + 0.25, y: point.location.y),
                          timeOffset: point.timeOffset, size: point.size, opacity: point.opacity,
                          force: point.force, azimuth: point.azimuth, altitude: point.altitude)
        }
        let refined = PKStroke(ink: b.ink, path: PKStrokePath(controlPoints: points, creationDate: b.path.creationDate))
        f.canvas.drawing = PKDrawing(strokes: [a,refined])
        f.reader.canvasViewDrawingDidChange(f.canvas)
        XCTAssertEqual(f.canvas.drawing.strokes.last?.fingeringID, refined.fingeringID)
        f.reader.undo(); XCTAssertEqual(f.canvas.drawing.strokes.map(\.fingeringID), [a.fingeringID])
        f.reader.redo(); XCTAssertEqual(f.canvas.drawing.strokes.last?.fingeringID, refined.fingeringID)
    }

    @MainActor
    func testMultiStrokeCircledDigitStillUndoesInOneStep() async throws {
        let f = try await Fixture(recognition: Self.convert)
        defer { f.close() }
        let note = ScoreSyncFixture.stroke(350)
        f.write([note]); f.reader.tool = .fingering
        let strokes = ScoreFingeringTests.digitInk(4)
        for stroke in strokes { f.write([stroke]) }
        f.write([ScoreFingeringTests.circle(around: PKDrawing(strokes: strokes).bounds)])
        try await f.converted()
        XCTAssertEqual(f.reader.syncSnapshot().fingerings[1]?.first?.circled, true)
        let cleanIDs = f.canvas.drawing.strokes.map(\.fingeringID)
        f.reader.undo()
        XCTAssertEqual(f.canvas.drawing.strokes.map(\.fingeringID), [note.fingeringID])
        f.reader.redo()
        XCTAssertEqual(f.canvas.drawing.strokes.map(\.fingeringID), cleanIDs)
        let saved = await f.reader.flush(); XCTAssertTrue(saved)
    }

    @MainActor
    func testEarlierUnconvertedFingeringInputRemainsAnIndependentStep() async throws {
        let f = try await Fixture(recognition: { strokes, _ in
            let selected = strokes.filter { $0.renderBounds.minX > 300 }
            guard let drawing = ScoreFingeringBeautifier.render(digit: 1, from: selected) else { return [] }
            return [.init(sourceIDs: Set(selected.map(\.fingeringID)), drawing: drawing, digit: 1, circled: false)]
        })
        defer { f.close() }
        f.reader.tool = .fingering
        let other = ScoreFingeringTests.stroke([(0, 0), (50, 30), (0, 60)])
        f.write([other])
        f.write([ScoreFingeringTests.stroke([(0, 0), (0, 70)], origin: CGPoint(x: 400, y: 100))])
        try await f.converted()
        f.reader.undo()
        XCTAssertEqual(f.canvas.drawing.strokes.map(\.fingeringID), [other.fingeringID])
        f.reader.undo(); XCTAssertTrue(f.canvas.drawing.strokes.isEmpty)
        let saved = await f.reader.flush(); XCTAssertTrue(saved)
    }

    @MainActor
    func testLateFinalDrawingCallbackDoesNotExposeOrDeleteEarlierNotes() async throws {
        let f = try await Fixture(recognition: Self.convert)
        defer { f.close() }
        let note = ScoreSyncFixture.stroke(350)
        f.write([note]); f.reader.tool = .fingering
        let raw = ScoreFingeringTests.digitInk(1)
        f.write(raw)
        // PencilKit refines the same stroke IDs after didEndUsingTool.
        let final = PKDrawing(strokes: raw).transformed(using: CGAffineTransform(translationX: 0.2, y: 0.2))
        XCTAssertEqual(final.strokes.map(\.fingeringID), raw.map(\.fingeringID))
        f.canvas.drawing = PKDrawing(strokes: [note] + final.strokes)
        f.reader.canvasViewDrawingDidChange(f.canvas)
        try await f.converted()
        f.reader.undo()
        XCTAssertEqual(f.canvas.drawing.strokes.map(\.fingeringID), [note.fingeringID])
        let saved = await f.reader.flush(); XCTAssertTrue(saved)
    }
    @MainActor
    func testReusedOverlayUndoThenWriteDoesNotResurrectCircledDigit() async throws {
        let f = try await Fixture(recognition: Self.convert)
        defer { f.close() }
        let note = ScoreSyncFixture.stroke(350)
        f.write([note]); f.reader.tool = .fingering
        let raw = ScoreFingeringTests.digitInk(4)
        f.write(raw + [ScoreFingeringTests.circle(around: PKDrawing(strokes: raw).bounds)])
        try await f.converted()
        let oldIDs = Set(f.canvas.drawing.strokes.map(\.fingeringID)).subtracting([note.fingeringID])
        let page = try XCTUnwrap(f.reader.document?.page(at: 0))
        let overlay = try XCTUnwrap(f.canvas.superview as? ScorePageOverlay)
        // PDFKit can reuse the same overlay after a page leaves and re-enters
        // the viewport, including while zooming or changing the fitted layout.
        f.reader.pdfView(f.view, willEndDisplayingOverlayView: overlay, for: page)
        f.reader.pdfView(f.view, willDisplayOverlayView: overlay, for: page)
        f.reader.undo()
        XCTAssertEqual(f.canvas.drawing.strokes.map(\.fingeringID), [note.fingeringID])
        let fresh = PKDrawing(strokes: ScoreFingeringTests.digitInk(2)).transformed(using: CGAffineTransform(translationX: 200, y: 0)).strokes
        f.write(fresh)
        XCTAssertTrue(oldIDs.isDisjoint(with: f.canvas.drawing.strokes.map(\.fingeringID)), "The next stroke must not re-submit undone ink")
        let saved = await f.reader.flush(); XCTAssertTrue(saved)
        let persisted = try PKDrawing(data: XCTUnwrap(f.reader.syncSnapshot().drawings[1]))
        XCTAssertTrue(oldIDs.isDisjoint(with: persisted.strokes.map(\.fingeringID)))
        f.reader.undo()
        XCTAssertEqual(f.canvas.drawing.strokes.map(\.fingeringID), [note.fingeringID])
    }

    @MainActor
    func testOffscreenUndoAndLateEndCallbackCannotLeaveAStaleReplacementOverlay() async throws {
        let f = try await Fixture(recognition: Self.convert)
        defer { f.close() }
        let note = ScoreSyncFixture.stroke(350)
        f.write([note]); f.reader.tool = .fingering
        f.write(ScoreFingeringTests.digitInk(4)); try await f.converted()
        let page = try XCTUnwrap(f.reader.document?.page(at: 0))
        let first = try XCTUnwrap(f.canvas.superview as? ScorePageOverlay)
        f.reader.pdfView(f.view, willEndDisplayingOverlayView: first, for: page)
        f.reader.undo()
        f.reader.pdfView(f.view, willDisplayOverlayView: first, for: page)
        XCTAssertEqual(first.canvas.drawing.strokes.map(\.fingeringID), [note.fingeringID])
        f.reader.redo()
        f.reader.pdfView(f.view, willEndDisplayingOverlayView: first, for: page)
        let replacement = try XCTUnwrap(f.reader.pdfView(f.view, overlayViewFor: page) as? ScorePageOverlay)
        f.reader.pdfView(f.view, willDisplayOverlayView: replacement, for: page)
        f.reader.pdfView(f.view, willEndDisplayingOverlayView: first, for: page)
        f.reader.undo()
        XCTAssertEqual(replacement.canvas.drawing.strokes.map(\.fingeringID), [note.fingeringID])
        let saved = await f.reader.flush(); XCTAssertTrue(saved)
    }

}
