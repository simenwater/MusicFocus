import PDFKit

/// A reversible, opaque PDF square. Coordinates belong to the PDF crop box,
/// not the screen, so moving/zooming never changes the saved geometry.
struct ScorePageCover: Codable, Equatable, Identifiable {
    var id = UUID()
    var page: Int
    var bounds: CGRect
    var color = ScoreAnnotationColor(.white)

    var isValid: Bool {
        page > 0 && [bounds.origin.x, bounds.origin.y, bounds.size.width, bounds.size.height].allSatisfy { $0.isFinite && abs($0) < 1_000_000 }
        && bounds.size.width >= 2 && bounds.size.height >= 2
        && [color.red, color.green, color.blue].allSatisfy { $0.isFinite && (0...1).contains($0) }
    }

    func constrained(to crop: CGRect) -> Self {
        var result = self
        let width = min(crop.width, max(2, bounds.width)), height = min(crop.height, max(2, bounds.height))
        result.bounds = CGRect(x: min(crop.maxX-width, max(crop.minX, bounds.minX)),
                               y: min(crop.maxY-height, max(crop.minY, bounds.minY)), width: width, height: height)
        return result
    }

    func annotation() -> PDFAnnotation {
        let annotation = PDFAnnotation(bounds: bounds, forType: .square, withProperties: nil)
        let border = PDFBorder(); border.lineWidth = 0
        annotation.border = border
        annotation.color = color.uiColor
        annotation.interiorColor = color.uiColor
        annotation.shouldPrint = true
        annotation.userName = "MusicFocus"
        annotation.setValue("MusicFocusCover:" + id.uuidString, forAnnotationKey: PDFAnnotationKey(rawValue: "/NM"))
        return annotation
    }
}
