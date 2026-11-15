import XCTest
import PDFKit
@testable import MusicFocus

final class ScoreExportNameTests: XCTestCase {
    @MainActor
    func testEditableAndPrintExportsKeepImportedChineseFilenameAndOriginalBytes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let name = "巴赫 BWV875《d小调前奏曲与赋格》-3.pdf"
        let source = root.appendingPathComponent(name)
        try UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 600, height: 800)).writePDF(to: source) { $0.beginPage() }
        let original = try Data(contentsOf: source)
        let disk = ScoreLibraryDisk(root: root.appendingPathComponent("Library")); _ = try await disk.load()
        let score = try await disk.importPDF(source)
        let reader = ScoreReaderController(); await reader.load(score: score, disk: disk)
        var outputs: [URL] = []
        defer { for url in outputs { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) } }
        for flattened in [false, true, false] {
            let result = await reader.export(flattened: flattened)
            let url = try XCTUnwrap(result); outputs.append(url)
            XCTAssertEqual(url.lastPathComponent, name)
            XCTAssertEqual(PDFDocument(url: url)?.pageCount, 1)
            XCTAssertNotEqual(url, source)
        }
        XCTAssertEqual(Set(outputs).count, 3, "Repeated exports must not overwrite each other")
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try Data(contentsOf: disk.pdfURL(score.id)), original)
        var renamed = score; renamed.title = "Étude Op. 10 — 练习 🎹"
        let renamedReader = ScoreReaderController(); await renamedReader.load(score: renamed, disk: disk)
        let renamedResult = await renamedReader.export()
        let renamedURL = try XCTUnwrap(renamedResult); outputs.append(renamedURL)
        XCTAssertEqual(renamedURL.lastPathComponent, renamed.title + ".pdf")
        // Live lessons pair devices by file hash: only the "original" export keeps it.
        let sharedResult = await renamedReader.exportOriginal()
        let shared = try XCTUnwrap(sharedResult); outputs.append(shared)
        XCTAssertEqual(shared.lastPathComponent, renamed.title + ".pdf")
        XCTAssertEqual(try Data(contentsOf: shared), original)
        XCTAssertEqual(try ScoreLibraryDisk.sha256(of: shared), score.sourceDigest)
        XCTAssertNotEqual(try ScoreLibraryDisk.sha256(of: renamedURL), score.sourceDigest)
    }

    func testFilenameStaysOnePathComponentAndKeepsUnicode() {
        XCTAssertEqual(ScorePDFExport.fileName(for: " Nocturne.PDF "), "Nocturne.pdf")
        XCTAssertEqual(ScorePDFExport.fileName(for: "乐谱 🎹"), "乐谱 🎹.pdf")
        XCTAssertEqual(ScorePDFExport.fileName(for: ""), "Score.pdf")
        for title in ["../练习/曲\\A:B\n", String(repeating: "🎹乐谱", count: 100)] {
            let name = ScorePDFExport.fileName(for: title)
            XCTAssertFalse(name.contains("/")); XCTAssertFalse(name.contains("\\")); XCTAssertFalse(name.contains(":"))
            XCTAssertLessThanOrEqual(name.utf8.count, 244)
            XCTAssertTrue(name.hasSuffix(".pdf"))
        }
    }
}
