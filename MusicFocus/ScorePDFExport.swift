import PDFKit
import PencilKit
import SwiftUI
import Combine

enum ScorePDFExport {
    /// Keep the score's title while producing a single portable filename. Each
    /// export still lives in its own UUID directory, so originals cannot be replaced.
    static func fileName(for title: String) -> String {
        var stem = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if stem.lowercased().hasSuffix(".pdf") { stem.removeLast(4) }
        let separators = CharacterSet(charactersIn: "/\\:").union(.controlCharacters)
        stem = stem.components(separatedBy: separators).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if stem.isEmpty || stem == "." || stem == ".." { stem = "Score" }
        // File systems bound UTF-8 filename bytes, not Swift character counts.
        // Keep complete characters (including emoji) and leave room for .pdf.
        var bounded = ""
        for character in stem {
            let next = String(character)
            if bounded.utf8.count + next.utf8.count > 240 { break }
            bounded += next
        }
        return (bounded.isEmpty ? "Score" : bounded) + ".pdf"
    }

    /// A byte-for-byte copy of the imported file under its readable title. Live
    /// lessons pair two devices by this file's hash, and every other export
    /// rewrites the PDF, so this is the copy to hand to the other person.
    static func original(source: URL, title: String? = nil) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ScoreExport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(fileName(for: title ?? source.deletingPathExtension().lastPathComponent))
        do { try FileManager.default.copyItem(at: source, to: url) } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        return url
    }

    /// Flatten PencilKit ink into a new PDF; never rewrite the imported original.
    static func create(source: URL, drawings: [Int: Data], title: String? = nil) throws -> URL {
        guard let document = PDFDocument(url: source), document.pageCount > 0 else { throw ScoreLibraryError.invalidPDF }
        // Decode before creating output so damaged ink is never silently omitted.
        let decodedInk = try drawings.mapValues { try PKDrawing(data: $0) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ScoreExport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(fileName(for: title ?? source.deletingPathExtension().lastPathComponent))
        let renderer = UIGraphicsPDFRenderer(bounds: .zero)
        try renderer.writePDF(to: url) { context in
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index) else { continue }
                let crop = page.bounds(for: .cropBox)
                let rotated = page.rotation % 180 != 0
                let size = rotated ? CGSize(width: crop.height, height: crop.width) : crop.size
                let bounds = CGRect(origin: .zero, size: size)
                context.beginPage(withBounds: bounds, pageInfo: [:])
                let cg = context.cgContext
                cg.saveGState()
                cg.translateBy(x: 0, y: size.height)
                cg.scaleBy(x: 1, y: -1)
                if let reference = page.pageRef {
                    cg.concatenate(reference.getDrawingTransform(.cropBox, rect: bounds, rotate: 0, preserveAspectRatio: true))
                    cg.drawPDFPage(reference)
                    for annotation in page.annotations where annotation.shouldDisplay {
                        annotation.draw(with: .cropBox, in: cg)
                    }
                }
                cg.restoreGState()
                if let drawing = decodedInk[index + 1], !drawing.strokes.isEmpty {
                    // Ink is stored in unrotated crop-box coordinates, matching PDFKit's overlay.
                    let scale = min(2, 4096 / max(1, crop.width, crop.height))
                    let image = drawing.image(from: CGRect(origin: .zero, size: crop.size), scale: scale)
                    cg.saveGState()
                    switch (page.rotation % 360 + 360) % 360 {
                    case 90: cg.translateBy(x: size.width, y: 0); cg.rotate(by: .pi / 2)
                    case 180: cg.translateBy(x: size.width, y: size.height); cg.rotate(by: .pi)
                    case 270: cg.translateBy(x: 0, y: size.height); cg.rotate(by: -.pi / 2)
                    default: break
                    }
                    image.draw(in: CGRect(origin: .zero, size: crop.size))
                    cg.restoreGState()
                }
            }
        }
        return url
    }
}
