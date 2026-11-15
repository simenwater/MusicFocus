import XCTest
import PDFKit
import PencilKit
@testable import MusicFocus

final class ScoreFingeringTests: XCTestCase {
    // Independently drawn polylines, deliberately unlike the production Bézier
    // glyphs. Feed the real bundled model, not an OCR mock or rendered font.
    private static let handwriting: [[[(Double, Double)]]] = [
        [[(45,3),(20,0),(3,20),(0,65),(12,95),(40,100),(60,78),(65,30),(55,8),(45,3)]],
        [[(3,24),(26,2),(25,30),(27,65),(24,100)]],
        [[(0,20),(15,3),(40,0),(60,15),(58,34),(40,55),(15,80),(0,100),(65,98)]],
        [[(0,7),(27,0),(57,10),(55,30),(25,47),(50,49),(65,70),(55,92),(25,100),(0,88)]],
        [[(38,0),(4,62),(65,61)],[(48,15),(47,100)]],
        [[(62,0),(7,0),(3,47),(30,42),(53,51),(62,73),(49,94),(22,100),(0,90)]],
        [[(56,0),(31,17),(10,45),(0,75),(8,96),(31,100),(54,84),(56,65),(40,49),(17,51),(3,68)]],
        [[(0,2),(65,0),(45,37),(28,70),(13,100)]],
        [[(30,48),(4,24),(8,5),(32,0),(55,10),(57,28),(30,48),(3,70),(5,94),(30,100),(60,88),(57,65),(30,48)]],
        [[(58,30),(52,7),(29,0),(8,10),(0,32),(13,49),(39,48),(58,30),(53,65),(31,100)]]
    ]

    static func stroke(_ coordinates: [(Double, Double)], origin: CGPoint = CGPoint(x: 100,y: 100),
                       scale: Double = 0.3, color: UIColor = .systemBlue) -> PKStroke {
        var points: [CGPoint] = []
        for (a,b) in zip(coordinates, coordinates.dropFirst()) {
            for i in 0..<8 {
                let t = Double(i)/8
                points.append(CGPoint(x: origin.x + (a.0+(b.0-a.0)*t)*scale,
                                      y: origin.y + (a.1+(b.1-a.1)*t)*scale))
            }
        }
        if let last = coordinates.last { points.append(CGPoint(x: origin.x+last.0*scale,y: origin.y+last.1*scale)) }
        return PKStroke(ink: PKInk(.pen,color: color), path: PKStrokePath(controlPoints: points.enumerated().map { index,p in
            PKStrokePoint(location: p, timeOffset: Double(index)*0.01, size: CGSize(width: 3.5,height: 3.5),
                          opacity: 0.9999847409781033, force: 1, azimuth: 0, altitude: .pi/2)
        }, creationDate: Date()))
    }
    static func digitInk(_ value: Int, color: UIColor = .systemBlue) -> [PKStroke] {
        handwriting[value].map { stroke($0, color: color) }
    }
    static func circle(around box: CGRect, color: UIColor = .systemBlue) -> PKStroke {
        let side = max(box.width,box.height)+18
        let r = CGRect(x: box.midX-side/2,y: box.midY-side/2,width: side,height: side)
        let points = (0...48).map { i -> (Double, Double) in
            let a = Double(i)/48 * 2 * .pi
            return (r.midX + cos(a)*r.width/2, r.midY + sin(a)*r.height/2)
        }
        return stroke(points,origin: .zero,scale: 1,color: color)
    }

    func testDedicatedRecognitionOnIndependentDigitsAndCircledDigits() async throws {
        var report: [String] = []
        var recognized = 0
        for digit in 1...9 {
            let raw = Self.digitInk(digit)
            let result = await ScoreFingeringBeautifier.recognize(strokes: raw,newIDs: Set(raw.map(\.fingeringID)))
            report.append("\(digit): \(result.map(\.digit))")
            XCTAssertTrue(result.isEmpty || result.map(\.digit) == [digit], "Never substitute a different digit")
            if !result.isEmpty { recognized += 1 }
            // A circle can arrive after the digit, in a different color.
            let ring = Self.circle(around: PKDrawing(strokes: raw).bounds, color: .systemRed)
            let circled = await ScoreFingeringBeautifier.recognize(strokes: raw+[ring],newIDs: [ring.fingeringID])
            report.append("circled \(digit): \(circled.map(\.digit))")
            XCTAssertEqual(circled.map(\.digit), result.map(\.digit), "A circle must preserve the inner recognizer's decision")
            if !circled.isEmpty { XCTAssertEqual(circled.first?.circled, true) }
        }
        // Some deliberately drawn examples overlap letter styles. Abstention is
        // intentional; the public corpus measures recall, not these nine shapes.
        XCTAssertGreaterThanOrEqual(recognized, 6)
        let attachment = XCTAttachment(string: report.joined(separator: "\n")); attachment.lifetime = .keepAlways; add(attachment)
    }

    func testWordsLinesScribblesAndOldInkStayUnchanged() async {
        XCTAssertNil(ScoreFingeringBeautifier.digit("1 2"))
        for text in ["I","l","O","1.","12","finger 1",""] { XCTAssertNil(ScoreFingeringBeautifier.digit(text)) }
        let marks = [
            [Self.stroke([(0,0),(100,1)])],
            [Self.stroke([(0,0),(60,100)]),Self.stroke([(60,0),(0,100)])],
            [Self.stroke([(0,0),(70,80),(0,30),(70,20),(0,100),(55,0),(10,90)])]
        ]
        for strokes in marks {
            let result = await ScoreFingeringBeautifier.recognize(strokes: strokes,newIDs: Set(strokes.map(\.fingeringID)))
            XCTAssertTrue(result.isEmpty)
        }
        let old = Self.digitInk(2)
        let result = await ScoreFingeringBeautifier.recognize(strokes: old,newIDs: [])
        XCTAssertTrue(result.isEmpty)
    }

    func testThinBarlinesRoundNoteheadsAndStackedSymbolsStayHandwritten() async {
        let round: [(Double,Double)] = (0...48).map { i in
            let angle = Double(i)*2 * Double.pi/48
            return (50.0+45*cos(angle),50.0+45*sin(angle))
        }
        let stacked = Self.digitInk(2) + PKDrawing(strokes: Self.digitInk(4))
            .transformed(using: CGAffineTransform(translationX:0,y:43)).strokes
        let examples: [[PKStroke]] = [[Self.stroke([(0,0),(0.5,5),(-0.3,15),(0.2,40),(0,100)])],
                                      [Self.stroke(round)],stacked]
        for ink in examples {
            let result = await ScoreFingeringBeautifier.recognize(strokes:ink,newIDs:Set(ink.map(\.fingeringID)))
            XCTAssertTrue(result.isEmpty)
        }
    }

    func testDedicatedRecognizerRejectsAmbiguousNonDigits() async {
        let marks = [
            Self.digitInk(0), // Ambiguous O / 0 is kept, never coerced.
            [Self.stroke([(0,0),(0,100)])],
            [Self.stroke([(0,0),(70,100)]),Self.stroke([(70,0),(0,100)])],
            [Self.stroke([(0,0),(35,100),(70,0)])],
            [Self.stroke([(65,5),(40,0),(10,10),(0,30),(10,45),(55,60),(65,75),(55,95),(30,100),(0,90)])],
            [Self.stroke([(60,5),(35,0),(10,15),(0,50),(10,85),(35,100),(60,95)])]
        ]
        for ink in marks {
            let result = await ScoreFingeringBeautifier.recognize(strokes: ink, newIDs: Set(ink.map(\.fingeringID)))
            XCTAssertTrue(result.isEmpty, "Non-numeral marks must remain original ink")
        }
    }

    func testDetachedCrossbarAndCloseCircle() async throws {
        for gap in [8.0, 12, 16, 20, 23] {
            let sample = [Self.stroke([(7,0),(3,47),(30,42),(53,51),(62,73),(49,94),(22,100),(0,90)]),
                          Self.stroke([(3,-gap),(62,-gap)])]
            let result = await ScoreFingeringBeautifier.recognize(strokes: sample, newIDs: Set(sample.map(\.fingeringID)))
            var detail = "Detached crossbar, gap \(gap)"
            if #available(iOS 27.0, *), result.map(\.digit) != [5] {
                let text = await ScoreAppleDigitRecognizer().recognize(sample)
                detail += "; Apple's text: \(String(describing:text))"
            }
            XCTAssertEqual(result.map(\.digit), [5], detail)
        }
        // A common two-stroke 5: the top bar does not quite touch the body.
        let five = [Self.stroke([(7,0),(3,47),(30,42),(53,51),(62,73),(49,94),(22,100),(0,90)]),
                    Self.stroke([(3,-23),(62,-23)])]
        let separated = await ScoreFingeringBeautifier.recognize(strokes: five, newIDs: Set(five.map(\.fingeringID)))
        XCTAssertEqual(separated.map(\.digit), [5], "Detached top bar belongs to the same digit")
        // A tight, hand-drawn circle should not require a large blank margin.
        let digit = Self.digitInk(3)
        let box = PKDrawing(strokes: digit).bounds
        let circle = Self.circle(around: box)
        let target = box.insetBy(dx: -1.5, dy: -1.5)
        let ringBounds = circle.renderBounds
        var ring = circle
        ring.transform = CGAffineTransform(a: target.width/ringBounds.width, b: 0, c: 0,
            d: target.height/ringBounds.height, tx: target.minX-ringBounds.minX*target.width/ringBounds.width,
            ty: target.minY-ringBounds.minY*target.height/ringBounds.height)
        let ink = digit + [ring]
        let circled = await ScoreFingeringBeautifier.recognize(strokes: ink, newIDs: [ring.fingeringID])
        XCTAssertEqual(circled.map(\.digit), [3], "Close circle must be removed before recognition")
        XCTAssertEqual(circled.first?.circled, true)
    }

    func testDetachedBarDoesNotConsumeNearbyDigitsOrTurnTIntoOne() async {
        let adjacent = Self.digitInk(2) + PKDrawing(strokes: Self.digitInk(3))
            .transformed(using: CGAffineTransform(translationX: 38, y: 0)).strokes
        let result = await ScoreFingeringBeautifier.recognize(strokes: adjacent, newIDs: Set(adjacent.map(\.fingeringID)))
        XCTAssertEqual(Set(result.map(\.digit)), [2, 3])
        let letterT = [Self.stroke([(30,0),(30,100)]), Self.stroke([(0,-15),(60,-15)])]
        let rejected = await ScoreFingeringBeautifier.recognize(strokes: letterT, newIDs: Set(letterT.map(\.fingeringID)))
        XCTAssertTrue(rejected.isEmpty, "Detached horizontal marks must not force non-numerals into a digit")
    }

    func testLegacyIdentitySurvivesSaveMoveAndRecolor() throws {
        for digit in 0...9 {
            let original = try XCTUnwrap(ScoreFingeringBeautifier.render(digit: digit, from: Self.digitInk(digit)))
            let saved = try PKDrawing(data: original.dataRepresentation())
            XCTAssertEqual(original.strokes.map(\.legacyFingeringID), saved.strokes.map(\.legacyFingeringID))
            let moved = original.transformed(using: CGAffineTransform(translationX: 25, y: 35))
            XCTAssertEqual(original.strokes.map(\.legacyFingeringID), moved.strokes.map(\.legacyFingeringID))
            var changed = original.strokes[0]
            changed.ink = PKInk(.pen, color: .systemPurple)
            XCTAssertEqual(changed.legacyFingeringID, original.strokes[0].legacyFingeringID)
        }
        let first = Self.digitInk(2)[0]
        var different = first
        different.path = Self.digitInk(3)[0].path
        XCTAssertNotEqual(first.legacyFingeringID, different.legacyFingeringID)
    }

    func testVectorOutputKeepsDigitGeometryAndUsesACompactEditableRing() throws {
        let raw = Self.digitInk(4,color: UIColor.systemPurple.withAlphaComponent(0.4))
        let ring = Self.circle(around: PKDrawing(strokes: raw).bounds,color: .systemRed)
        let original = PKDrawing(strokes: raw+[ring])
        let clean = try XCTUnwrap(ScoreFingeringBeautifier.render(digit: 4,from: raw,circle: ring))
        let plain = try XCTUnwrap(ScoreFingeringBeautifier.render(digit: 4, from: raw))
        let glyphBounds = ScoreFingeringSizing.inkBounds(Array(clean.strokes.dropLast()))
        let ringBounds = ScoreFingeringSizing.inkBounds([try XCTUnwrap(clean.strokes.last)])
        // The compact-circle design intentionally replaces an oversized hand-
        // drawn ring. Adding it must leave the digit geometry unchanged.
        XCTAssertEqual(glyphBounds, ScoreFingeringSizing.inkBounds(plain.strokes))
        XCTAssertTrue(ringBounds.contains(glyphBounds))
        XCTAssertEqual(ringBounds.width, ringBounds.height, accuracy: 0.2)
        XCTAssertLessThan(ringBounds.width, original.bounds.width)
        XCTAssertTrue(clean.strokes.first!.ink.color.isEqual(raw[0].ink.color))
        XCTAssertEqual(clean.strokes.first!.ink.color.cgColor.alpha,0.4,accuracy: 0.001)
        XCTAssertTrue(clean.strokes.last!.ink.color.isEqual(ring.ink.color))
        let restored = try PKDrawing(data: clean.dataRepresentation())
        XCTAssertEqual(restored.strokes.map(\.fingeringID),clean.strokes.map(\.fingeringID))
        if #available(iOS 27.0, *) {
        let erased = clean.erasingPath(PKStrokePath(controlPoints: [
            PKStrokePoint(location: clean.bounds.origin, timeOffset: 0, size: CGSize(width: 200,height: 200), opacity: 1, force: 1, azimuth: 0, altitude: .pi/2),
            PKStrokePoint(location: CGPoint(x: clean.bounds.maxX,y: clean.bounds.maxY), timeOffset: 1, size: CGSize(width: 200,height: 200), opacity: 1, force: 1, azimuth: 0, altitude: .pi/2)
        ],creationDate: Date()))
        XCTAssertTrue(erased.strokes.isEmpty || erased.bounds.isEmpty)
        }
    }

    @MainActor
    func testRenderDigitsForVisualReview() throws {
        let images = (0...9).map { digit -> (UIImage,UIImage,CGRect) in
            let raw = Self.digitInk(digit), before = PKDrawing(strokes: Self.digitInk(digit))
            let clean = ScoreFingeringBeautifier.render(digit: digit,from: raw)!
            let bounds = before.bounds.insetBy(dx: -4,dy: -4)
            return (before.image(from: bounds,scale: 3),clean.image(from: bounds,scale: 3),bounds)
        }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 600,height: 1000)).image { context in
            context.cgContext.setFillColor(UIColor.white.cgColor); context.cgContext.fill(CGRect(x: 0,y: 0,width: 600,height: 1000))
            for digit in 0...9 {
                ("\(digit)" as NSString).draw(at: CGPoint(x: 20,y: CGFloat(digit*100+25)),withAttributes: [.font:UIFont.systemFont(ofSize: 24)])
                let (before,after,bounds) = images[digit]
                context.cgContext.saveGState()
                context.cgContext.translateBy(x: 0,y: CGFloat(digit*100)+bounds.height*2)
                context.cgContext.scaleBy(x: 1,y: -1)
                context.cgContext.draw(before.cgImage!,in: CGRect(x: 100,y: 0,width: bounds.width*2,height: bounds.height*2))
                context.cgContext.draw(after.cgImage!,in: CGRect(x: 350,y: 0,width: bounds.width*2,height: bounds.height*2))
                context.cgContext.restoreGState()
            }
        }
        let attachment = XCTAttachment(image: image); attachment.name = "Fingering-before-after"; attachment.lifetime = .keepAlways; add(attachment)
        let url = FileManager.default.urls(for: .documentDirectory,in: .userDomainMask)[0].appendingPathComponent("Fingering-Visual-Review.png")
        try image.pngData()?.write(to: url)
    }

    func testAmbiguousOvalAndVerticalStrokeKeepTheirOriginalInk() async {
        let samples = [Self.digitInk(0), [Self.stroke([(26,2),(25,30),(27,65),(24,100)])]]
        for ink in samples {
            let result = await ScoreFingeringBeautifier.recognize(strokes: ink,newIDs: Set(ink.map(\.fingeringID)))
            XCTAssertTrue(result.isEmpty, "An oval or lowercase l must not be guessed as 0 or 1")
        }
        XCTAssertEqual(ScoreFingeringBeautifier.digit("0"),0)
    }

    func testRecordedSimulatorSeven() async throws {
        guard let url = Bundle(for: Self.self).url(forResource: "RecordedFingering7", withExtension: "drawing") else {
            throw XCTSkip("Requires an optional local drawing fixture")
        }
        let raw = Array(try PKDrawing(data: Data(contentsOf: url)).strokes.suffix(2))
        let result = await ScoreFingeringBeautifier.recognize(strokes: raw,newIDs: Set(raw.map(\.fingeringID)))
        XCTAssertEqual(result.map(\.digit),[7])
    }

    @MainActor
    func testNativeInkIsVisible() throws {
        guard let url = Bundle(for: Self.self).url(forResource: "RecordedFingering7", withExtension: "drawing") else {
            throw XCTSkip("Requires an optional local drawing fixture")
        }
        let actual = try PKDrawing(data: Data(contentsOf: url))
        let raw = PKDrawing(strokes: Self.digitInk(7))
        let clean = try XCTUnwrap(ScoreFingeringBeautifier.render(digit: 7,from: raw.strokes))
        for (name,drawing) in [("recorded",actual),("raw",raw),("clean",clean)] {
            let image = drawing.image(from: drawing.bounds.insetBy(dx: -4,dy: -4),scale: 3)
            let cg = try XCTUnwrap(image.cgImage)
            var pixels = [UInt8](repeating: 0,count: cg.width*cg.height*4)
            let context = try XCTUnwrap(CGContext(data: &pixels,width: cg.width,height: cg.height,bitsPerComponent: 8,bytesPerRow: cg.width*4,space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cg,in: CGRect(x: 0,y: 0,width: cg.width,height: cg.height))
            let count = stride(from: 3,to: pixels.count,by: 4).filter { pixels[$0]>10 }.count
            print("VISIBLE \(name) \(count) size \(cg.width)x\(cg.height) bounds \(drawing.bounds)")
            XCTAssertGreaterThan(count,20,name)
            try image.pngData()?.write(to: FileManager.default.urls(for: .documentDirectory,in: .userDomainMask)[0].appendingPathComponent("Fingering-\(name).png"))
        }
    }

    func testCircleCanFollowAnAlreadyBeautifiedDigit() async throws {
        let ink = Self.digitInk(4)
        let first = await ScoreFingeringBeautifier.recognize(strokes: ink,newIDs: Set(ink.map(\.fingeringID)))
        let clean = try XCTUnwrap(first.first?.drawing)
        let circle = Self.circle(around: clean.bounds,color: .systemRed)
        // The app uses stored mark metadata for already-generated typefaces;
        // it must not run a handwriting classifier on its own rendered glyph.
        let mark = ScoreFingeringMark(drawing: clean, digit: 4, circled: false)
        let result = ScoreReaderController.encloseKnownFingerings(strokes: clean.strokes+[circle], fresh: [circle.fingeringID], marks: [mark])
        XCTAssertEqual(result.map(\.digit),[4])
        XCTAssertEqual(result.first?.circled,true)
        let replacement = try XCTUnwrap(result.first)
        XCTAssertTrue(replacement.drawing.strokes.last!.ink.color.isEqual(circle.ink.color))
    }

    @MainActor
    func testInkDeliveredAfterPenUpIsBeautifiedUsingTheRealRecognizer() async throws {
        let (reader,canvas,root,defaults,_,_) = try await fixture(recognition: { await ScoreFingeringService.recognize($0,$1) })
        defer { reader.detach(); testView = nil; defaults.removePersistentDomain(forName: root.lastPathComponent); try? FileManager.default.removeItem(at: root) }
        guard let url = Bundle(for: Self.self).url(forResource: "RecordedFingering7", withExtension: "drawing") else {
            throw XCTSkip("Requires an optional local drawing fixture")
        }
        let strokes = Array(try PKDrawing(data: Data(contentsOf: url)).strokes.suffix(2))
        reader.tool = .fingering
        reader.canvasViewDidBeginUsingTool(canvas)
        reader.canvasViewDidEndUsingTool(canvas)
        canvas.drawing = PKDrawing(strokes: strokes)
        reader.canvasViewDrawingDidChange(canvas)
        let raw = canvas.drawing
        try await Task.sleep(for: .milliseconds(1400))
        XCTAssertEqual(canvas.drawing.strokes.count,1,"The two real pen strokes become one clean 7")
        XCTAssertEqual(raw.strokes.count,2)
        reader.undo(); XCTAssertTrue(canvas.drawing.strokes.isEmpty,"One Undo removes the written digit and its conversion")
        let saved = await reader.flush(); XCTAssertTrue(saved)
    }

    @MainActor
    func testSwitchingOffWhileRecognitionIsRunningKeepsRawInk() async throws {
        let (reader,canvas,root,defaults,_,_) = try await fixture(recognition: { strokes,ids in
            try? await Task.sleep(for: .milliseconds(600))
            return await Self.replacement(strokes,ids)
        })
        defer { reader.detach(); testView = nil; defaults.removePersistentDomain(forName: root.lastPathComponent); try? FileManager.default.removeItem(at: root) }
        reader.tool = .fingering
        write(Self.digitInk(1),reader: reader,canvas: canvas)
        let raw = canvas.drawing
        try await Task.sleep(for: .milliseconds(950))
        reader.tool = .pen
        try await Task.sleep(for: .milliseconds(650))
        assertSameInk(canvas.drawing,raw)
        let saved = await reader.flush(); XCTAssertTrue(saved)
    }

    @MainActor
    private func fixture(recognition: @escaping ScoreFingeringRecognition) async throws -> (ScoreReaderController,ScoreCanvas,URL,UserDefaults,ScoreLibraryDisk,LibraryScore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        let source = root.appendingPathComponent("Fingering.pdf")
        try UIGraphicsPDFRenderer(bounds: CGRect(x: 0,y: 0,width: 600,height: 800)).writePDF(to: source) { $0.beginPage() }
        let disk = ScoreLibraryDisk(root: root.appendingPathComponent("Library")); _ = try await disk.load()
        let score = try await disk.importPDF(source)
        let defaults = UserDefaults(suiteName: root.lastPathComponent)!
        let reader = ScoreReaderController(inkDefaults: defaults,fingeringRecognition: recognition)
        XCTAssertEqual(reader.tool, .pen)
        await reader.load(score: score,disk: disk)
        let view = ScorePDFViewport(frame: CGRect(x: 0,y: 0,width: 600,height: 800))
        // Keep PDFView alive for the recognition task via the test's association.
        testView = view
        reader.attach(view); reader.editing = true; reader.tool = .monoline
        let page = try XCTUnwrap(reader.document?.page(at: 0))
        let overlay = try XCTUnwrap(reader.pdfView(view,overlayViewFor: page) as? ScorePageOverlay)
        return (reader,overlay.canvas,root,defaults,disk,score)
    }
    @MainActor private var testView: PDFView?

    @MainActor
    private func write(_ strokes: [PKStroke], reader: ScoreReaderController, canvas: ScoreCanvas) {
        reader.canvasViewDidBeginUsingTool(canvas)
        canvas.drawing = PKDrawing(strokes: canvas.drawing.strokes + strokes)
        reader.canvasViewDrawingDidChange(canvas)
        reader.canvasViewDidEndUsingTool(canvas)
    }

    private static let replacement: ScoreFingeringRecognition = { strokes,_ in
        guard let drawing = ScoreFingeringBeautifier.render(digit: 1,from: strokes) else { return [] }
        return [.init(sourceIDs: Set(strokes.map(\.fingeringID)),drawing: drawing,digit: 1,circled: false)]
    }

    @MainActor
    private final class GestureScroll: UIScrollView {
        var zoomInProgress = true
        override var isZooming: Bool { zoomInProgress }
    }

    @MainActor
    func testRecognizedInkWaitsForZoomThenAppliesWithoutAnotherStroke() async throws {
        let (reader, canvas, root, defaults, _, _) = try await fixture(recognition: Self.replacement)
        defer { reader.detach(); defaults.removePersistentDomain(forName: root.lastPathComponent); try? FileManager.default.removeItem(at: root) }
        let scroll = GestureScroll(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
        scroll.addSubview(canvas)
        reader.tool = .fingering
        write(Self.digitInk(2), reader: reader, canvas: canvas)
        let raw = canvas.drawing
        try await Task.sleep(for: .milliseconds(1300))
        assertSameInk(canvas.drawing, raw)
        scroll.zoomInProgress = false
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertNotEqual(canvas.drawing.strokes.map(\.fingeringID), raw.strokes.map(\.fingeringID))
        reader.undo(); XCTAssertTrue(canvas.drawing.strokes.isEmpty, "One Undo removes the whole digit")
    }

    @MainActor
    func testDisablingDuringDeferredZoomKeepsOriginalInk() async throws {
        let (reader, canvas, root, defaults, _, _) = try await fixture(recognition: Self.replacement)
        defer { reader.detach(); defaults.removePersistentDomain(forName: root.lastPathComponent); try? FileManager.default.removeItem(at: root) }
        let scroll = GestureScroll(frame: CGRect(x: 0, y: 0, width: 600, height: 800)); scroll.addSubview(canvas)
        reader.tool = .fingering
        write(Self.digitInk(2), reader: reader, canvas: canvas)
        let raw = canvas.drawing
        try await Task.sleep(for: .milliseconds(1300))
        reader.tool = .pen; scroll.zoomInProgress = false
        try await Task.sleep(for: .milliseconds(350))
        assertSameInk(canvas.drawing, raw)
    }

    /// User report: write 1, undo, write 2, undo -> the undone 1 came back. The first
    /// Undo only reverted the conversion, leaving the raw 1 on the page; it then joined
    /// the next digit's recognition and reappeared on the next Undo.
    @MainActor
    func testUndoAfterConversionRemovesTheDigitAndItNeverReturns() async throws {
        let (reader, canvas, root, defaults, _, _) = try await fixture(recognition: Self.replacement)
        defer { reader.detach(); testView = nil; defaults.removePersistentDomain(forName: root.lastPathComponent); try? FileManager.default.removeItem(at: root) }
        reader.tool = .fingering
        write(Self.digitInk(1), reader: reader, canvas: canvas)
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertFalse(canvas.drawing.strokes.isEmpty)
        reader.undo()
        XCTAssertTrue(canvas.drawing.strokes.isEmpty, "The 1 is gone after one Undo")
        write(Self.digitInk(2), reader: reader, canvas: canvas)
        try await Task.sleep(for: .milliseconds(1200))
        reader.undo()
        XCTAssertTrue(canvas.drawing.strokes.isEmpty, "Undoing the 2 must not bring back the 1")
        XCTAssertFalse(reader.canUndo)
        reader.redo()
        XCTAssertFalse(canvas.drawing.strokes.isEmpty, "Redo restores the converted 2")
        XCTAssertFalse(reader.canRedo)
    }

    @MainActor
    func testEnabledPipelineUndoRedoSaveAndEditableExport() async throws {
        let (reader,canvas,root,defaults,disk,score) = try await fixture(recognition: Self.replacement)
        defer { reader.detach(); testView = nil; defaults.removePersistentDomain(forName: root.lastPathComponent); try? FileManager.default.removeItem(at: root) }
        // The reader remembers the last ordinary pen kind; the fingering pen is never that pen.
        for pen in [ScoreInkTool.pen, .monoline] {
            reader.tool = pen; reader.tool = .fingering
            XCTAssertEqual(defaults.string(forKey: "score.penMode.v1"), pen.rawValue)
            XCTAssertEqual(ScoreReaderController(inkDefaults: defaults).tool, pen, "Reopening never changes an ordinary pen into a fingering pen")
        }
        write(Self.digitInk(1),reader: reader,canvas: canvas)
        let original = canvas.drawing.dataRepresentation()
        try await Task.sleep(for: .milliseconds(1200))
        let clean = canvas.drawing.dataRepresentation()
        XCTAssertNotEqual(clean,original)
        XCTAssertFalse(try PKDrawing(data: original).strokes.isEmpty)
        reader.undo(); XCTAssertTrue(canvas.drawing.strokes.isEmpty, "Undo goes back to before the digit was written")
        reader.redo(); assertSameInk(canvas.drawing,try PKDrawing(data: clean))
        let saved = await reader.flush(); XCTAssertTrue(saved)
        let diskInk = try await disk.drawings(score.id)
        assertSameInk(try PKDrawing(data: XCTUnwrap(diskInk[1])),try PKDrawing(data: clean))
        let url = await reader.export()
        let exported = try XCTUnwrap(url)
        defer { try? FileManager.default.removeItem(at: exported.deletingLastPathComponent()) }
        let pdf = try XCTUnwrap(PDFDocument(url: exported)), page = try XCTUnwrap(pdf.page(at: 0))
        XCTAssertEqual(page.annotations.count,canvas.drawing.strokes.count)
        XCTAssertTrue(page.annotations.allSatisfy { $0.type == "Ink" && !($0.paths?.isEmpty ?? true) })
        let annotation = try XCTUnwrap(page.annotations.first)
        let count = page.annotations.count
        page.removeAnnotation(annotation); XCTAssertEqual(page.annotations.count,count-1)
        page.addAnnotation(annotation); XCTAssertEqual(page.annotations.count,count)
    }

    @MainActor
    func testDisabledAndCancelledRecognitionNeverReplacesInk() async throws {
        let (reader,canvas,root,defaults,_,_) = try await fixture(recognition: { strokes,ids in
            try? await Task.sleep(for: .milliseconds(600))
            return await Self.replacement(strokes,ids)
        })
        defer { reader.detach(); testView = nil; defaults.removePersistentDomain(forName: root.lastPathComponent); try? FileManager.default.removeItem(at: root) }
        write(Self.digitInk(1),reader: reader,canvas: canvas)
        let old = canvas.drawing.dataRepresentation()
        try await Task.sleep(for: .milliseconds(950)); XCTAssertEqual(canvas.drawing.dataRepresentation(),old)
        reader.tool = .fingering
        write([Self.stroke([(10,0),(11,100)],origin: CGPoint(x: 180,y: 100))],reader: reader,canvas: canvas)
        try await Task.sleep(for: .milliseconds(950)) // Model is running.
        reader.undo()
        assertSameInk(canvas.drawing,try PKDrawing(data: old))
        try await Task.sleep(for: .milliseconds(650))
        assertSameInk(canvas.drawing,try PKDrawing(data: old))
        reader.redo()
        let raw = canvas.drawing.dataRepresentation()
        reader.tool = .pen
        try await Task.sleep(for: .milliseconds(950)); XCTAssertEqual(canvas.drawing.dataRepresentation(),raw)
        let saved = await reader.flush(); XCTAssertTrue(saved)
    }

    private func assertSameInk(_ lhs: PKDrawing, _ rhs: PKDrawing, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(lhs.strokes.map(\.fingeringID),rhs.strokes.map(\.fingeringID),file: file,line: line)
        XCTAssertEqual(lhs.bounds,rhs.bounds,file: file,line: line)
        for (a,b) in zip(lhs.strokes,rhs.strokes) {
            // PencilKit round-trips dynamic UIColors as fixed PDF-paper colors.
            func rgba(_ color: UIColor) -> [CGFloat] {
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, alpha: CGFloat = 0
                color.getRed(&r, green: &g, blue: &b, alpha: &alpha)
                return [r, g, b, alpha]
            }
            for (x, y) in zip(rgba(a.ink.color), rgba(b.ink.color)) {
                XCTAssertEqual(x, y, accuracy: 0.0001, file: file, line: line)
            }
            XCTAssertEqual(a.transform,b.transform,file: file,line: line)
            XCTAssertEqual(a.path.count,b.path.count,file: file,line: line)
            for (p,q) in zip(a.path,b.path) {
                XCTAssertEqual(p.location,q.location,file: file,line: line)
                XCTAssertEqual(p.size,q.size,file: file,line: line)
                XCTAssertEqual(p.opacity,q.opacity,file: file,line: line)
            }
        }
    }
}
