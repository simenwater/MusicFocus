import PencilKit

/// Optional, reversible whiteout under a fingering. It is ordinary vector ink,
/// so the original PDF remains intact and the existing backup/export path works.
struct ScoreFingeringCover: Codable, Equatable, Sendable {
    var color = ScoreAnnotationColor(.white)
    var padding = 1.5
    static let enabledKey = "score.fingeringCover.enabled.v1"
    static let styleKey = "score.fingeringCover.style.v1"
    static let paddingRange = 0.0...12.0

    var validated: Self {
        var result = self
        result.padding = padding.isFinite ? min(12, max(0, padding)) : 1.5
        func channel(_ value: Double) -> Double { value.isFinite ? min(1, max(0, value)) : 1 }
        result.color.red = channel(color.red); result.color.green = channel(color.green); result.color.blue = channel(color.blue)
        return result
    }

    static func saved(in defaults: UserDefaults) -> Self {
        guard let data = defaults.data(forKey: styleKey), let value = try? JSONDecoder().decode(Self.self, from: data) else { return .init() }
        return value.validated
    }

    func applying(to replacement: ScoreFingeringReplacement) -> ScoreFingeringReplacement {
        let style = validated
        let glyph = replacement.cover == nil ? replacement.drawing.strokes : Array(replacement.drawing.strokes.dropFirst())
        let bounds = ScoreFingeringSizing.inkBounds(glyph)
        let digit = ScoreFingeringSizing.digitBounds(replacement)
        guard bounds.width > 0, bounds.height > 0, bounds.height.isFinite,
              bounds.width.isFinite else { return replacement }
        // A narrow 1 must still cover a wider printed finger number at the same
        // location. Padding is in PDF points, independent of viewport zoom.
        let width = max(bounds.width, digit.height * 0.8) + style.padding * 2
        let height = bounds.height + style.padding * 2
        let target = CGRect(x: bounds.midX-width/2, y: bounds.midY-height/2, width: width, height: height)
        let cover = Self.stroke(in: target, color: style.color.uiColor)
        return .init(sourceIDs: replacement.sourceIDs, drawing: PKDrawing(strokes: [cover] + glyph),
                     digit: replacement.digit, circled: replacement.circled, font: replacement.font,
                     preservesDigitSize: replacement.preservesDigitSize, cover: style)
    }

    private static func stroke(in rect: CGRect, color: UIColor) -> PKStroke {
        // A small continuous scan-line fill with overlapping opaque monoline
        // nibs. One erasable stroke; no image tiles or per-frame rasterization.
        let scale: CGFloat = 8
        let width = rect.width * scale, height = rect.height * scale
        let nib: CGFloat = min(max(8, height / 128), min(width, height) / 4)
        let rows = max(2, Int(ceil((height - nib) / (nib * 0.65))))
        var locations: [CGPoint] = []
        for row in 0...rows {
            let y = nib/2 + (height-nib) * CGFloat(row) / CGFloat(rows)
            let ends = row.isMultiple(of: 2) ? [nib/2, width-nib/2] : [width-nib/2, nib/2]
            for x in ends { locations += Array(repeating: CGPoint(x: x, y: y), count: 3) }
        }
        let points = locations.enumerated().map { index, point in
            PKStrokePoint(location: point, timeOffset: Double(index)*0.001, size: CGSize(width: nib, height: nib),
                          opacity: 1, force: 1, azimuth: 0, altitude: .pi/2)
        }
        return PKStroke(ink: PKInk(.monoline, color: color), path: PKStrokePath(controlPoints: points, creationDate: Date()),
                        transform: CGAffineTransform(a: 1/scale, b: 0, c: 0, d: 1/scale, tx: rect.minX, ty: rect.minY))
    }
}
