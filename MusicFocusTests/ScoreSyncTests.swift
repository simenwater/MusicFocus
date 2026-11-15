import PDFKit
import PencilKit
import XCTest
@testable import MusicFocus

/// Deterministic bytes, so two "iPads" (or two simulators) can import the same file.
enum ScoreSyncFixture {
    static func pdf(pages: Int, label: String = "") -> Data {
        var objects = ["<< /Type /Catalog /Pages 2 0 R >>",
                       "<< /Type /Pages /Kids [\((0..<pages).map { "\($0 + 3) 0 R" }.joined(separator: " "))] /Count \(pages) >>"]
        objects += (0..<pages).map { _ in "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 600 800] /Resources << >> >>" }
        var text = "%PDF-1.4\n%\(label)\n", offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(text.utf8.count)
            text += "\(index + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xref = text.utf8.count
        text += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        text += offsets.map { String(format: "%010d 00000 n \n", $0) }.joined()
        text += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return Data(text.utf8)
    }

    static func stroke(_ y: CGFloat, color: UIColor = .red) -> PKStroke {
        let points = (0..<12).map { i in
            PKStrokePoint(location: CGPoint(x: 100 + CGFloat(i) * 6, y: y), timeOffset: Double(i) * 0.01,
                          size: CGSize(width: 3, height: 3), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: PKInk(.pen, color: color), path: PKStrokePath(controlPoints: points, creationDate: Date()))
    }

    static func snapshot(_ ys: [Int: [CGFloat]], digit: Int = 3, edits: [String: ScoreAnnotationEdit] = [:]) -> ScoreAnnotationSnapshot {
        var result = ScoreAnnotationSnapshot()
        for (page, values) in ys {
            let drawing = PKDrawing(strokes: values.map { stroke($0) })
            result.drawings[page] = drawing.dataRepresentation()
            if let first = values.first {
                result.fingerings[page] = [ScoreFingeringMark(drawing: PKDrawing(strokes: [stroke(first)]), digit: digit, circled: false)]
            }
        }
        result.edits.items = edits
        return result
    }

    /// One device: a library holding one imported copy of `pdf`.
    @MainActor
    final class Device {
        let root: URL
        let disk: ScoreLibraryDisk
        let score: LibraryScore
        let target: ScoreSyncDiskTarget
        let session = ScoreSyncSession()

        init(pdf: Data, name: String = "Score") async throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("ScoreSync-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let source = root.appendingPathComponent("\(name).pdf")
            try pdf.write(to: source)
            disk = ScoreLibraryDisk(root: root.appendingPathComponent("Library"))
            _ = try await disk.load()
            score = try await disk.importPDF(source)
            target = ScoreSyncDiskTarget(disk: disk, scoreID: score.id)
            await session.configure(identity: .init(digest: score.sourceDigest ?? "", pageCount: score.pageCount, title: score.title,
                                                    layout: score.layoutDigest),
                                    scoreID: score.id, disk: disk, target: target)
        }

        func annotations() async throws -> ScoreAnnotationSnapshot { try await disk.annotationSnapshot(score.id) }
        func write(_ snapshot: ScoreAnnotationSnapshot) async throws { try await disk.replaceAnnotations(score.id, with: snapshot) }
        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }
}

@MainActor
func scoreSyncWait(timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line,
                   _ condition: @MainActor () async throws -> Bool) async throws {
    let end = Date().addingTimeInterval(timeout)
    while try await !condition() {
        guard Date() < end else { XCTFail("Timed out", file: file, line: line); return }
        try await Task.sleep(for: .milliseconds(20))
    }
}

/// Blank pages compare equal whether stored as an empty drawing or not at all.
private func normalized(_ snapshot: ScoreAnnotationSnapshot) -> ScoreAnnotationSnapshot {
    var result = snapshot
    result.drawings = result.drawings.filter { ((try? PKDrawing(data: $0.value))?.strokes.count ?? 0) > 0 }
    return result
}

final class ScoreSyncTests: XCTestCase {
    private var devices: [ScoreSyncFixture.Device] = []

    @MainActor
    private func spin(_ seconds: TimeInterval = 0.3) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    @MainActor
    override func tearDown() async throws {
        devices.forEach { $0.cleanUp() }
        devices.removeAll()
    }

    @MainActor
    private func pair(_ pdfA: Data, _ pdfB: Data) async throws -> (ScoreSyncFixture.Device, ScoreSyncFixture.Device) {
        let a = try await ScoreSyncFixture.Device(pdf: pdfA, name: "bach1")
        let b = try await ScoreSyncFixture.Device(pdf: pdfB, name: "bach1")
        devices += [a, b]
        let (ta, tb) = ScoreSyncLoopback.pair("Teacher", "Student")
        a.session.connect(ta)
        b.session.connect(tb)
        try await scoreSyncWait { a.session.remote != nil && b.session.remote != nil }
        return (a, b)
    }

    // MARK: Base-file identity

    /// A copy whose bytes differ but whose pages line up (an annotated export, a
    /// re-saved file) can join a live lesson; saved annotations stay exact-file only.
    @MainActor
    func testSameLayoutAllowsLiveLessonButNotSavedSync() async throws {
        let pdf = ScoreSyncFixture.pdf(pages: 2)
        let (teacher, student) = try await pair(pdf, ScoreSyncFixture.pdf(pages: 2, label: "annotated copy"))
        XCTAssertNotEqual(teacher.score.sourceDigest, student.score.sourceDigest)
        XCTAssertEqual(teacher.score.layoutDigest, student.score.layoutDigest)
        XCTAssertFalse(teacher.session.sameBaseFile)
        XCTAssertTrue(teacher.session.sameLayout && student.session.sameLayout)
        XCTAssertEqual(student.session.status, "score.sync.similarFile".localized)

        try await teacher.write(ScoreSyncFixture.snapshot([1: [100]]))
        await teacher.session.requestSync()
        XCTAssertFalse(teacher.session.waiting, "Saved annotations are never exchanged between different files")

        teacher.session.liveInterval = .seconds(60)
        teacher.session.startLive()
        try await scoreSyncWait { student.session.incoming != nil }
        await student.session.respond(.takeTheirs)
        try await scoreSyncWait { teacher.session.live == .presenting && student.session.live == .watching }
        let marked = ScoreSyncFixture.snapshot([2: [120, 140]])
        try await teacher.write(marked)
        await teacher.session.pushLiveChanges()
        try await scoreSyncWait { try await student.annotations().drawings[2] == marked.drawings[2] }

        // Another page count is still a different score.
        let (a, b) = try await pair(pdf, ScoreSyncFixture.pdf(pages: 3))
        XCTAssertFalse(a.session.sameLayout || b.session.sameLayout)
        a.session.startLive()
        XCTAssertFalse(a.session.waiting)
    }

    func testLayoutSurvivesAnnotatedExportsOfTheSameScore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var made = [root]
        defer { made.forEach { try? FileManager.default.removeItem(at: $0) } }
        let source = root.appendingPathComponent("score.pdf")
        try ScoreSyncFixture.pdf(pages: 2).write(to: source)
        let ink = [1: PKDrawing(strokes: [ScoreSyncFixture.stroke(200)]).dataRepresentation()]
        let editable = try ScorePDFExport.editable(source: source, drawings: ink)
        let flattened = try ScorePDFExport.create(source: source, drawings: ink)
        made += [editable.deletingLastPathComponent(), flattened.deletingLastPathComponent()]
        let layout = try ScoreLibraryDisk.layoutDigest(of: source)
        XCTAssertNotEqual(try ScoreLibraryDisk.sha256(of: editable), try ScoreLibraryDisk.sha256(of: source))
        XCTAssertEqual(try ScoreLibraryDisk.layoutDigest(of: editable), layout)
        XCTAssertEqual(try ScoreLibraryDisk.layoutDigest(of: flattened), layout)
        let longer = root.appendingPathComponent("longer.pdf")
        try ScoreSyncFixture.pdf(pages: 3).write(to: longer)
        XCTAssertNotEqual(try ScoreLibraryDisk.layoutDigest(of: longer), layout)
    }

    @MainActor
    func testSameBytesMatchAndDifferentBytesAreRefused() async throws {
        let pdf = ScoreSyncFixture.pdf(pages: 2)
        let (a, b) = try await pair(pdf, pdf)
        XCTAssertEqual(a.score.sourceDigest, b.score.sourceDigest)
        XCTAssertTrue(a.session.sameBaseFile)
        XCTAssertTrue(b.session.sameBaseFile)

        // Same title and page count, different bytes: refused, nothing applied.
        let (c, d) = try await pair(pdf, ScoreSyncFixture.pdf(pages: 2, label: "other edition"))
        XCTAssertEqual(c.score.title, d.score.title)
        XCTAssertNotEqual(c.score.sourceDigest, d.score.sourceDigest)
        XCTAssertFalse(c.session.sameBaseFile)
        XCTAssertFalse(d.session.sameBaseFile)
        let before = try await d.annotations()
        try await c.write(ScoreSyncFixture.snapshot([1: [100]]))
        await c.session.requestSync()
        XCTAssertFalse(c.session.waiting, "No request is sent to a different file")
        // Even a forced request is answered with "different file".
        let identity = try XCTUnwrap(c.session.identity)
        let forced = try ScoreSyncCodec.encode(.init(app: "test", identity: identity,
                                                     message: .syncRequest(id: UUID(), snapshot: try await c.annotations())))
        let (raw, _) = ScoreSyncLoopback.pair("Teacher", "Student")
        d.session.connect(raw)
        raw.onReceive?(forced)
        await d.session.settle()
        XCTAssertNil(d.session.incoming)
        let after = try await d.annotations()
        XCTAssertEqual(after, before)
    }

    @MainActor
    func testDigestIsComputedAndCachedForOlderImports() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ScoreSync-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("Old.pdf")
        try ScoreSyncFixture.pdf(pages: 1).write(to: source)
        let library = ScoreLibrary(root: root.appendingPathComponent("Library"))
        await library.load()
        let importedScores = await library.importFiles([source])
        let imported = try XCTUnwrap(importedScores.first)
        let expected = try XCTUnwrap(imported.sourceDigest)
        XCTAssertEqual(expected, try ScoreLibraryDisk.sha256(of: source))

        // Simulate a score imported before digests were stored.
        let manifestURL = root.appendingPathComponent("Library/library.json")
        var manifest = try JSONDecoder().decode(ScoreLibraryManifest.self, from: Data(contentsOf: manifestURL))
        manifest.scores[0].sourceDigest = nil
        try JSONEncoder().encode(manifest).write(to: manifestURL)
        let reopened = ScoreLibrary(root: root.appendingPathComponent("Library"))
        await reopened.load()
        XCTAssertNil(reopened.scores[0].sourceDigest)
        let digest = try await reopened.ensureSourceDigest(imported.id)
        XCTAssertEqual(digest, expected)
        let saved = try JSONDecoder().decode(ScoreLibraryManifest.self, from: Data(contentsOf: manifestURL))
        XCTAssertEqual(saved.scores[0].sourceDigest, expected)
    }

    // MARK: Payload

    func testPayloadRoundTripAndRejection() throws {
        let snapshot = ScoreSyncFixture.snapshot([1: [100, 200], 2: [300]],
                                                 edits: ["1:0": .init(deleted: true), "2:1": .init(offset: CGPoint(x: 3, y: 4), removedPaths: [1])])
        let identity = ScoreSyncIdentity(digest: "abc", pageCount: 2, title: "bach1")
        for message: ScoreSyncMessage in [.hello, .syncRequest(id: UUID(), snapshot: snapshot),
                                          .livePage(page: 2, drawing: snapshot.drawings[2], fingerings: snapshot.fingerings[2] ?? []),
                                          .liveEdits(snapshot.edits), .syncReply(id: UUID(), reply: .tookYours), .liveEnd] {
            let envelope = ScoreSyncEnvelope(app: "2.3", identity: identity, message: message)
            XCTAssertEqual(try ScoreSyncCodec.decode(try ScoreSyncCodec.encode(envelope)), envelope)
        }
        XCTAssertEqual(try snapshot.validated(pageCount: 2), snapshot)
        XCTAssertEqual(snapshot.summary, .init(inkPages: 2, strokes: 3, fingerings: 2, pdfEdits: 2))

        XCTAssertThrowsError(try ScoreSyncCodec.decode(Data("garbage".utf8)))
        var newer = ScoreSyncEnvelope(app: "9", identity: identity, message: .hello)
        newer.schema = ScoreSyncEnvelope.schema + 1
        XCTAssertThrowsError(try ScoreSyncCodec.decode(try ScoreSyncCodec.encode(newer))) {
            guard case ScoreSyncError.newerSchema = $0 else { return XCTFail("\($0)") }
        }
        // Pages outside the shared PDF, damaged ink or bad keys never reach the reader.
        XCTAssertThrowsError(try snapshot.validated(pageCount: 1))
        XCTAssertThrowsError(try ScoreAnnotationSnapshot(drawings: [1: Data("not ink".utf8)]).validated(pageCount: 2))
        XCTAssertThrowsError(try ScoreAnnotationSnapshot(edits: .init(items: ["x": .init()])).validated(pageCount: 2))
    }

    // MARK: Direction

    @MainActor
    func testReceiverTakesTheirs() async throws {
        let pdf = ScoreSyncFixture.pdf(pages: 3)
        let (teacher, student) = try await pair(pdf, pdf)
        let teacherMarks = ScoreSyncFixture.snapshot([1: [100, 150], 3: [400]], edits: ["1:0": .init(deleted: true)])
        let studentMarks = ScoreSyncFixture.snapshot([2: [250]], digit: 5)
        try await teacher.write(teacherMarks)
        try await student.write(studentMarks)

        await teacher.session.requestSync()
        XCTAssertTrue(teacher.session.waiting)
        try await scoreSyncWait { student.session.incoming != nil }
        guard case let .sync(_, peer, _, theirs, mine) = student.session.incoming else { return XCTFail() }
        XCTAssertEqual(peer, "Teacher")
        XCTAssertEqual(theirs, teacherMarks.summary)
        XCTAssertEqual(mine, studentMarks.summary)

        await student.session.respond(.takeTheirs)
        let studentAfter = try await student.annotations()
        XCTAssertEqual(normalized(studentAfter), teacherMarks, "Student's copy now equals the teacher's")
        try await scoreSyncWait { !teacher.session.waiting }
        let teacherAfter = try await teacher.annotations()
        XCTAssertEqual(normalized(teacherAfter), teacherMarks, "Teacher's copy is untouched")
        XCTAssertEqual(student.session.backups.first?.summary, studentMarks.summary)
        XCTAssertTrue(teacher.session.backups.isEmpty)
    }

    @MainActor
    func testReceiverSendsMine() async throws {
        let pdf = ScoreSyncFixture.pdf(pages: 3)
        let (teacher, student) = try await pair(pdf, pdf)
        let teacherMarks = ScoreSyncFixture.snapshot([1: [100]])
        let studentMarks = ScoreSyncFixture.snapshot([2: [250, 260]], digit: 5, edits: ["3:0": .init(text: "hi")])
        try await teacher.write(teacherMarks)
        try await student.write(studentMarks)

        await teacher.session.requestSync()
        try await scoreSyncWait { student.session.incoming != nil }
        await student.session.respond(.sendMine)
        try await scoreSyncWait { !teacher.session.waiting }
        await teacher.session.settle()
        let teacherAfter = try await teacher.annotations()
        XCTAssertEqual(normalized(teacherAfter), studentMarks, "Initiator's copy replaced by the receiver's")
        let studentAfter = try await student.annotations()
        XCTAssertEqual(normalized(studentAfter), studentMarks)
        XCTAssertEqual(teacher.session.backups.first?.summary, teacherMarks.summary)
        XCTAssertTrue(student.session.backups.isEmpty)
        try await scoreSyncWait { student.session.status == "score.sync.theyTookYours".localizedFormat("Teacher") }
    }

    @MainActor
    func testDeclineChangesNothingAndUnsolicitedPushIsIgnored() async throws {
        let pdf = ScoreSyncFixture.pdf(pages: 2)
        let (teacher, student) = try await pair(pdf, pdf)
        try await teacher.write(ScoreSyncFixture.snapshot([1: [100]]))
        let studentMarks = ScoreSyncFixture.snapshot([2: [200]])
        try await student.write(studentMarks)
        await teacher.session.requestSync()
        try await scoreSyncWait { student.session.incoming != nil }
        await student.session.respond(.decline)
        try await scoreSyncWait { !teacher.session.waiting }
        let after = try await student.annotations()
        XCTAssertEqual(normalized(after), studentMarks)

        // A push nobody asked for is dropped.
        let identity = try XCTUnwrap(student.session.identity)
        let push = try ScoreSyncCodec.encode(.init(app: "test", identity: identity,
                                                   message: .syncPush(id: UUID(), snapshot: ScoreSyncFixture.snapshot([1: [1]]))))
        let (raw, _) = ScoreSyncLoopback.pair("Teacher", "Student")
        student.session.connect(raw)
        raw.onReceive?(push)
        await student.session.settle()
        let unchanged = try await student.annotations()
        XCTAssertEqual(normalized(unchanged), studentMarks)
    }

    // MARK: Backup

    @MainActor
    func testBackupAndRestore() async throws {
        let pdf = ScoreSyncFixture.pdf(pages: 2)
        let (teacher, student) = try await pair(pdf, pdf)
        let teacherMarks = ScoreSyncFixture.snapshot([1: [100]])
        let studentMarks = ScoreSyncFixture.snapshot([2: [200, 210]], edits: ["1:2": .init(deleted: true)])
        try await teacher.write(teacherMarks)
        try await student.write(studentMarks)
        await teacher.session.requestSync()
        try await scoreSyncWait { student.session.incoming != nil }
        await student.session.respond(.takeTheirs)

        let backup = try XCTUnwrap(student.session.backups.first)
        XCTAssertEqual(backup.reason, .sync)
        XCTAssertEqual(backup.peer, "Teacher")
        let saved = try await student.disk.backupSnapshot(backup, scoreID: student.score.id)
        XCTAssertEqual(normalized(saved), studentMarks)

        await student.session.restore(backup)
        let restored = try await student.annotations()
        XCTAssertEqual(normalized(restored), studentMarks)
        XCTAssertEqual(student.session.backups.count, 2)
        XCTAssertEqual(student.session.backups.first?.reason, .restore, "Restoring backs up what it replaces")

        for _ in 0..<12 {
            try await student.disk.backupAnnotations(studentMarks, scoreID: student.score.id, reason: .sync, peer: "x")
        }
        let kept = try await student.disk.syncBackups(student.score.id)
        XCTAssertEqual(kept.count, ScoreLibraryDisk.maximumSyncBackups)
    }

    // MARK: Live

    @MainActor
    func testLivePagesReachAnOpenReader() async throws {
        let pdf = ScoreSyncFixture.pdf(pages: 3)
        let teacher = try await ScoreSyncFixture.Device(pdf: pdf)
        let student = try await ScoreSyncFixture.Device(pdf: pdf)
        devices += [teacher, student]
        let studentMarks = ScoreSyncFixture.snapshot([3: [500]])
        try await student.write(studentMarks)

        // The student's copy is open in a reader, with ink of its own and undo history.
        let reader = ScoreReaderController()
        await reader.load(score: student.score, disk: student.disk)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 600, height: 800)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        defer { window.isHidden = true; reader.detach() }
        let view = ScorePDFViewport(frame: window.bounds)
        window.rootViewController!.view.addSubview(view)
        reader.attach(view)
        reader.editing = true
        spin()
        let page = try XCTUnwrap(reader.document?.page(at: 0))
        let canvas = try XCTUnwrap((reader.pdfView(view, overlayViewFor: page) as? ScorePageOverlay)?.canvas)
        reader.canvasViewDidBeginUsingTool(canvas)
        canvas.drawing = PKDrawing(strokes: [ScoreSyncFixture.stroke(700)])
        spin()
        reader.canvasViewDidEndUsingTool(canvas)
        XCTAssertTrue(reader.canUndo)

        let viewer = ScoreSyncSession()
        await viewer.configure(identity: .init(digest: student.score.sourceDigest!, pageCount: 3, title: "bach1"),
                               scoreID: student.score.id, disk: student.disk, target: reader)
        teacher.session.liveInterval = .seconds(60)  // the test pushes changes itself
        let (tt, ts) = ScoreSyncLoopback.pair("Teacher", "Student")
        teacher.session.connect(tt)
        viewer.connect(ts)
        try await scoreSyncWait { teacher.session.sameBaseFile && viewer.sameBaseFile }

        teacher.session.startLive()
        try await scoreSyncWait { viewer.incoming != nil }
        await viewer.respond(.takeTheirs)
        try await scoreSyncWait { teacher.session.live == .presenting && viewer.live == .watching }
        // The full snapshot (teacher has nothing yet) clears the student's copy.
        try await scoreSyncWait { reader.syncSnapshot().drawings.values.allSatisfy { (try? PKDrawing(data: $0))?.strokes.isEmpty ?? false } }
        XCTAssertEqual(viewer.backups.first?.reason, .live)
        XCTAssertFalse(reader.canUndo, "Synced changes clear the reader's undo history")

        // Teacher marks page 1 → only page 1 travels, visible canvas updates.
        let marked = ScoreSyncFixture.snapshot([1: [120, 140]])
        try await teacher.write(marked)
        await teacher.session.pushLiveChanges()
        try await scoreSyncWait { canvas.drawing.strokes.count == 2 }
        XCTAssertEqual(reader.syncSnapshot().drawings[1], marked.drawings[1])
        XCTAssertEqual(reader.syncSnapshot().fingerings[1], marked.fingerings[1])

        // Annotation edits follow too.
        var edited = marked
        edited.edits.items["2:0"] = .init(deleted: true)
        try await teacher.write(edited)
        await teacher.session.pushLiveChanges()
        try await scoreSyncWait { reader.annotationEdits == edited.edits }

        // Erasing on the teacher's side erases on the student's.
        try await teacher.write(.init(edits: edited.edits))
        await teacher.session.pushLiveChanges()
        try await scoreSyncWait { canvas.drawing.strokes.isEmpty }

        teacher.session.stopLive()
        try await scoreSyncWait { viewer.live == nil }
        let flushed = await reader.flush()
        XCTAssertTrue(flushed)
        let saved = try await student.annotations()
        XCTAssertEqual(normalized(saved), ScoreAnnotationSnapshot(edits: edited.edits))
        // The backup still has the student's own marks from before the lesson.
        let backup = try await student.disk.backupSnapshot(try XCTUnwrap(viewer.backups.first), scoreID: student.score.id)
        XCTAssertEqual(normalized(backup).drawings[3], studentMarks.drawings[3])
    }

    /// A reader for `device`'s score in its own window of the given size.
    @MainActor
    private func openReader(_ device: ScoreSyncFixture.Device, size: CGSize) async throws -> (ScoreReaderController, UIWindow) {
        let reader = ScoreReaderController()
        await reader.load(score: device.score, disk: device.disk)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        let view = ScorePDFViewport(frame: window.bounds)
        window.rootViewController!.view.addSubview(view)
        reader.attach(view)
        spin()
        return (reader, window)
    }

    @MainActor
    func testViewerFollowsThePresentersZoomAndScrolling() async throws {
        let pdf = ScoreSyncFixture.pdf(pages: 3)
        let teacherDevice = try await ScoreSyncFixture.Device(pdf: pdf)
        let studentDevice = try await ScoreSyncFixture.Device(pdf: pdf)
        devices += [teacherDevice, studentDevice]
        // Big iPad for the teacher, a phone-sized screen for the student.
        let (teacherReader, teacherWindow) = try await openReader(teacherDevice, size: CGSize(width: 820, height: 1100))
        let (studentReader, studentWindow) = try await openReader(studentDevice, size: CGSize(width: 390, height: 760))
        defer {
            teacherWindow.isHidden = true; studentWindow.isHidden = true
            teacherReader.detach(); studentReader.detach()
        }
        let presenter = ScoreSyncSession(), viewer = ScoreSyncSession()
        presenter.viewportInterval = .seconds(60)  // the test pushes the view itself
        let identity = ScoreSyncIdentity(digest: teacherDevice.score.sourceDigest!, pageCount: 3, title: "bach1")
        await presenter.configure(identity: identity, scoreID: teacherDevice.score.id, disk: teacherDevice.disk, target: teacherReader)
        await viewer.configure(identity: identity, scoreID: studentDevice.score.id, disk: studentDevice.disk, target: studentReader)
        studentReader.onUserNavigation = { [weak viewer] in viewer?.pauseFollowing() }
        let (tt, ts) = ScoreSyncLoopback.pair("Teacher", "Student")
        presenter.connect(tt)
        viewer.connect(ts)
        try await scoreSyncWait { presenter.sameBaseFile && viewer.sameBaseFile }
        presenter.startLive()
        try await scoreSyncWait { viewer.incoming != nil }
        await viewer.respond(.takeTheirs)
        try await scoreSyncWait { presenter.live == .presenting && viewer.live == .watching }

        /// The student sees all of the teacher's area, fitted to the narrower side
        /// (centred unless that would scroll past the start or end of the score).
        func studentMatchesTeacher() -> Bool {
            guard let teacher = teacherReader.syncViewport(), let student = studentReader.syncViewport() else { return false }
            let fitted = abs(student.width - teacher.width) < 0.01 || abs(student.height - teacher.height) < 0.01
            let contains = student.x <= teacher.x + 0.01 && student.y <= teacher.y + 0.01
                && student.x + student.width >= teacher.x + teacher.width - 0.01
                && student.y + student.height >= teacher.y + teacher.height - 0.01
            return student.page == teacher.page && fitted && contains
        }

        // Teacher turns to page 2 and zooms into its lower right.
        let teacherView = try XCTUnwrap(teacherReader.pdfViewForTesting)
        teacherReader.go(to: 2)
        spin()
        teacherView.autoScales = false
        teacherView.scaleFactor = teacherView.scaleFactor * 2.5
        spin()
        let page2 = try XCTUnwrap(teacherReader.document?.page(at: 1))
        teacherView.go(to: CGRect(x: 380, y: 60, width: 160, height: 160), on: page2)
        spin()
        let shown = try XCTUnwrap(teacherReader.syncViewport())
        XCTAssertEqual(shown.page, 2)
        XCTAssertLessThan(shown.width, 0.6, "Zoomed in")
        presenter.pushViewport()
        try await scoreSyncWait { studentMatchesTeacher() }

        // The student scrolls by hand: following pauses, the teacher's next move is not applied.
        studentReader.go(by: 1)
        XCTAssertFalse(viewer.following)
        spin()
        let studentOwn = try XCTUnwrap(studentReader.syncViewport())
        teacherReader.go(to: 1)
        spin()
        presenter.pushViewport()
        await viewer.settle()
        spin()
        XCTAssertEqual(studentReader.syncViewport()?.page, studentOwn.page)

        // "Follow" catches up with where the teacher is now.
        viewer.resumeFollowing()
        spin()
        XCTAssertTrue(viewer.following)
        try await scoreSyncWait { studentMatchesTeacher() }

        // A two-page spread on the teacher's side switches the student's layout too.
        teacherReader.twoPages = true
        spin()
        presenter.pushViewport()
        try await scoreSyncWait { studentReader.twoPages }
        presenter.stopLive()
        try await scoreSyncWait { viewer.live == nil }
        XCTAssertTrue(viewer.following)
    }

    func testViewportValidation() {
        let good = ScoreSyncViewport(page: 2, x: 0.1, y: 0.2, width: 0.5, height: 0.4, twoPages: false)
        XCTAssertNoThrow(try good.validated(pageCount: 3))
        var bad = good; bad.page = 4
        XCTAssertThrowsError(try bad.validated(pageCount: 3))
        bad = good; bad.width = .nan
        XCTAssertThrowsError(try bad.validated(pageCount: 3))
        bad = good; bad.height = 0
        XCTAssertThrowsError(try bad.validated(pageCount: 3))
        var moved = good; moved.x += 0.001
        XCTAssertTrue(good.isClose(to: moved))
        moved.x += 0.01
        XCTAssertFalse(good.isClose(to: moved))
    }

    func testMergeScopes() {
        let mine = ScoreSyncFixture.snapshot([1: [10], 2: [20]], edits: ["1:0": .init(deleted: true)])
        let theirs = ScoreSyncFixture.snapshot([2: [99], 3: [30]])
        let page = mine.merging(theirs, scope: .pages([2]))
        XCTAssertEqual(page.drawings[1], mine.drawings[1])
        XCTAssertEqual(page.drawings[2], theirs.drawings[2])
        XCTAssertNil(page.drawings[3])
        XCTAssertEqual(page.edits, mine.edits)
        let all = mine.merging(theirs, scope: .everything)
        XCTAssertEqual(all, theirs)
        let edits = mine.merging(theirs, scope: .edits)
        XCTAssertEqual(edits.drawings, mine.drawings)
        XCTAssertEqual(edits.edits, theirs.edits)
    }

    func testLocalizedStrings() throws {
        for language in ["en", "zh-Hans"] {
            let path = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj"))
            let bundle = try XCTUnwrap(Bundle(path: path))
            for key in ["score.sync.title", "score.sync.summary", "score.sync.confirmTakeMessage", "score.sync.differentFile"] {
                XCTAssertNotEqual(bundle.localizedString(forKey: key, value: "MISSING", table: nil), "MISSING", key)
            }
            XCTAssertNotEqual(bundle.localizedString(forKey: "NSLocalNetworkUsageDescription", value: "MISSING", table: "InfoPlist"), "MISSING")
        }
        let services = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "NSBonjourServices") as? [String])
        XCTAssertTrue(services.contains("_\(ScoreSyncNearby.serviceType)._tcp"))
        XCTAssertNotNil(Bundle.main.object(forInfoDictionaryKey: "NSLocalNetworkUsageDescription"))
    }
}
