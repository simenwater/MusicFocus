import XCTest
import PDFKit
import PencilKit
@testable import MusicFocus

final class ScoreAnnotationTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("AnnotationTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @MainActor
    private func fixture(_ root: URL, rotated: Bool = false) throws -> URL {
        let url = root.appendingPathComponent("Annotations.pdf")
        try UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 600, height: 800)).writePDF(to: url) { ctx in
            ctx.beginPage()
            ("Printed music must survive erasing" as NSString).draw(at: CGPoint(x: 40, y: 40), withAttributes: [.font: UIFont.systemFont(ofSize: 16)])
        }
        let doc = try XCTUnwrap(PDFDocument(url: url)), page = try XCTUnwrap(doc.page(at: 0))
        // Establish geometry before adding ink. Rewriting a populated fixture
        // through PDFKit 26 can itself alter annotation metadata before export.
        if rotated {
            page.setBounds(CGRect(x: 20, y: 30, width: 560, height: 740), for: .cropBox)
            page.rotation = 90
        }
        let ink = ScoreVariableInkAnnotation.make(bounds: CGRect(x: 100, y: 500, width: 110, height: 60), opacity: 0.4)
        for y: CGFloat in [10, 40] {
            let path = UIBezierPath(); path.move(to: CGPoint(x: 5, y: y)); path.addLine(to: CGPoint(x: 100, y: y)); ink.add(path)
        }
        ink.color = UIColor.red.withAlphaComponent(0.4)
        let border = PDFBorder(); border.lineWidth = 4; ink.border = border
        ink.setValue([[2, 8], [8, 2]], forAnnotationKey: PDFAnnotationKey(rawValue: "/ReaddleWidthList"))
        ink.setValue("original-ink", forAnnotationKey: PDFAnnotationKey(rawValue: "/NM"))
        page.addAnnotation(ink)
        let note = PDFAnnotation(bounds: CGRect(x: 300, y: 500, width: 200, height: 40), forType: .freeText, withProperties: nil)
        note.contents = "Practice slowly"; note.font = .systemFont(ofSize: 16); note.fontColor = .blue
        page.addAnnotation(note)
        let link = PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 20, height: 20), forType: .link, withProperties: nil)
        link.url = URL(string: "https://example.com"); page.addAnnotation(link)
        let locked = PDFAnnotation(bounds: CGRect(x: 20, y: 200, width: 50, height: 50), forType: .text, withProperties: nil)
        locked.contents = "Locked"; locked.setValue(128, forAnnotationKey: PDFAnnotationKey(rawValue: "/F")); page.addAnnotation(locked)
        try ScorePDFExport.writeEditable(doc, to: url, changedAnnotations: [ink])
        return url
    }

    private func drawing(transform: CGAffineTransform = .identity, mask: UIBezierPath? = nil) -> PKDrawing {
        let points = [CGPoint(x: 60, y: 120), CGPoint(x: 180, y: 120)].enumerated().map { i, p in
            PKStrokePoint(location: p, timeOffset: Double(i) * 0.1, size: CGSize(width: 5 + i * 3, height: 5 + i * 3), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .red), path: PKStrokePath(controlPoints: points, creationDate: Date()), transform: transform, mask: mask)])
    }

    /// A standard ink appearance with a different BBox aspect ratio from its annotation Rect,
    /// matching the structure written by PDF Reader Pro after an ink delete/undo round trip.
    private func nonuniformAppearancePDF() -> Data {
        let appearance = "q 1 0 0 RG 10 w 110 110 m 290 110 l S Q\n"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 400] /Resources << >> /Contents 4 0 R /Annots [5 0 R] >>",
            "<< /Length 0 >>\nstream\n\nendstream",
            "<< /Type /Annot /Subtype /Ink /Rect [100 100 300 120] /F 4 /C [1 0 0] /BS << /W 10 >> /InkList [[110 110 290 110]] /AP << /N 6 0 R >> >>",
            "<< /Type /XObject /Subtype /Form /BBox [90 80 310 140] /Resources << >> /Length \(appearance.utf8.count) >>\nstream\n\(appearance)endstream"
        ]
        var pdf = "%PDF-1.7\n", offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(pdf.utf8.count); pdf += "\(index + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xref = pdf.utf8.count
        pdf += "xref\n0 \(offsets.count)\n0000000000 65535 f \n"
        for offset in offsets.dropFirst() { pdf += String(format: "%010d 00000 n \n", offset) }
        pdf += "trailer\n<< /Size \(offsets.count) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return Data(pdf.utf8)
    }

    @MainActor
    private func redInkWidth(_ page: PDFPage) throws -> Int {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 400), format: format).image { renderer in
            UIColor.white.setFill(); renderer.fill(CGRect(x: 0, y: 0, width: 400, height: 400))
            renderer.cgContext.translateBy(x: 0, y: 400); renderer.cgContext.scaleBy(x: 1, y: -1)
            page.draw(with: .mediaBox, to: renderer.cgContext)
            // On iPadOS 27 the reader's sharp ink overlay owns these appearances.
            for annotation in page.annotations.compactMap({ $0 as? ScoreOverlayInkAnnotation }) where annotation.shouldDisplay {
                annotation.rendered.draw(with: .mediaBox, in: renderer.cgContext)
            }
        }
        var pixels = [UInt8](repeating: 0, count: 400 * 400 * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: 400, height: 400, bitsPerComponent: 8,
            bytesPerRow: 400 * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(try XCTUnwrap(image.cgImage), in: CGRect(x: 0, y: 0, width: 400, height: 400))
        var xs: [Int] = []
        for y in 0..<400 { for x in 0..<400 {
            let i = (y * 400 + x) * 4
            if pixels[i] > 180 && pixels[i+1] < 80 && pixels[i+2] < 80 { xs.append(x) }
        } }
        return (xs.max() ?? 0) - (xs.min() ?? 0)
    }

    @MainActor
    func testExternalInkAppearanceDoesNotShrinkAndUndoKeepsCorrectDisplay() throws {
        let data = nonuniformAppearancePDF()
        let document = try XCTUnwrap(PDFDocument(data: data)), page = try XCTUnwrap(document.page(at: 0))
        let original = try XCTUnwrap(page.annotations.first)
        let catalog = ScorePDFAnnotations(document: document, correctAppearanceForDisplay: true)
        XCTAssertFalse(catalog.live["1:0"] === original)
        // Standard PDF appearance mapping: a 180-point path scales by Rect.width / BBox.width.
        XCTAssertEqual(try redInkWidth(page), Int(180.0 * 200.0 / 220.0), accuracy: 3)
        XCTAssertNotNil(catalog.hit(pageNumber: 1, point: CGPoint(x: 150, y: 110), tolerance: 1))
        var edits = ScoreAnnotationEdits(); edits.items["1:0"] = .init(deleted: true)
        catalog.apply(edits); XCTAssertEqual(try redInkWidth(page), 0)
        catalog.apply(.init())
        XCTAssertEqual(try redInkWidth(page), Int(180.0 * 200.0 / 220.0), accuracy: 3)
        XCTAssertTrue(catalog.live["1:0"] === catalog.entry("1:0")?.displayedOriginal)
        // The export catalog must keep the original stream, so the workaround cannot alter
        // the interoperable file or accumulate another correction on subsequent round trips.
        let exportDocument = try XCTUnwrap(PDFDocument(data: data))
        let exportOriginal = try XCTUnwrap(exportDocument.page(at: 0)?.annotations.first)
        let exportCatalog = ScorePDFAnnotations(document: exportDocument)
        XCTAssertTrue(exportCatalog.live["1:0"] === exportOriginal)
    }

    @MainActor
    func testImportedInkBypassesPencilKitLassoWhileBlankPaperStillAcceptsNewInk() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let disk = ScoreLibraryDisk(root: root.appendingPathComponent("Library")); _ = try await disk.load()
        let score = try await disk.importPDF(fixture(root))
        let reader = ScoreReaderController(); await reader.load(score: score, disk: disk)
        let view = PDFView(frame: CGRect(x: 0, y: 0, width: 600, height: 800)); reader.attach(view)
        defer { reader.detach() }
        view.layoutDocumentView()
        reader.editing = true; reader.tool = .select
        let page = try XCTUnwrap(reader.document?.page(at: 0))
        let overlay = try XCTUnwrap(reader.pdfView(view, overlayViewFor: page) as? ScorePageOverlay)
        let hit = overlay.convert(view.convert(CGPoint(x: 150, y: 510), from: page), from: view)
        let blank = overlay.convert(view.convert(CGPoint(x: 250, y: 100), from: page), from: view)
        XCTAssertEqual(overlay.routesToPDFAnnotation?(hit), true)
        XCTAssertNil(overlay.hitTest(hit, with: nil), "Imported ink must not enter the competing PencilKit lasso")
        XCTAssertEqual(overlay.routesToPDFAnnotation?(blank), false)
        reader.tool = .pen
        XCTAssertEqual(overlay.routesToPDFAnnotation?(hit), false, "Writing over an old annotation remains possible")
        reader.editing = false
        XCTAssertEqual(overlay.routesToPDFAnnotation?(hit), false)
    }

    @MainActor
    func testTransparentInkRemainsTransparentAfterExportAndReimport() throws {
        let root = try directory()
        let source = try fixture(root), doc = try XCTUnwrap(PDFDocument(url: source)), page = try XCTUnwrap(doc.page(at: 0))
        let ink = ScoreVariableInkAnnotation.make(bounds: CGRect(x: 10, y: 10, width: 100, height: 20), opacity: 0.25)
        ink.color = UIColor.yellow.withAlphaComponent(0.25)
        let path = UIBezierPath(); path.move(to: CGPoint(x: 1,y: 1)); path.addLine(to: CGPoint(x: 95,y: 1)); ink.add(path)
        page.addAnnotation(ink)
        try ScorePDFExport.writeEditable(doc, to: source, changedAnnotations: [ink])
        let result = try XCTUnwrap(PDFDocument(url: source))
        let resultPage = try XCTUnwrap(result.page(at: 0))
        let reloaded = try XCTUnwrap(resultPage.annotations.last)
        XCTAssertEqual(ScorePDFAnnotations.opacity(reloaded), 0.25, accuracy: 0.01)
        withExtendedLifetime(result) { }
        let target = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Opacity Validation.pdf")
        try Data(contentsOf: source).write(to: target)
    }

    @MainActor
    func testHitEraseOnePathAndRestoreOriginalAppearance() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let doc = try XCTUnwrap(PDFDocument(url: fixture(root)))
        let catalog = ScorePDFAnnotations(document: doc)
        XCTAssertEqual(catalog.entries.count, 2, "Links and locked annotations are not editable")
        let original = try XCTUnwrap(catalog.live["1:0"])
        XCTAssertEqual(catalog.hit(pageNumber: 1, point: CGPoint(x: 150, y: 510), tolerance: 1)?.path, 0)
        XCTAssertNil(catalog.hit(pageNumber: 1, point: CGPoint(x: 150, y: 525), tolerance: 1))
        var edits = ScoreAnnotationEdits(); edits.items["1:0"] = .init(removedPaths: [0])
        catalog.apply(edits)
        XCTAssertEqual(catalog.live["1:0"]?.paths?.count, 1)
        XCTAssertNil(catalog.hit(pageNumber: 1, point: CGPoint(x: 150, y: 510), tolerance: 1))
        XCTAssertEqual(catalog.hit(pageNumber: 1, point: CGPoint(x: 150, y: 540), tolerance: 1)?.path, 1)
        catalog.apply(.init())
        XCTAssertTrue(catalog.live["1:0"] === original, "Undo restores the original PDF appearance object")
    }

    @MainActor
    func testMoveColorEraseTextAndMixedUndoPersistWithoutChangingSource() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(root), original = try Data(contentsOf: source)
        let disk = ScoreLibraryDisk(root: root.appendingPathComponent("Library")); _ = try await disk.load()
        let score = try await disk.importPDF(source)
        let reader = ScoreReaderController(); await reader.load(score: score, disk: disk)
        let view = PDFView(frame: CGRect(x: 0, y: 0, width: 600, height: 800)); reader.attach(view)
        defer { reader.detach() }
        reader.editing = true; reader.tool = .select; reader.select("1:0"); reader.chooseColor(1)
        reader.editAnnotation("1:0") { $0.offset = CGPoint(x: 20, y: -30); $0.removedPaths = [0] }
        reader.select("1:1"); reader.setSelectedText("Count carefully")
        let page = try XCTUnwrap(reader.document?.page(at: 0))
        let overlay = try XCTUnwrap(reader.pdfView(view, overlayViewFor: page) as? ScorePageOverlay)
        reader.canvasViewDidBeginUsingTool(overlay.canvas)
        overlay.canvas.drawing = drawing()
        reader.canvasViewDrawingDidChange(overlay.canvas)
        reader.canvasViewDidEndUsingTool(overlay.canvas)
        XCTAssertTrue(reader.canUndo)
        reader.undo(); XCTAssertTrue(overlay.canvas.drawing.strokes.isEmpty)
        reader.undo(); XCTAssertEqual(reader.selectedText, "Practice slowly")
        reader.redo(); XCTAssertEqual(reader.selectedText, "Count carefully")
        reader.redo(); XCTAssertEqual(overlay.canvas.drawing.strokes.count, 1)
        let ok = await reader.flush(); XCTAssertTrue(ok)
        let reopened = ScoreReaderController(); await reopened.load(score: score, disk: disk)
        XCTAssertEqual(reopened.annotationEdits, reader.annotationEdits)
        XCTAssertEqual(reopened.annotations?.live["1:0"]?.bounds.origin, CGPoint(x: 120, y: 470))
        XCTAssertEqual(reopened.annotations?.live["1:0"]?.paths?.count, 1)
        XCTAssertEqual(reopened.annotations?.live["1:1"]?.contents, "Count carefully")
        let export = await reopened.export(); let output = try XCTUnwrap(export)
        let result = try XCTUnwrap(PDFDocument(url: output)?.page(at: 0))
        XCTAssertEqual(result.annotations.filter { $0.type == "Ink" }.count, 2)
        XCTAssertTrue(result.annotations.contains { $0.contents == "Count carefully" })
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try Data(contentsOf: disk.pdfURL(score.id)), original)
    }

    @MainActor
    func testEditableExportKeepsInkListOpacityAndPageGeometry() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(root, rotated: true), doc = try XCTUnwrap(PDFDocument(url: source)), page = try XCTUnwrap(doc.page(at: 0))
        let exported = try ScorePDFExport.editable(source: source, drawings: [1: drawing().dataRepresentation()])
        let result = try XCTUnwrap(PDFDocument(url: exported)?.page(at: 0))
        XCTAssertEqual(result.rotation, 90); XCTAssertEqual(result.bounds(for: .cropBox), page.bounds(for: .cropBox))
        XCTAssertEqual(result.annotations.count, page.annotations.count + 1, "One new ink annotation; preserve any OS-created popup")
        let ink = try XCTUnwrap(result.annotations.last)
        XCTAssertEqual(ink.type, "Ink"); XCTAssertNotNil(ink.paths?.first)
        XCTAssertTrue(ink.hasAppearanceStream)
        let path = try XCTUnwrap(ink.paths?.first)
        XCTAssertEqual(path.bounds.minX + ink.bounds.minX, 80, accuracy: 1)
        XCTAssertEqual(path.bounds.minY + ink.bounds.minY, 650, accuracy: 1)
        XCTAssertFalse(ScorePDFAnnotations.widths(ink).isEmpty)
        let originalInk = try XCTUnwrap(result.annotations.first)
        XCTAssertEqual(ScorePDFAnnotations.opacity(originalInk), 0.4, accuracy: 0.01)
        XCTAssertEqual(result.annotations[2].url, URL(string: "https://example.com"))
    }

    @MainActor
    func testMaskedPencilStrokeOnlyExportsSurvivingRanges() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(root), page = try XCTUnwrap(PDFDocument(url: source)?.page(at: 0))
        let mask = UIBezierPath(rect: CGRect(x: 50, y: 100, width: 50, height: 40))
        let stroke = drawing(mask: mask).strokes[0]
        let annotations = ScorePDFExport.inkAnnotations(stroke, on: page)
        XCTAssertFalse(annotations.isEmpty)
        for ink in annotations {
            XCTAssertLessThanOrEqual(ink.bounds.maxX, 110, "Erased portions must not reappear in exported InkList")
        }
    }

    @MainActor
    func testBadSidecarDoesNotSilentlyRestoreDeletedNotes() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let disk = ScoreLibraryDisk(root: root.appendingPathComponent("Library")); _ = try await disk.load()
        let score = try await disk.importPDF(fixture(root))
        let url = disk.folder(score.id).appendingPathComponent("annotation-edits.json")
        try Data("broken".utf8).write(to: url)
        let reader = ScoreReaderController(); await reader.load(score: score, disk: disk)
        XCTAssertFalse(reader.ready); XCTAssertNotNil(reader.errorMessage)
        XCTAssertEqual(try Data(contentsOf: url), Data("broken".utf8))
    }

    @MainActor
    func testRealBachScoreRoundtripAndEditedExport() throws {
        // Optional real-user fixture lives only in this simulator's Documents, never in the app bundle.
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let source = ProcessInfo.processInfo.environment["MUSICFOCUS_BACH_TEST_PDF"].map { URL(fileURLWithPath: $0) } ?? docs.appendingPathComponent("Bach Original.pdf")
        guard FileManager.default.fileExists(atPath: source.path) else { throw XCTSkip("Real score is supplied locally for validation") }
        let originalData = try Data(contentsOf: source)
        let original = try XCTUnwrap(PDFDocument(url: source))
        let exported = try ScorePDFExport.editable(source: source, drawings: [:])
        let roundtrip = try XCTUnwrap(PDFDocument(url: exported))
        var total = 0
        for p in 0..<4 {
            let before = try XCTUnwrap(original.page(at: p)), after = try XCTUnwrap(roundtrip.page(at: p))
            XCTAssertEqual(after.annotations.count, before.annotations.count)
            for (a, b) in zip(before.annotations, after.annotations) {
                for (x, y) in zip([a.bounds.minX, a.bounds.minY, a.bounds.width, a.bounds.height], [b.bounds.minX, b.bounds.minY, b.bounds.width, b.bounds.height]) {
                    XCTAssertEqual(x, y, accuracy: 0.00001)
                }
                XCTAssertEqual(a.paths?.count, b.paths?.count)
                let aw = ScorePDFAnnotations.widths(a), bw = ScorePDFAnnotations.widths(b)
                XCTAssertEqual(aw.map(\.count), bw.map(\.count))
                XCTAssertLessThan(zip(aw.flatMap { $0 }, bw.flatMap { $0 }).map { abs($0-$1) }.max() ?? 0, 0.00001)
                XCTAssertTrue(b.hasAppearanceStream)
            }
            total += after.annotations.count
        }
        XCTAssertEqual(total, 857)
        let catalog = ScorePDFAnnotations(document: original)
        let first = try XCTUnwrap(catalog.entry("1:0")), old = first.original
        XCTAssertEqual(old.paths?.count, 2)
        var edits = ScoreAnnotationEdits()
        edits.items["1:0"] = .init(offset: CGPoint(x: 20, y: -15), color: .init(.systemBlue), removedPaths: [0])
        edits.items["1:1"] = .init(deleted: true)
        let translucent = try XCTUnwrap(catalog.entries.first { $0.opacity < 0.5 })
        edits.items[translucent.key] = .init(offset: CGPoint(x: 4, y: 0))
        let edited = try ScorePDFExport.editable(source: source, drawings: [1: drawing().dataRepresentation()], edits: edits)
        let editedDoc = try XCTUnwrap(PDFDocument(url: edited)), editedPage = try XCTUnwrap(editedDoc.page(at: 0))
        let changed = try XCTUnwrap(editedPage.annotations.first { ($0.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/NM")) as? String) == (old.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/NM")) as? String) })
        XCTAssertEqual(changed.paths?.count, 1)
        XCTAssertEqual(changed.bounds.origin.x, old.bounds.origin.x + 20, accuracy: 0.001)
        XCTAssertEqual(changed.bounds.origin.y, old.bounds.origin.y - 15, accuracy: 0.001)
        XCTAssertTrue(changed.hasAppearanceStream)
        let translucentPage = try XCTUnwrap(editedDoc.page(at: translucent.pageNumber - 1))
        let markerID = translucent.original.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/NM")) as? String
        let exportedMarker = try XCTUnwrap(translucentPage.annotations.first { ($0.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/NM")) as? String) == markerID })
        XCTAssertEqual(ScorePDFAnnotations.opacity(exportedMarker), translucent.opacity, accuracy: 0.001)
        XCTAssertEqual(editedPage.annotations.count, 317)
        XCTAssertEqual(try Data(contentsOf: source), originalData)
        for (url, name) in [(exported, "Bach Roundtrip.pdf"), (edited, "Bach Edited.pdf")] {
            let target = docs.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            try FileManager.default.copyItem(at: url, to: target)
        }
    }
}
