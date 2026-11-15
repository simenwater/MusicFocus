import CoreText
import PencilKit

enum ScoreFingeringFont: String, CaseIterable, Codable, Sendable {
    case handwritten, timesNewRoman
    static let defaultsKey = "score.fingeringFont.v1"
    static func saved(in defaults: UserDefaults = .standard) -> Self {
        Self(rawValue: defaults.string(forKey: defaultsKey) ?? "") ?? .handwritten
    }
    var title: String {
        self == .timesNewRoman ? "Times New Roman" : "score.fingeringFont.handwritten".localized
    }
}

/// Filled system-font outlines converted to ordinary vector ink. Keeping these
/// as unmasked PencilKit strokes preserves the existing eraser/history/export
/// path on iPadOS 26, without baking text into a bitmap or changing the PDF.
enum ScoreFingeringFontInk {
    private struct Span {
        let left: CGFloat
        let right: CGFloat
        let y: CGFloat
        var links: [Int] = []
    }
    private static let templates: [[CGPoint]] = (0...9).map { digit in
        guard let outline = outline(digit: digit) else { return [] }
        return fillPath(outline)
    }

    static func outline(digit: Int) -> CGPath? {
        let font = CTFontCreateWithName("TimesNewRomanPSMT" as CFString, 200, nil)
        guard CTFontCopyPostScriptName(font) as String == "TimesNewRomanPSMT" else { return nil }
        var character = UniChar(48 + digit), glyph: CGGlyph = 0
        guard CTFontGetGlyphsForCharacters(font, &character, &glyph, 1),
              let path = CTFontCreatePathForGlyph(font, glyph, nil) else { return nil }
        let box = path.boundingBoxOfPath, scale = 128 / box.height
        var transform = CGAffineTransform(a: scale, b: 0, c: 0, d: -scale,
                                         tx: -box.minX * scale, ty: box.maxY * scale)
        return path.copy(using: &transform)
    }

    static func render(digit: Int, target: CGRect, style: PKStroke) -> [PKStroke]? {
        guard templates.indices.contains(digit), !templates[digit].isEmpty,
              target.width > 0, target.height > 0,
              [target.minX, target.minY, target.width, target.height].allSatisfy(\.isFinite) else { return nil }
        // One continuous, overlapping fill stroke, with a single alpha blend.
        // Repeat corners so older PencilKit's B-spline does not round away the serifs.
        // PencilKit drops sub-point nibs before applying the stroke transform.
        // Build at a comfortably large native scale, then fit in page coordinates.
        let locations = templates[digit].flatMap { p -> [CGPoint] in
            let point = CGPoint(x: p.x * 8, y: p.y * 8)
            return [point, point, point]
        }
        let opacity = min(0.9999847409781033, max(0.1, style.path.first?.opacity ?? 1))
        let points = locations.enumerated().map { index, p in
            PKStrokePoint(location: p, timeOffset: Double(index) * 0.001,
                          size: CGSize(width: 8.8, height: 8.8), opacity: opacity,
                          force: 1, azimuth: 0, altitude: .pi / 2)
        }
        let stroke = PKStroke(ink: PKInk(.monoline, color: style.ink.color),
                              path: PKStrokePath(controlPoints: points, creationDate: Date()))
        let drawing = PKDrawing(strokes: [stroke]), box = drawing.bounds
        guard box.width > 0, box.height > 0 else { return nil }
        // Keep the font designer's proportions even when the handwritten input
        // is very wide or narrow. Only its center and height set the placement.
        let scale = target.height / box.height
        return drawing.transformed(using: CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
            tx: target.midX - box.midX * scale, ty: target.midY - box.midY * scale)).strokes
    }

    /// Join overlapping scan lines inside the glyph into a continuous vector
    /// fill. Core Text supplies the actual glyph geometry, including the hole in 4.
    private static func fillPath(_ outline: CGPath) -> [CGPoint] {
        var edges: [(CGPoint, CGPoint)] = []
        var current = CGPoint.zero, start = CGPoint.zero
        func mix(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
            CGPoint(x: a.x + (b.x-a.x)*t, y: a.y + (b.y-a.y)*t)
        }
        outline.applyWithBlock { pointer in
            let e = pointer.pointee, from = current
            func add(_ p: CGPoint) { edges.append((current, p)); current = p }
            switch e.type {
            case .moveToPoint: current = e.points[0]; start = current
            case .addLineToPoint: add(e.points[0])
            case .closeSubpath: add(start)
            case .addQuadCurveToPoint:
                for i in 1...32 {
                    let t = CGFloat(i)/32
                    add(mix(mix(from,e.points[0],t),mix(e.points[0],e.points[1],t),t))
                }
            case .addCurveToPoint:
                for i in 1...32 {
                    let t = CGFloat(i)/32
                    add(mix(mix(mix(from,e.points[0],t),mix(e.points[0],e.points[1],t),t),
                            mix(mix(e.points[0],e.points[1],t),mix(e.points[1],e.points[2],t),t),t))
                }
            @unknown default: break
            }
        }
        var spans: [Span] = [], previous: [Int] = []
        for y in stride(from: CGFloat(0.25), to: 128, by: 0.5) {
            let xs = edges.compactMap { a, b -> CGFloat? in
                guard (a.y <= y && b.y > y) || (b.y <= y && a.y > y) else { return nil }
                return a.x + (y-a.y) * (b.x-a.x) / (b.y-a.y)
            }.sorted()
            var row: [Int] = []
            for i in stride(from: 0, to: xs.count-1, by: 2) {
                let index = spans.count
                let span = Span(left: xs[i], right: xs[i+1], y: y)
                let links = previous.filter { min(spans[$0].right,span.right) >= max(spans[$0].left,span.left) }
                spans.append(span); spans[index].links = links
                for other in links { spans[other].links.append(index) }
                row.append(index)
            }
            previous = row
        }
        guard let first = spans.indices.first else { return [] }
        var visited = Set<Int>(), points: [CGPoint] = []
        func walk(_ index: Int, entering x: CGFloat) {
            visited.insert(index)
            let span = spans[index], entry = CGPoint(x: x, y: span.y)
            points += [entry, CGPoint(x: span.left, y: span.y), CGPoint(x: span.right, y: span.y), entry]
            for other in span.links where !visited.contains(other) {
                let next = spans[other]
                let bridge = (max(span.left,next.left) + min(span.right,next.right))/2
                points.append(CGPoint(x: bridge, y: span.y))
                walk(other, entering: bridge)
                points.append(CGPoint(x: bridge, y: span.y))
            }
            points.append(entry)
        }
        walk(first, entering: spans[first].left)
        // Fail closed if the font unexpectedly has disconnected components.
        return visited.count == spans.count ? points : []
    }
}
