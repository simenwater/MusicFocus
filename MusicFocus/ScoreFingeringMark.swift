import PencilKit

struct ScoreFingeringMark: Codable, Equatable, Identifiable {
    var id = UUID()
    var strokeIDs: Set<UUID>
    var digit: Int
    var circled: Bool
    var font: ScoreFingeringFont?
    var cover: ScoreFingeringCover?
    var coverStrokeID: UUID?

    init(drawing: PKDrawing, digit: Int, circled: Bool, font: ScoreFingeringFont = .handwritten, cover: ScoreFingeringCover? = nil) {
        strokeIDs = Set(drawing.strokes.map(\.legacyFingeringID))
        self.digit = digit
        self.circled = circled
        self.font = font
        self.cover = cover
        coverStrokeID = cover == nil ? nil : drawing.strokes.first?.legacyFingeringID
    }

    func strokes(in drawing: PKDrawing) -> [PKStroke]? {
        let ink = drawing.strokes.filter { strokeIDs.contains($0.legacyFingeringID) }
        guard !strokeIDs.isEmpty, ink.count == strokeIDs.count, ink.allSatisfy({ $0.mask == nil }) else { return nil }
        return ink
    }

    func glyphStrokes(in drawing: PKDrawing) -> [PKStroke]? {
        strokes(in: drawing)?.filter { $0.legacyFingeringID != coverStrokeID }
    }

    /// A mask edit or late ring reuses the glyph. Undo can therefore restore a
    /// larger group while a newer, smaller history version also looks intact.
    /// Prefer the complete group, then the newest version; never count its
    /// glyph again as a separate plain digit.
    static func active(in drawing: PKDrawing, marks: [Self]) -> [Self] {
        let byID = Dictionary(drawing.strokes.map { ($0.legacyFingeringID, $0) }, uniquingKeysWith: { a, _ in a })
        var claimed = Set<UUID>(), result: [Self] = []
        for (_, mark) in marks.enumerated().sorted(by: {
            $0.element.strokeIDs.count == $1.element.strokeIDs.count ? $0.offset > $1.offset : $0.element.strokeIDs.count > $1.element.strokeIDs.count
        }) {
            guard !mark.strokeIDs.isEmpty, mark.strokeIDs.isDisjoint(with: claimed),
                  mark.strokeIDs.allSatisfy({ byID[$0] != nil && byID[$0]?.mask == nil }) else { continue }
            claimed.formUnion(mark.strokeIDs); result.append(mark)
        }
        return result
    }
}

struct ScoreFingeringSelection: Equatable {
    let page: Int
    let mark: ScoreFingeringMark
}
