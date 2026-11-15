import PencilKit
import CryptoKit

extension PKStroke {
    /// Earlier PencilKit versions do not expose stroke UUIDs. Use a stable,
    /// content-derived identity, including creation time, for recent-ink tracking.
    var fingeringID: UUID {
        if #available(iOS 27.0, *) { return id }
        return legacyFingeringID
    }

    var legacyFingeringID: UUID {
        var data = Data()
        func append(_ value: Double) {
            // PencilKit quantizes some fields on serialization. Sub-millipoint
            // rounding keeps identity stable across saving, undo and reloading.
            var bits = ((value * 1000).rounded() / 1000).bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        append(path.creationDate.timeIntervalSinceReferenceDate)
        append(Double(path.count))
        // Bound this work: the controller checks identity for the whole page.
        // Creation time plus a sampled path distinguishes strokes without
        // hashing every pen point on a heavily annotated score.
        let count = min(16, path.count)
        for index in 0..<count {
            let p = path[count > 1 ? index * (path.count - 1) / (count - 1) : 0]
            for v in [p.location.x, p.location.y] { append(Double(v)) }
            append(p.timeOffset)
        }
        // A move or recolor is the same stroke, not newly written fingering ink.
        let bytes = Array(SHA256.hash(data: data).prefix(16))
        return bytes.withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
    }
}

struct ScoreFingeringReplacement: Sendable {
    let sourceIDs: Set<UUID>
    let drawing: PKDrawing
    let digit: Int
    let circled: Bool
    var font: ScoreFingeringFont = .handwritten
    var preservesDigitSize = false
    var cover: ScoreFingeringCover? = nil
}
typealias ScoreFingeringRecognition = @Sendable ([PKStroke], Set<UUID>) async -> [ScoreFingeringReplacement]

enum ScoreFingeringService {
    static var usesAppleHandwriting: Bool {
        if #available(iOS 27.0, *) {
            return ScoreAppleDigitRecognizer.isSupported && ScoreDigitRecognizer.hasAppleCalibration
        }
        return false
    }
    static func recognize(_ strokes: [PKStroke], _ newIDs: Set<UUID>) async -> [ScoreFingeringReplacement] {
        await ScoreFingeringBeautifier.recognize(strokes: strokes, newIDs: newIDs)
    }
}

/// Only the caller's recent ink is eligible. Printed music and imported annotations
/// never enter recognition. The output remains ordinary, editable PencilKit ink.
enum ScoreFingeringBeautifier {
    typealias Replacement = ScoreFingeringReplacement
    private typealias AppleRecognition = @Sendable ([PKStroke]) async -> String?

    static func recognize(strokes: [PKStroke], newIDs: Set<UUID>, fingeringOnly: Bool = false, font: ScoreFingeringFont = .handwritten) async -> [Replacement] {
        guard !Task.isCancelled, !newIDs.isEmpty, strokes.count <= 24 else { return [] }
        let apple: AppleRecognition?
        if #available(iOS 27.0, *), ScoreFingeringService.usesAppleHandwriting {
            let recognizer = ScoreAppleDigitRecognizer()
            apple = { await recognizer.recognize($0) }
        } else { apple = nil }
        var replacements: [Replacement] = []
        for group in groups(strokes) where group.contains(where: { newIDs.contains($0.fingeringID) }) {
            guard !Task.isCancelled else { return [] }
            // Closed vocabulary always has a winner, so split adjacent numbers
            // before classifying, rather than letting a whole row become one digit.
            if fingeringOnly {
                let parts = separatedGroups(group)
                if candidate(group)?.circle == nil && isHorizontalRow(parts) {
                    for part in parts where part.contains(where: { newIDs.contains($0.fingeringID) }) {
                        if let result = await replacement(part, apple: apple, fingeringOnly: true, font: font) { replacements.append(result) }
                    }
                    continue
                }
            }
            if let whole = await replacement(group, apple: apple, fingeringOnly: fingeringOnly, font: font) {
                replacements.append(whole)
                continue
            }
            // A coarse group may join neighboring numbers through invisible nib
            // margins. Split only a horizontal row where EVERY part is a clear
            // digit. Never extract one plausible digit from an unknown clef,
            // letter or dotted mark and silently leave the other parts behind.
            let parts = separatedGroups(group)
            guard isHorizontalRow(parts) else { continue }
            var recognized: [Replacement] = []
            for part in parts {
                guard !Task.isCancelled else { return [] }
                guard let result = await replacement(part, apple: apple, fingeringOnly: fingeringOnly, font: font) else { break }
                recognized.append(result)
            }
            guard recognized.count == parts.count else { continue }
            replacements += recognized.filter { !$0.sourceIDs.isDisjoint(with: newIDs) }
        }
        return Task.isCancelled ? [] : replacements
    }

    private static func replacement(_ group: [PKStroke], apple: AppleRecognition?, fingeringOnly: Bool = false, font: ScoreFingeringFont) async -> Replacement? {
        guard !Task.isCancelled, let candidate = candidate(group) else { return nil }
        let paths = candidate.digits.map { samples($0, count: max(64, min(256, $0.path.count * 2))) }
        var recognized: Int?
        if fingeringOnly {
            // A ring written first waits for its number; never turn an empty
            // enclosing circle into a numeral while the user is still composing.
            if group.count == 1 && isCircle(group[0]) { return nil }
            let text = await apple?(candidate.digits)
            recognized = ScoreDigitRecognizer.fingerDigit(paths: paths, appleText: text)
        } else if let apple {
            let text = await apple(candidate.digits)
            guard !Task.isCancelled else { return nil }
            recognized = ScoreDigitRecognizer.resolveAppleText(text, paths: paths)
            if recognized == nil,
               let retry = detachedCapRetry(candidate.digits, text: text, paths: paths) {
                // Recheck a detached crossbar in a temporary recognition copy.
                // Never strip punctuation and accept the trailing digit alone.
                let confirmed = await apple(retry)
                guard !Task.isCancelled else { return nil }
                recognized = ScoreDigitRecognizer.resolveAppleText(confirmed, paths: paths)
            }
        } else { recognized = ScoreDigitRecognizer.recognize(paths: paths) }
        guard let digit = recognized, !Task.isCancelled,
              let clean = render(digit: digit, from: candidate.digits, circle: candidate.circle, font: font) else { return nil }
        return .init(sourceIDs: Set(group.map(\.fingeringID)), drawing: clean,
                     digit: digit, circled: candidate.circle != nil, font: font)
    }

    private static func isHorizontalRow(_ groups: [[PKStroke]]) -> Bool {
        guard groups.count > 1 else { return false }
        let boxes = groups.map { bounds($0.flatMap { samples($0) }) }.sorted { $0.minX < $1.minX }
        guard let minHeight = boxes.map(\.height).min(), minHeight > 0,
              boxes.allSatisfy({ $0.height <= minHeight*2 }) else { return false }
        return zip(boxes, boxes.dropFirst()).allSatisfy {
            $1.minX > $0.maxX && abs($1.midY-$0.midY) < minHeight*0.4
        }
    }

    static func digit(_ text: String) -> Int? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count == 1, let scalar = value.unicodeScalars.first,
              (48...57).contains(scalar.value) else { return nil }
        return Int(scalar.value - 48)
    }

    private struct Candidate {
        let digits: [PKStroke]
        let circle: PKStroke?
    }

    private static func candidate(_ strokes: [PKStroke]) -> Candidate? {
        guard (1...5).contains(strokes.count), strokes.allSatisfy({
            $0.mask == nil && [.pen, .monoline].contains($0.ink.inkType) && (2...1600).contains($0.path.count)
        }) else { return nil }
        // These are PDF points: a clearly visible number at high reading zoom
        // may be only a few points tall. Shape rejection below is scale invariant.
        let total = PKDrawing(strokes: strokes).bounds
        guard total.width.isFinite, total.height.isFinite,
              (1...140).contains(total.height), (0.05...140).contains(total.width) else { return nil }
        for ring in strokes where isCircle(ring) && strokes.count > 1 {
            let inside = strokes.filter { $0.fingeringID != ring.fingeringID }
            // Judge containment by pen paths, not padded nib/render bounds.
            // A tightly drawn ring can touch the digit's ink envelope.
            let inner = bounds(inside.flatMap { samples($0) })
            let outer = bounds(samples(ring))
            let inset = outer.insetBy(dx: outer.width * 0.01, dy: outer.height * 0.01)
            if inset.contains(inner), inner.height < outer.height * 0.96,
               inner.height > outer.height * 0.23, sameStyle(inside) {
                return .init(digits: inside, circle: ring)
            }
        }
        guard strokes.count <= 4, sameStyle(strokes) else { return nil }
        return .init(digits: strokes, circle: nil)
    }

    /// Overlapping strokes form one symbol (including a surrounding circle).
    /// Adjacent finger numbers remain separate; long text is rejected as a group.
    private static func groups(_ strokes: [PKStroke]) -> [[PKStroke]] {
        var groups: [[PKStroke]] = []
        for stroke in strokes {
            var merged = [stroke]
            var remaining: [[PKStroke]] = []
            for group in groups {
                if group.contains(where: { $0.renderBounds.insetBy(dx: -1, dy: -1).intersects(stroke.renderBounds) ||
                    detachedTopBar($0, stroke) || detachedTopBar(stroke, $0) || coarseRelatedMark($0, stroke) }) {
                    merged += group
                } else { remaining.append(group) }
            }
            groups = remaining + [merged]
        }
        return groups.map { $0.sorted { $0.path.creationDate < $1.path.creationDate } }
    }

    private static func coarseRelatedMark(_ lhs: PKStroke, _ rhs: PKStroke) -> Bool {
        let a = lhs.renderBounds, b = rhs.renderBounds
        let xGap = max(0, max(a.minX,b.minX)-min(a.maxX,b.maxX))
        let yGap = max(0, max(a.minY,b.minY)-min(a.maxY,b.maxY))
        let overlap = min(a.maxX,b.maxX)-max(a.minX,b.minX)
        let height = max(a.height,b.height)
        if overlap > min(a.width,b.width)*0.3 && abs(a.midY-b.midY) > height*0.45 && yGap < height*0.9 {
            return true
        }
        return min(a.height,b.height) < height*0.5 && xGap < height*0.5 && yGap < height*0.4
    }

    private static func separatedGroups(_ strokes: [PKStroke]) -> [[PKStroke]] {
        // PencilKit's render bounds include nib/antialiasing padding. On small
        // finger numbers those invisible margins overlap the next number. Use
        // the center paths for grouping, with a small absolute joining tolerance.
        struct Item {
            let stroke: PKStroke
            let box: CGRect
        }
        let items = strokes.map { Item(stroke: $0, box: bounds(samples($0, count: 64))) }
        var groups: [[Item]] = []
        for item in items {
            var merged = [item]
            var remaining: [[Item]] = []
            for group in groups {
                if group.contains(where: {
                    $0.box.insetBy(dx: -0.5, dy: -0.5).intersects(item.box) ||
                    ($0.stroke.ink.color.isEqual(item.stroke.ink.color) &&
                        (topBarGap($0.box, item.box) != nil || topBarGap(item.box, $0.box) != nil)) ||
                    relatedMark($0.box, item.box)
                }) {
                    merged += group
                } else { remaining.append(group) }
            }
            groups = remaining + [merged]
        }
        return groups.map { $0.map(\.stroke).sorted { $0.path.creationDate < $1.path.creationDate } }
    }

    /// Keep stacked time signatures, accents and detached dots with their
    /// symbol. Classifying their pieces separately can turn a clef into 9 or a
    /// question mark into a finger number. Same-height neighboring digits stay
    /// separate; uncertain vertical clusters remain handwritten.
    private static func relatedMark(_ a: CGRect, _ b: CGRect) -> Bool {
        let xGap = max(0, max(a.minX,b.minX)-min(a.maxX,b.maxX))
        let yGap = max(0, max(a.minY,b.minY)-min(a.maxY,b.maxY))
        let overlap = min(a.maxX,b.maxX)-max(a.minX,b.minX)
        let height = max(a.height,b.height)
        if overlap > min(a.width,b.width)*0.3 && abs(a.midY-b.midY) > height*0.45 && yGap < height*0.9 {
            return true
        }
        // A detached dot/cap must share the symbol's horizontal footprint.
        // A short stroke beside a tall one may belong to the NEXT number.
        return min(a.height,b.height) < height*0.5 && xGap <= 0.25 && yGap < height*0.4
    }

    /// A top bar of 5 or 7 may stop just short of the next stroke. Only bridge
    /// a small vertical gap with substantial horizontal overlap, never neighbors.
    private static func topBarGap(_ bar: CGRect, _ body: CGRect) -> CGFloat? {
        let gap = body.minY - bar.maxY
        let overlap = min(bar.maxX, body.maxX) - max(bar.minX, body.minX)
        guard body.height >= 4, bar.width > 0,
              bar.height <= max(0.5, body.height * 0.08),
              bar.width >= body.width * 0.6,
              overlap >= min(bar.width, body.width) * 0.6,
              gap > 0.5, gap <= body.height * 0.25 else { return nil }
        return gap
    }

    private static func detachedTopBar(_ bar: PKStroke, _ body: PKStroke) -> Bool {
        guard bar.ink.color.isEqual(body.ink.color) else { return false }
        return topBarGap(bounds(samples(bar)), bounds(samples(body))) != nil
    }

    /// Apple can read a separated top bar as "/5". Retry only when the local
    /// model also supports 5/7 and the two paths meet the existing cap geometry.
    /// The stored ink and the bounds used for beautification remain unchanged.
    static func detachedCapRetry(_ strokes: [PKStroke], text: String?, paths: [[CGPoint]]) -> [PKStroke]? {
        guard strokes.count == 2, let text else { return nil }
        let scalars = Array(text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
        let digits = scalars.filter { (48...57).contains($0.value) }
        guard (2...4).contains(scalars.count), digits.count == 1,
              [53, 55].contains(digits[0].value),
              scalars.allSatisfy({ $0 == digits[0] || "/\\-_¯‾".unicodeScalars.contains($0) }),
              ScoreDigitRecognizer.recognize(paths: paths) == Int(digits[0].value-48) else { return nil }
        for bar in 0...1 {
            let body = 1-bar
            guard let gap = topBarGap(bounds(samples(strokes[bar])), bounds(samples(strokes[body]))) else { continue }
            var adjusted = strokes
            adjusted[bar].transform = adjusted[bar].transform.concatenating(CGAffineTransform(translationX: 0, y: gap))
            return adjusted
        }
        return nil
    }

    private static func sameStyle(_ strokes: [PKStroke]) -> Bool {
        guard let first = strokes.first else { return false }
        return strokes.allSatisfy { $0.ink.color.isEqual(first.ink.color) }
    }

    static func samples(_ stroke: PKStroke, count: Int = 48) -> [CGPoint] {
        guard stroke.path.count > 1 else { return [] }
        return (0..<count).map { index in
            stroke.path.interpolatedLocation(at: CGFloat(index) * CGFloat(stroke.path.count - 1) / CGFloat(count - 1))
                .applying(stroke.transform)
        }
    }

    static func isCircle(_ stroke: PKStroke) -> Bool {
        let points = samples(stroke, count: 64)
        guard let first = points.first, let last = points.last else { return false }
        let box = bounds(points)
        guard box.width > 1, box.height > 1, (0.45...1.8).contains(box.width / box.height),
              hypot(first.x-last.x, first.y-last.y) < max(box.width, box.height) * 0.25 else { return false }
        let normalized = points.map { CGPoint(x: ($0.x-box.midX)/(box.width/2), y: ($0.y-box.midY)/(box.height/2)) }
        guard normalized.allSatisfy({ (0.65...1.3).contains(hypot($0.x, $0.y)) }) else { return false }
        var sweep = 0.0, travel = 0.0
        for (a, b) in zip(normalized, normalized.dropFirst()) {
            var angle = atan2(b.y, b.x) - atan2(a.y, a.x)
            if angle > .pi { angle -= 2 * .pi }
            if angle < -.pi { angle += 2 * .pi }
            sweep += angle; travel += abs(angle)
        }
        return abs(sweep) > 5.3 && travel < 7.6 && abs(sweep) / max(travel, 0.01) > 0.9
    }

    private static func bounds(_ points: [CGPoint]) -> CGRect {
        points.reduce(CGRect.null) { $0.union(CGRect(x: $1.x, y: $1.y, width: 0, height: 0)) }
    }
    static func render(digit: Int, from strokes: [PKStroke], circle: PKStroke? = nil, targetBounds: CGRect? = nil, font: ScoreFingeringFont = .handwritten) -> PKDrawing? {
        guard (0...9).contains(digit), let first = strokes.first else { return nil }
        let original = PKDrawing(strokes: strokes)
        let paths = variants(digit)[0]
        let target = targetBounds ?? original.bounds
        guard target.width > 0, target.height > 0,
              [target.minX, target.minY, target.width, target.height].allSatisfy(\.isFinite) else { return nil }
        var clean: [PKStroke]
        if font == .timesNewRoman {
            guard let rendered = ScoreFingeringFontInk.render(digit: digit, target: target, style: first) else { return nil }
            clean = rendered
        } else { clean = fitted(paths: paths, to: target, style: first) }
        if let circle { return addingCircle(to: clean, style: circle) }
        return PKDrawing(strokes: clean)
    }

    /// Adding a ring must not redraw or subtly resize an existing digit.
    static func addingCircle(to strokes: [PKStroke], style: PKStroke) -> PKDrawing {
        var clean = strokes
        if !clean.isEmpty {
            let ellipse = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 1, height: 1), transform: nil)
            // Fit the ring to the normalized digit, not the user's oversized
            // oval. A diagonal-sized circle encloses all corners with a little
            // breathing room. Use the ring's color/opacity with a light nib.
            let box = ScoreFingeringSizing.inkBounds(clean)
            let diameter = hypot(box.width, box.height) + box.height * 0.16
            let target = CGRect(x: box.midX - diameter / 2, y: box.midY - diameter / 2,
                                width: diameter, height: diameter)
            clean += fitted(paths: [ellipse], to: target, style: style, pageWidthLimit: box.height * 0.045)
        }
        return PKDrawing(strokes: clean)
    }

    private static func fitted(paths: [CGPath], to target: CGRect, style: PKStroke, pageWidthLimit: CGFloat? = nil) -> [PKStroke] {
        let widths = style.path.map { max($0.size.width, $0.size.height) }.sorted()
        guard !widths.isEmpty else { return [] }
        // Build the canonical glyph at a stable native size so tiny fingerings
        // still have a drawable PencilKit nib. Account for existing stroke scale
        // when a corrected digit or a late circle reuses generated ink.
        let nativeHeight: CGFloat = 128
        let pageWidth = min(widths[widths.count / 2] * hypot(style.transform.c, style.transform.d), pageWidthLimit ?? .infinity)
        let width = min(32, max(3, pageWidth * nativeHeight / target.height))
        let opacity = min(1, max(0.1, style.path.map(\.opacity).reduce(0,+) / CGFloat(style.path.count)))
        let pathsBounds = paths.reduce(CGRect.null) { $0.union($1.boundingBoxOfPath) }
        guard pathsBounds.height > 0 else { return [] }
        let pathScale = nativeHeight / pathsBounds.height
        var transform = CGAffineTransform(a: pathScale, b: 0, c: 0, d: pathScale,
            tx: -pathsBounds.midX * pathScale, ty: -pathsBounds.midY * pathScale)
        let drawing = PKDrawing(strokes: paths.compactMap { path in
            path.copy(using: &transform).map { path in
                var result = stroke(path: path, color: style.ink.color, width: width, opacity: opacity)
                result.ink = style.ink
                return result
            }
        })
        let box = drawing.bounds
        guard box.width > 0, box.height > 0 else { return [] }
        // Handwriting determines the center and height, never the glyph's aspect
        // ratio. One scale also keeps a hand-drawn oval's replacement circular.
        let scale = target.height / box.height
        return drawing.transformed(using: CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
            tx: target.midX - box.midX * scale, ty: target.midY - box.midY * scale)).strokes
    }

    private static func stroke(path: CGPath, color: UIColor, width: CGFloat, opacity: CGFloat, legacyPath: Bool = false) -> PKStroke {
        func point(_ location: CGPoint, _ index: Int) -> PKStrokePoint {
            PKStrokePoint(location: location, timeOffset: Double(index)*0.01,
                          size: CGSize(width: width, height: width), opacity: min(0.9999847409781033,opacity),
                          force: 1, azimuth: 0, altitude: .pi/2)
        }
        let strokePath: PKStrokePath
        if #available(iOS 27.0, *), !legacyPath {
            strokePath = PKStrokePath(bezierPath: path, creationDate: Date()) { point($0.location, $0.index) }
        } else {
            // Earlier systems can build editable strokes from sampled control
            // points. Dense Bézier sampling keeps the same vector glyph outline.
            strokePath = PKStrokePath(controlPoints: bezierPoints(path).enumerated().map { point($0.element, $0.offset) }, creationDate: Date())
        }
        return PKStroke(ink: PKInk(.pen, color: color), path: strokePath)
    }

    private static func bezierPoints(_ path: CGPath) -> [CGPoint] {
        var points: [CGPoint] = [], current = CGPoint.zero, start = CGPoint.zero
        func mix(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
            CGPoint(x: a.x+(b.x-a.x)*t, y: a.y+(b.y-a.y)*t)
        }
        path.applyWithBlock { pointer in
            let e = pointer.pointee
            let from = current
            switch e.type {
            case .moveToPoint:
                current = e.points[0]; start = current; points.append(current)
            case .addLineToPoint, .closeSubpath:
                let end = e.type == .closeSubpath ? start : e.points[0]
                for i in 1...32 { points.append(mix(from, end, CGFloat(i)/32)) }
                current = end
            case .addQuadCurveToPoint:
                let c = e.points[0], end = e.points[1]
                for i in 1...32 {
                    let t = CGFloat(i)/32
                    points.append(mix(mix(from,c,t),mix(c,end,t),t))
                }
                current = end
            case .addCurveToPoint:
                let c1 = e.points[0], c2 = e.points[1], end = e.points[2]
                for i in 1...32 {
                    let t = CGFloat(i)/32
                    points.append(mix(mix(mix(from,c1,t),mix(c1,c2,t),t),mix(mix(c1,c2,t),mix(c2,end,t),t),t))
                }
                current = end
            @unknown default: break
            }
        }
        return points
    }

    // Small, hand-designed monoline glyphs. No font license or generative service.
    static func variants(_ digit: Int) -> [[CGPath]] {
        let p = CGMutablePath()
        switch digit {
        case 0: p.addEllipse(in: CGRect(x: 0, y: 0, width: 0.65, height: 1))
        case 1: return [[line([(0.08,0.18),(0.3,0),(0.3,1)]), line([(0.05,1),(0.55,1)])],
                       [line([(0.5,0),(0.5,1)])], [line([(0,0.2),(0.3,0),(0.3,1)])]]
        case 2:
            p.move(to: CGPoint(x: 0, y: 0.2)); p.addCurve(to: CGPoint(x: 0.62,y: 0.25), control1: CGPoint(x: 0.08,y: -0.12), control2: CGPoint(x: 0.65,y: -0.08))
            p.addCurve(to: CGPoint(x: 0,y: 1), control1: CGPoint(x: 0.65,y: 0.5), control2: CGPoint(x: 0.1,y: 0.75)); p.addLine(to: CGPoint(x: 0.68,y: 1))
        case 3:
            p.move(to: CGPoint(x: 0,y: 0.08)); p.addCurve(to: CGPoint(x: 0.15,y: 0.48), control1: CGPoint(x: 0.85,y: -0.2), control2: CGPoint(x: 0.82,y: 0.5))
            p.addCurve(to: CGPoint(x: 0,y: 0.92), control1: CGPoint(x: 0.9,y: 0.35), control2: CGPoint(x: 0.87,y: 1.25))
        case 4: return [[line([(0.38,0),(0,0.66),(0.72,0.66)]),line([(0.52,0.12),(0.52,1)])],
                       [line([(0.55,1),(0.55,0),(0,0.66),(0.75,0.66)])]]
        case 5:
            p.move(to: CGPoint(x: 0.62,y: 0)); p.addLine(to: CGPoint(x: 0.06,y: 0)); p.addLine(to: CGPoint(x: 0,y: 0.48))
            p.addCurve(to: CGPoint(x: 0,y: 0.94), control1: CGPoint(x: 0.9,y: 0.2), control2: CGPoint(x: 0.9,y: 1.3))
        case 6:
            p.move(to: CGPoint(x: 0.55,y: 0)); p.addCurve(to: CGPoint(x: 0.02,y: 0.75), control1: CGPoint(x: 0.1,y: 0.15), control2: CGPoint(x: -0.05,y: 0.4))
            p.addCurve(to: CGPoint(x: 0.58,y: 0.76), control1: CGPoint(x: 0.08,y: 1.1), control2: CGPoint(x: 0.59,y: 1.1))
            p.addCurve(to: CGPoint(x: 0.03,y: 0.65), control1: CGPoint(x: 0.65,y: 0.38), control2: CGPoint(x: 0.1,y: 0.35))
        case 7: return [[line([(0,0),(0.65,0),(0.18,1)])],
                       [line([(0,0),(0.65,0),(0.18,1)]),line([(0.12,0.5),(0.6,0.5)])]]
        case 8:
            p.move(to: CGPoint(x: 0.3,y: 0.47))
            p.addCurve(to: CGPoint(x: 0.3,y: 0.47), control1: CGPoint(x: -0.65,y: -0.17), control2: CGPoint(x: 1.25,y: -0.17))
            p.addCurve(to: CGPoint(x: 0.3,y: 0.47), control1: CGPoint(x: -0.75,y: 1.22), control2: CGPoint(x: 1.35,y: 1.22))
        case 9:
            p.move(to: CGPoint(x: 0.58,y: 0.32))
            p.addCurve(to: CGPoint(x: 0.02,y: 0.25), control1: CGPoint(x: 0.5,y: -0.18), control2: CGPoint(x: 0,y: -0.05))
            p.addCurve(to: CGPoint(x: 0.59,y: 0.3), control1: CGPoint(x: -0.08,y: 0.7), control2: CGPoint(x: 0.54,y: 0.58))
            p.addCurve(to: CGPoint(x: 0.12,y: 1), control1: CGPoint(x: 0.62,y: 0.6), control2: CGPoint(x: 0.4,y: 0.87))
        default: return []
        }
        return [[p]]
    }
    private static func line(_ points: [(CGFloat, CGFloat)]) -> CGPath {
        let path = CGMutablePath()
        for (index, p) in points.enumerated() {
            if index == 0 { path.move(to: CGPoint(x: p.0,y: p.1)) }
            else { path.addLine(to: CGPoint(x: p.0,y: p.1)) }
        }
        return path
    }
}
