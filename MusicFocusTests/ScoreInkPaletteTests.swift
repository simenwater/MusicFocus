import XCTest
import PDFKit
@testable import MusicFocus

final class ScoreInkPaletteTests: XCTestCase {
    @MainActor
    func testCustomFavoritesPersistWithoutChangingOtherToolsOrExistingStyleSettings() throws {
        let suite = "Palette-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let marker = ScoreInkStyle(color: .init(.systemPurple), width: 24, opacity: 0.25)
        defaults.set(try JSONEncoder().encode(["marker": marker]), forKey: "score.inkStyles.v1")
        let reader = ScoreReaderController(inkDefaults: defaults)
        XCTAssertEqual(Array(reader.inkColorPresets.prefix(3)), Array(ScoreInkPalette.initialPresets.prefix(3)))
        let custom = UIColor(red: 0.15, green: 0.55, blue: 0.7, alpha: 1)
        reader.chooseColor(custom); reader.chooseWidth(4)
        reader.setInkColorPreset(reader.currentColor, at: 4)
        XCTAssertFalse(reader.canUndo, "Saving a palette must not create document undo entries")
        XCTAssertFalse(reader.hasUnsavedChanges)
        let reopened = ScoreReaderController(inkDefaults: defaults)
        XCTAssertEqual(reopened.inkColorPresets[4], ScoreAnnotationColor(custom))
        XCTAssertEqual(reopened.inkStyle.width, 4)
        reopened.tool = .marker
        XCTAssertEqual(reopened.inkStyle, marker)
        reopened.chooseColor(reopened.inkColorPresets[4].uiColor)
        XCTAssertEqual(reopened.tool, .marker)
        XCTAssertEqual(reopened.inkStyle.width, 24)
        XCTAssertEqual(reopened.currentOpacity, 0.25)
        let before = reopened.inkColorPresets
        reopened.setInkColorPreset(reopened.currentColor, at: -1); reopened.setInkColorPreset(reopened.currentColor, at: 6)
        XCTAssertEqual(reopened.inkColorPresets, before)
    }

    @MainActor
    func testUnifiedPenRemembersModeWithoutMixingItsStyles() throws {
        let suite = "PenMode-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let reader = ScoreReaderController(inkDefaults: defaults)
        reader.tool = .pen; reader.chooseWidth(8); reader.chooseColor(.blue)
        reader.tool = .monoline; reader.chooseWidth(1); reader.chooseColor(.red)
        reader.tool = .marker
        XCTAssertEqual(reader.preferredPenTool,.monoline)
        reader.tool = reader.preferredPenTool
        XCTAssertEqual(reader.inkStyle.width,1)
        XCTAssertEqual(ScoreAnnotationColor(reader.currentColor),ScoreAnnotationColor(.red))
        let reopened = ScoreReaderController(inkDefaults: defaults)
        XCTAssertEqual(reopened.tool,.monoline)
        reopened.tool = .pen
        XCTAssertEqual(reopened.inkStyle.width,8)
        XCTAssertEqual(ScoreAnnotationColor(reopened.currentColor),ScoreAnnotationColor(.blue))
        XCTAssertFalse(reader.canUndo)
        XCTAssertEqual(ScoreInkTool.toolbarTools.filter { $0.isPen }.count,1)
    }

    @MainActor
    func testEditingActiveFavoriteUpdatesOnlyTheCurrentPenAndPersists() throws {
        let suite = "Palette-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let reader = ScoreReaderController(inkDefaults: defaults)
        reader.tool = .marker; reader.chooseColor(reader.inkColorPresets[0].uiColor)
        reader.chooseWidth(24); reader.chooseOpacity(0.25)
        let color = UIColor(red: 52.0/255, green: 120.0/255, blue: 194.0/255, alpha: 1)
        reader.setInkColorPreset(color, at: 0)
        XCTAssertEqual(ScoreAnnotationColor(reader.currentColor), ScoreAnnotationColor(color))
        XCTAssertEqual(reader.inkStyle.width, 24); XCTAssertEqual(reader.currentOpacity, 0.25)
        XCTAssertFalse(reader.canUndo)
        let reopened = ScoreReaderController(inkDefaults: defaults)
        XCTAssertEqual(ScoreInkPalette.label(for: reopened.inkColorPresets[0]), "#3478C2")
        XCTAssertEqual(reopened.inkStyle.color, ScoreInkStyle.initial(for: .pen).color)
        reopened.tool = .marker
        XCTAssertEqual(reopened.inkStyle.color, ScoreAnnotationColor(color))
        XCTAssertEqual(reopened.currentOpacity, 0.25)
    }

    @MainActor
    func testMalformedAndPartialPalettesFallBackWithoutLosingValidSlots() throws {
        let suite = "Palette-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("not json".utf8), forKey: ScoreInkPalette.defaultsKey)
        XCTAssertEqual(ScoreReaderController(inkDefaults: defaults).inkColorPresets, ScoreInkPalette.initialPresets)
        let valid = ScoreAnnotationColor(.brown)
        defaults.set(try JSONEncoder().encode([valid]), forKey: ScoreInkPalette.defaultsKey)
        let restored = ScoreReaderController(inkDefaults: defaults).inkColorPresets
        XCTAssertEqual(restored.count, 6); XCTAssertEqual(restored[0], valid)
        XCTAssertEqual(restored[5], ScoreInkPalette.initialPresets[5])
        var invalid = valid; invalid.red = .infinity
        XCTAssertEqual(ScoreInkPalette.validated([invalid])[0], ScoreInkPalette.initialPresets[0])
        invalid.red = -0.2
        XCTAssertEqual(ScoreInkPalette.validated([invalid])[0], ScoreInkPalette.initialPresets[0])
    }

    @MainActor
    func testImportedNotePresetColorUndoRedoAndEditableExport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Source.pdf")
        try UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 600, height: 800)).writePDF(to: source) { $0.beginPage() }
        let document = try XCTUnwrap(PDFDocument(url: source)), page = try XCTUnwrap(document.page(at: 0))
        let ink = PDFAnnotation(bounds: CGRect(x: 20, y: 20, width: 200, height: 40), forType: .ink, withProperties: nil)
        ink.color = .red
        let path = UIBezierPath(); path.move(to: CGPoint(x: 5, y: 15)); path.addLine(to: CGPoint(x: 190, y: 25))
        ink.add(path); page.addAnnotation(ink); XCTAssertTrue(document.write(to: source))
        let original = try Data(contentsOf: source)
        let disk = ScoreLibraryDisk(root: root.appendingPathComponent("Library")); _ = try await disk.load()
        let score = try await disk.importPDF(source)
        let suite = "Palette-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let reader = ScoreReaderController(inkDefaults: defaults); await reader.load(score: score, disk: disk)
        reader.chooseColor(.brown); reader.setInkColorPreset(reader.currentColor, at: 0)
        reader.tool = .select; reader.select("1:0")
        reader.setInkColorPreset(.red, at: 2)
        reader.setInkColorPreset(.systemPurple, at: 2)
        XCTAssertEqual(ScoreAnnotationColor(reader.currentColor), ScoreAnnotationColor(.red), "Editing a matching palette slot must not recolor an existing note")
        XCTAssertFalse(reader.canUndo)
        reader.chooseColor(reader.inkColorPresets[0].uiColor)
        XCTAssertEqual(ScoreAnnotationColor(reader.currentColor), ScoreAnnotationColor(.brown))
        reader.setInkColorPreset(reader.currentColor, at: 5)
        reader.undo()
        XCTAssertEqual(ScoreAnnotationColor(reader.currentColor), ScoreAnnotationColor(.red), "One undo must revert the annotation, not a palette save")
        reader.redo()
        let exported = await reader.export()
        let output = try XCTUnwrap(exported), result = try XCTUnwrap(PDFDocument(url: output))
        defer { try? FileManager.default.removeItem(at: output.deletingLastPathComponent()) }
        let note = try XCTUnwrap(result.page(at: 0)?.annotations.first)
        XCTAssertEqual(note.type, "Ink")
        XCTAssertEqual(Double(note.color.cgColor.components?[0] ?? 0), 0.6, accuracy: 0.01)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }
    @MainActor
    func testChangingInkStyleDoesNotStealFocusFromColorInputs() async throws {
        let device = try await ScoreSyncFixture.Device(pdf: ScoreSyncFixture.pdf(pages: 1))
        defer { device.cleanUp() }
        let reader = ScoreReaderController()
        await reader.load(score: device.score, disk: device.disk)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene); let host = UIViewController()
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { reader.detach(); window.isHidden = true }
        let pdf = ScorePDFViewport(frame: CGRect(x: 0, y: 80, width: 600, height: 700))
        host.view.addSubview(pdf); reader.attach(pdf); reader.editing = true
        let input = UITextField(frame: CGRect(x: 20, y: 20, width: 200, height: 44))
        host.view.addSubview(input); XCTAssertTrue(input.becomeFirstResponder())
        reader.chooseColor(.systemTeal); reader.chooseWidth(4); reader.chooseOpacity(0.5)
        XCTAssertTrue(input.isFirstResponder, "A color/width/opacity update must not interrupt an in-progress color entry")
        reader.focusKeys()
        XCTAssertTrue(pdf.isFirstResponder, "Closing the palette can explicitly restore pedal/keyboard navigation")
    }

}
