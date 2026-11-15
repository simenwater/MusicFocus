import XCTest
import PDFKit
import PencilKit
@testable import MusicFocus

final class ScorePageCoverTests: XCTestCase {
    func testLegacyDataValidationAndSyncKeepCovers() throws {
        let old = Data(#"{"version":1,"items":{}}"#.utf8)
        XCTAssertTrue(try JSONDecoder().decode(ScoreAnnotationEdits.self,from: old).covers.isEmpty)
        var edits = ScoreAnnotationEdits()
        edits.covers = [.init(page: 1,bounds: CGRect(x: 20,y: 30,width: 40,height: 25))]
        XCTAssertEqual(try JSONDecoder().decode(ScoreAnnotationEdits.self,from: JSONEncoder().encode(edits)),edits)
        var snapshot = ScoreAnnotationSnapshot(); snapshot.edits = edits
        XCTAssertEqual(try snapshot.validated(pageCount: 1),snapshot)
        XCTAssertEqual(snapshot.summary.pdfEdits,1)
        XCTAssertEqual(ScoreAnnotationSnapshot().merging(snapshot,scope: .edits).edits,edits)
        var bad = snapshot; bad.edits.covers[0].page = 2
        XCTAssertThrowsError(try bad.validated(pageCount: 1))
        bad = snapshot; bad.edits.covers.append(bad.edits.covers[0])
        XCTAssertThrowsError(try bad.validated(pageCount: 1))
        bad = snapshot; bad.edits.covers[0].bounds.size.width = -10
        XCTAssertThrowsError(try bad.validated(pageCount: 1))
        let bounded = edits.covers[0].constrained(to: CGRect(x: 0,y: 0,width: 30,height: 40))
        XCTAssertTrue(CGRect(x: 0,y: 0,width: 30,height: 40).contains(bounded.bounds))
    }

    @MainActor
    func testIndependentCoverHistoryDoesNotResurrectUndoneInkAndReloads() async throws {
        let device = try await ScoreSyncFixture.Device(pdf: ScoreSyncFixture.pdf(pages: 1))
        defer { device.cleanUp() }
        let reader = ScoreReaderController()
        await reader.load(score: device.score,disk: device.disk)
        let view = ScorePDFViewport(frame: CGRect(x: 0,y: 0,width: 600,height: 800))
        reader.attach(view); reader.editing = true; reader.tool = .pen
        defer { reader.detach() }
        let page = try XCTUnwrap(reader.document?.page(at: 0))
        let canvas = try XCTUnwrap(reader.pdfView(view,overlayViewFor: page) as? ScorePageOverlay).canvas
        let ink = PKDrawing(strokes: ScoreFingeringTests.digitInk(4))
        reader.canvasViewDidBeginUsingTool(canvas); canvas.drawing = ink
        reader.canvasViewDrawingDidChange(canvas); reader.canvasViewDidEndUsingTool(canvas)
        let originalInk = canvas.drawing
        var cover = ScorePageCover(page: 1,bounds: CGRect(x: 100,y: 100,width: 60,height: 30))
        reader.tool = .cover; reader.saveCover(cover)
        let created = reader.syncSnapshot()
        cover.bounds.origin.x += 45; cover.bounds.size.width += 20; reader.saveCover(cover)
        reader.selectCover(cover.id); reader.chooseCoverColor(.systemYellow)
        XCTAssertEqual(reader.selectedCover?.color,ScoreAnnotationColor(.systemYellow))
        reader.undo(); XCTAssertEqual(reader.annotationEdits.covers.first?.color,ScoreAnnotationColor(.white))
        reader.undo(); XCTAssertEqual(reader.syncSnapshot(),created)
        reader.undo(); XCTAssertTrue(reader.annotationEdits.covers.isEmpty)
        XCTAssertTrue(canvas.drawing.hasSameVisibleInk(as: originalInk))
        reader.undo(); XCTAssertTrue(canvas.drawing.strokes.isEmpty)
        // Editing a new cover after undo clears redo, never writes an old canvas
        // buffer back over the user's history.
        reader.saveCover(cover); reader.tool = .monoline
        reader.canvasViewDrawingDidChange(canvas)
        XCTAssertTrue(canvas.drawing.strokes.isEmpty); XCTAssertFalse(reader.canRedo)
        reader.tool = .cover; reader.selectCover(cover.id); reader.deleteSelectedCover()
        XCTAssertTrue(reader.annotationEdits.covers.isEmpty)
        reader.undo(); XCTAssertEqual(reader.annotationEdits.covers,[cover])
        let flushed = await reader.flush(); XCTAssertTrue(flushed)
        let reopened = ScoreReaderController(); await reopened.load(score: device.score,disk: device.disk)
        XCTAssertEqual(reopened.annotationEdits.covers,[cover])
        XCTAssertTrue(reopened.syncSnapshot().drawings.values.allSatisfy { (try? PKDrawing(data: $0).strokes.isEmpty) == true })
    }

    @MainActor
    func testFingeringAndIndependentCoversSurviveBackupAndExportTogether() async throws {
        let device = try await ScoreSyncFixture.Device(pdf: ScoreSyncFixture.pdf(pages: 1))
        defer { device.cleanUp() }
        let raw = ScoreFingeringTests.digitInk(4)
        let glyph = try XCTUnwrap(ScoreFingeringBeautifier.render(digit: 4,from: raw))
        let converted = ScoreFingeringCover().applying(to: .init(sourceIDs: [],drawing: glyph,digit: 4,circled: false))
        let mark = ScoreFingeringMark(drawing: converted.drawing,digit: 4,circled: false,cover: converted.cover)
        let cover = ScorePageCover(page: 1,bounds: CGRect(x: 200,y: 300,width: 45,height: 20))
        let snapshot = ScoreAnnotationSnapshot(drawings: [1: converted.drawing.dataRepresentation()],
            edits: .init(covers: [cover]),fingerings: [1: [mark]])
        try await device.write(snapshot)
        var manifest = try await device.disk.load()
        manifest.scores = [device.score]
        let backup = try await device.disk.exportBackup(manifest)
        defer { try? FileManager.default.removeItem(at: backup.deletingLastPathComponent()) }
        let restored = try await device.disk.restoreBackupCopies(backup)
        let copy = try XCTUnwrap(restored.scores.first)
        XCTAssertNotEqual(copy.id,device.score.id)
        let recovered = try await device.disk.annotationSnapshot(copy.id)
        XCTAssertEqual(recovered,snapshot)
        let reader = ScoreReaderController(); await reader.load(score: copy,disk: device.disk)
        reader.tool = .cover; reader.selectCover(cover.id); reader.deleteSelectedCover()
        XCTAssertEqual(reader.syncSnapshot().drawings,snapshot.drawings)
        XCTAssertEqual(reader.syncSnapshot().fingerings,snapshot.fingerings)
        reader.undo(); XCTAssertEqual(reader.syncSnapshot(),snapshot)
        let exported = await reader.export()
        let url = try XCTUnwrap(exported)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let annotations = try XCTUnwrap(PDFDocument(url: url)?.page(at: 0)).annotations
        XCTAssertEqual(annotations.filter { $0.type == "Square" }.count,1)
        XCTAssertEqual(annotations.filter { $0.type == "Ink" }.count,converted.drawing.strokes.count)
        let envelope = ScoreSyncEnvelope(app: "test",identity: .init(digest: "test",pageCount: 1,title: "score"),message: .liveFull(snapshot))
        let data = try ScoreSyncCodec.encode(envelope)
        XCTAssertEqual(try ScoreSyncCodec.decode(data),envelope)
        XCTAssertGreaterThan(envelope.schema,1,"Older clients must prompt for an update rather than silently drop rectangles")
    }

    @MainActor
    func testPreviewCancelExportAndOriginalContentRecovery() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Original markings.pdf")
        try UIGraphicsPDFRenderer(bounds: CGRect(x: 0,y: 0,width: 300,height: 240)).writePDF(to: source) { ctx in
            ctx.beginPage(); UIColor.white.setFill(); ctx.cgContext.fill(CGRect(x: 0,y: 0,width: 300,height: 240))
            UIColor.black.setFill(); ctx.cgContext.fill(CGRect(x: 90,y: 100,width: 40,height: 20))
            ("Printed score — reversible cover" as NSString).draw(at: CGPoint(x: 20,y: 20),withAttributes: [.font: UIFont.systemFont(ofSize: 12)])
        }
        let original = try Data(contentsOf: source)
        let document = try XCTUnwrap(PDFDocument(data: original)), page = try XCTUnwrap(document.page(at: 0))
        let catalog = ScorePDFAnnotations(document: document)
        let cover = ScorePageCover(page: 1,bounds: CGRect(x: 80,y: 110,width: 60,height: 40))
        var edits = ScoreAnnotationEdits(); edits.covers = [cover]
        catalog.apply(edits)
        var moved = cover; moved.bounds.origin.x += 80
        catalog.applyCovers([moved]); XCTAssertEqual(catalog.edits,edits)
        catalog.applyCovers(edits.covers); XCTAssertEqual(catalog.coverAnnotations[cover.id]?.bounds,cover.bounds)
        XCTAssertEqual(page.annotations.count,1)
        let url = try ScorePDFExport.editable(source: source,drawings: [:],edits: edits,title: "Original markings")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let exported = try XCTUnwrap(PDFDocument(url: url)?.page(at: 0))
        XCTAssertEqual(exported.annotations.count,1)
        let annotation = try XCTUnwrap(exported.annotations.first)
        XCTAssertEqual(annotation.type,"Square"); XCTAssertEqual(annotation.bounds,cover.bounds)
        XCTAssertEqual(ScoreAnnotationColor(try XCTUnwrap(annotation.interiorColor)),ScoreAnnotationColor(.white))
        XCTAssertEqual(annotation.border?.lineWidth,0)
        let format = UIGraphicsImageRendererFormat(); format.scale = 3
        func render(_ page: PDFPage) -> UIImage {
            UIGraphicsImageRenderer(size: CGSize(width: 300,height: 240),format: format).image { ctx in
                UIColor.white.setFill(); ctx.fill(CGRect(x: 0,y: 0,width: 300,height: 240))
                ctx.cgContext.translateBy(x: 0,y: 240); ctx.cgContext.scaleBy(x: 1,y: -1)
                page.draw(with: .cropBox,to: ctx.cgContext)
            }
        }
        let covered = render(exported)
        let flattened = try ScorePDFExport.create(source: url,drawings: [:],title: "Flattened markings")
        defer { try? FileManager.default.removeItem(at: flattened.deletingLastPathComponent()) }
        XCTAssertTrue(try XCTUnwrap(PDFDocument(url: flattened)?.page(at: 0)).annotations.isEmpty)
        exported.removeAnnotation(annotation)
        let restored = render(exported), pristine = render(try XCTUnwrap(PDFDocument(data: original)?.page(at: 0)))
        XCTAssertEqual(restored.pngData(),pristine.pngData()); XCTAssertNotEqual(covered.pngData(),pristine.pngData())
        XCTAssertEqual(try Data(contentsOf: source),original)
        for (name,image) in [("Standalone mask export",covered),("Original after removing mask",restored)] {
            let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        }
        let proof = XCTAttachment(data: try Data(contentsOf: url),uniformTypeIdentifier: "com.adobe.pdf")
        proof.name = "Editable standalone mask proof"; proof.lifetime = .keepAlways; add(proof)
    }
}
