import PencilKit

enum ScoreFingeringSizeMode: String, CaseIterable {
    case handwritten, first, fixed

    var title: String { ("score.fingeringSizeMode." + rawValue).localized }
}

/// Size is measured in PDF coordinates, never screen/zoom coordinates. Scaling
/// vector ink keeps colors, proportions, editable PDF export and Undo intact.
enum ScoreFingeringSizing {
    static let enabledKey = "score.fingeringFixedSize.v1"
    static let modeKey = "score.fingeringSizeMode.v1"
    static let fixedHeightKey = "score.fingeringDefaultHeight.v1"
    static let defaultHeight = 12.0
    static let fixedHeightRange = 4.0...48.0

    static func mode(in defaults: UserDefaults) -> ScoreFingeringSizeMode {
        if let raw = defaults.string(forKey: modeKey), let mode = ScoreFingeringSizeMode(rawValue: raw) { return mode }
        return (defaults.object(forKey: enabledKey) as? Bool ?? true) ? .first : .handwritten
    }

    static func fixedHeight(in defaults: UserDefaults) -> Double {
        let height = defaults.double(forKey: fixedHeightKey)
        return fixedHeightRange.contains(height) ? height : defaultHeight
    }
    static func heightKey(scoreID: UUID) -> String { "score.fingeringHeight.v1." + scoreID.uuidString }

    static func digitBounds(_ replacement: ScoreFingeringReplacement) -> CGRect {
        let glyph = replacement.cover == nil ? replacement.drawing.strokes : Array(replacement.drawing.strokes.dropFirst())
        let strokes = replacement.circled ? Array(glyph.dropLast()) : glyph
        return inkBounds(strokes)
    }

    static func inkBounds(_ strokes: [PKStroke]) -> CGRect {
        // PKDrawing.renderBounds rounds to full PDF points and iPadOS 27 may
        // bake transforms into the path. Measure control points and nibs instead,
        // so an 8 pt digit does not acquire a different size after serialization.
        return strokes.reduce(CGRect.null) { bounds, stroke in
            stroke.path.reduce(bounds) { result, point in
                let nib = CGRect(x: point.location.x - point.size.width / 2,
                                 y: point.location.y - point.size.height / 2,
                                 width: point.size.width, height: point.size.height)
                return result.union(nib.applying(stroke.transform))
            }
        }
    }

    static func validHeight(_ height: Double) -> Bool { height.isFinite && height > 0 && height <= 4096 }

    static func apply(_ replacements: [ScoreFingeringReplacement], height: Double?) -> [ScoreFingeringReplacement] {
        var anchor = height.flatMap { validHeight($0) ? $0 : nil }
        return replacements.map { replacement in
            // A circle added around a saved digit must not resize that old digit.
            guard !replacement.preservesDigitSize else { return replacement }
            let bounds = digitBounds(replacement)
            guard validHeight(bounds.height) else { return replacement }
            if anchor == nil { anchor = bounds.height; return replacement }
            guard let anchor else { return replacement }
            let scale = anchor / bounds.height
            guard abs(scale - 1) > 0.00001 else { return replacement }
            let whole = replacement.drawing.bounds
            let drawing = replacement.drawing.transformed(using: CGAffineTransform(
                a: scale, b: 0, c: 0, d: scale,
                tx: whole.midX * (1 - scale), ty: whole.midY * (1 - scale)))
            return .init(sourceIDs: replacement.sourceIDs, drawing: drawing, digit: replacement.digit,
                         circled: replacement.circled, font: replacement.font,
                         preservesDigitSize: replacement.preservesDigitSize, cover: replacement.cover)
        }
    }
}
