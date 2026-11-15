import PDFKit
import PencilKit

struct ScoreAnnotationColor: Codable, Equatable {
    var red: Double, green: Double, blue: Double
    init(_ color: UIColor) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        red = r; green = g; blue = b
    }
    var uiColor: UIColor { UIColor(red: red, green: green, blue: blue, alpha: 1) }
}

/// Changes refer to indices in the immutable imported PDF. Unchanged annotations retain their appearance streams.
struct ScoreAnnotationEdit: Codable, Equatable {
    var deleted = false
    var offset = CGPoint.zero
    var color: ScoreAnnotationColor?
    var removedPaths: Set<Int> = []
    var text: String?
    var opacity: Double?
}

struct ScoreAnnotationEdits: Codable, Equatable {
    var version = 1
    var items: [String: ScoreAnnotationEdit] = [:]
    var covers: [ScorePageCover] = []

    init(version: Int = 1, items: [String: ScoreAnnotationEdit] = [:], covers: [ScorePageCover] = []) {
        self.version = version; self.items = items; self.covers = covers
    }
    private enum CodingKeys: String, CodingKey { case version, items, covers }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        items = try values.decode([String: ScoreAnnotationEdit].self, forKey: .items)
        covers = try values.decodeIfPresent([ScorePageCover].self, forKey: .covers) ?? []
        guard covers.allSatisfy(\.isValid), Set(covers.map(\.id)).count == covers.count else {
            throw DecodingError.dataCorruptedError(forKey: .covers, in: values, debugDescription: "Invalid page cover")
        }
    }
}

struct ScoreAnnotationHit {
    let key: String
    let path: Int?
}

/// One PDF instance per reader/export. No full-document serialization or full-page rasterization while a finger moves.
final class ScorePDFAnnotations {
    struct Entry {
        let key: String
        let page: PDFPage
        let original: PDFAnnotation
        let displayedOriginal: PDFAnnotation
        let pageNumber: Int
        let opacity: CGFloat
    }
    let entries: [Entry]
    private var originals: [String: Entry] = [:]
    private(set) var live: [String: PDFAnnotation] = [:]
    private var geometry: [String: [[CGPoint]]] = [:]
    private(set) var edits = ScoreAnnotationEdits()
    private let document: PDFDocument
    private(set) var coverAnnotations: [UUID: PDFAnnotation] = [:]
    private var displayedCovers: [ScorePageCover] = []
    private let usesInkOverlay: Bool
    static let supported: Set<String> = ["Ink", "FreeText", "Text", "Highlight", "Underline", "StrikeOut"]

    init(document: PDFDocument, correctAppearanceForDisplay: Bool = false) {
        self.document = document
        // iPadOS 27 leaves imported annotation layers at 1 pixel per PDF point.
        // Keep PDFKit's correct rendering on older systems; on 27, draw ink in
        // our viewport-sized overlay using only public PDFKit/UIKit APIs.
        if #available(iOS 27, *) { usesInkOverlay = correctAppearanceForDisplay }
        else { usesInkOverlay = false }
        var entries: [Entry] = []
        var replacements: [(PDFPage, PDFAnnotation, PDFAnnotation)] = []
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            for (index, annotation) in page.annotations.enumerated() {
                let key = "\(pageIndex + 1):\(index)"
                let corrected = correctAppearanceForDisplay
                    ? ScoreInkAppearance.annotation(annotation, on: page, at: index) : annotation
                let displayed = usesInkOverlay && annotation.type == "Ink"
                    ? ScoreOverlayInkAnnotation(displaying: corrected) : corrected
                if displayed !== annotation { replacements.append((page, annotation, displayed)) }
                guard Self.supported.contains(annotation.type ?? ""), Self.canEdit(annotation) else { continue }
                let entry = Entry(key: key, page: page, original: annotation, displayedOriginal: displayed,
                                  pageNumber: pageIndex + 1, opacity: Self.opacity(annotation))
                entries.append(entry); originals[key] = entry; live[key] = displayed
            }
        }
        self.entries = entries
        for (page, original, displayed) in replacements {
            page.removeAnnotation(original); page.addAnnotation(displayed)
        }
    }

    static func canEdit(_ annotation: PDFAnnotation) -> Bool {
        let flags = (annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/F")) as? NSNumber)?.intValue ?? 0
        return flags & (64 | 128 | 512) == 0 // ReadOnly, Locked, LockedContents.
    }

    func entry(_ key: String) -> Entry? { originals[key] }

    func apply(_ newEdits: ScoreAnnotationEdits) {
        let changed = Set(edits.items.keys).union(newEdits.items.keys).filter { edits.items[$0] != newEdits.items[$0] }
        for key in changed {
            guard let entry = originals[key] else { continue }
            if let old = live.removeValue(forKey: key) { entry.page.removeAnnotation(old) }
            guard let patch = newEdits.items[key] else {
                entry.page.addAnnotation(entry.displayedOriginal); live[key] = entry.displayedOriginal; continue
            }
            guard !patch.deleted else { continue }
            let opacity = patch.opacity.map { CGFloat(min(1, max(0.1, $0.isFinite ? $0 : 1))) } ?? entry.opacity
            let annotation: PDFAnnotation
            if entry.original.type == "Ink" {
                let sourcePaths = entry.original.paths ?? []
                let remaining = sourcePaths.enumerated().filter { !patch.removedPaths.contains($0.offset) }
                guard !remaining.isEmpty else { continue }
                let ink = ScoreVariableInkAnnotation.make(bounds: entry.original.bounds.offsetBy(dx: patch.offset.x, dy: patch.offset.y), opacity: opacity)
                ink.color = (patch.color?.uiColor ?? entry.original.color).withAlphaComponent(opacity)
                ink.border = entry.original.border?.copy() as? PDFBorder
                ink.userName = entry.original.userName
                ink.contents = entry.original.contents
                ink.shouldPrint = entry.original.shouldPrint
                ink.shouldDisplay = entry.original.shouldDisplay
                if let name = entry.original.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/NM")) { ink.setValue(name, forAnnotationKey: PDFAnnotationKey(rawValue: "/NM")) }
                let widths = Self.widths(entry.original)
                ink.strokeWidths = remaining.map { widths.indices.contains($0.offset) ? widths[$0.offset] : [] }
                for (_, path) in remaining { ink.add(path.copy() as! UIBezierPath) }
                ink.setValue(ink.strokeWidths, forAnnotationKey: PDFAnnotationKey(rawValue: "/ReaddleWidthList"))
                annotation = ink
            } else {
                // PDFKit's NSCopying implementation can drop the subtype on iOS. Rebuild from PDF properties.
                let subtypes: [String: PDFAnnotationSubtype] = ["Text": .text, "FreeText": .freeText,
                    "Highlight": .highlight, "Underline": .underline, "StrikeOut": .strikeOut]
                var properties = entry.original.annotationKeyValues
                properties.removeValue(forKey: "/AP")
                properties.removeValue(forKey: "/AAPL:AKExtras")
                annotation = PDFAnnotation(bounds: entry.original.bounds.offsetBy(dx: patch.offset.x, dy: patch.offset.y),
                                           forType: subtypes[entry.original.type ?? ""]!, withProperties: properties)
                annotation.color = entry.original.color.withAlphaComponent(opacity)
                annotation.font = entry.original.font
                annotation.fontColor = entry.original.fontColor
                annotation.alignment = entry.original.alignment
                annotation.border = entry.original.border?.copy() as? PDFBorder
                annotation.contents = entry.original.contents
                if let quads = entry.original.quadrilateralPoints, !quads.isEmpty {
                    annotation.quadrilateralPoints = quads.map { NSValue(cgPoint: CGPoint(x: $0.cgPointValue.x + patch.offset.x, y: $0.cgPointValue.y + patch.offset.y)) }
                }
                if let color = patch.color {
                    annotation.removeValue(forAnnotationKey: PDFAnnotationKey(rawValue: "/AP"))
                    annotation.color = color.uiColor.withAlphaComponent(opacity)
                    if annotation.type == "FreeText" { annotation.fontColor = color.uiColor }
                }
                if let text = patch.text {
                    annotation.removeValue(forAnnotationKey: PDFAnnotationKey(rawValue: "/RC"))
                    annotation.removeValue(forAnnotationKey: PDFAnnotationKey(rawValue: "/AP"))
                    annotation.contents = text
                }
            }
            annotation.modificationDate = Date()
            let displayed = usesInkOverlay && annotation.type == "Ink"
                ? ScoreOverlayInkAnnotation(displaying: annotation) : annotation
            entry.page.addAnnotation(displayed)
            live[key] = displayed
        }
        applyCovers(newEdits.covers, reorder: !changed.isEmpty)
        edits = newEdits
    }

    /// Preview never changes persisted edits or the undo baseline. Only changed
    /// rectangles are replaced; imported pages and PencilKit canvases stay alive.
    func applyCovers(_ covers: [ScorePageCover], reorder: Bool = false) {
        let prior = Dictionary(uniqueKeysWithValues: displayedCovers.map { ($0.id, $0) })
        let nextIDs = Set(covers.map(\.id))
        for id in Array(coverAnnotations.keys) where !nextIDs.contains(id) {
            if let old = coverAnnotations.removeValue(forKey: id) { old.page?.removeAnnotation(old) }
        }
        for cover in covers where cover.isValid {
            guard let page = document.page(at: cover.page-1) else { continue }
            if prior[cover.id] == cover, let existing = coverAnnotations[cover.id] {
                if reorder { page.removeAnnotation(existing); page.addAnnotation(existing) }
                continue
            }
            if let old = coverAnnotations.removeValue(forKey: cover.id) { old.page?.removeAnnotation(old) }
            let annotation = cover.annotation()
            let displayed = usesInkOverlay ? ScoreOverlayInkAnnotation(displaying: annotation) : annotation
            page.addAnnotation(displayed); coverAnnotations[cover.id] = displayed
        }
        // Keep overlapping covers in their saved order, including after a move.
        if covers.count > 1 {
            for cover in covers {
                if let annotation = coverAnnotations[cover.id], let page = annotation.page {
                    page.removeAnnotation(annotation); page.addAnnotation(annotation)
                }
            }
        }
        displayedCovers = covers
    }

    func hit(pageNumber: Int, point: CGPoint, tolerance: CGFloat, inkOnly: Bool = false) -> ScoreAnnotationHit? {
        for entry in entries.reversed() where entry.pageNumber == pageNumber {
            guard let annotation = live[entry.key], annotation.shouldDisplay,
                  annotation.bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(point) else { continue }
            if annotation.type != "Ink" {
                if !inkOnly { return ScoreAnnotationHit(key: entry.key, path: nil) }
                continue
            }
            if geometry[entry.key] == nil { geometry[entry.key] = (entry.original.paths ?? []).map { Self.points($0.cgPath) } }
            let point = CGPoint(x: point.x - annotation.bounds.minX, y: point.y - annotation.bounds.minY)
            let widths = Self.widths(entry.original)
            let removed = edits.items[entry.key]?.removedPaths ?? []
            for (path, samples) in (geometry[entry.key] ?? []).enumerated().reversed() where !removed.contains(path) {
                let width = widths.indices.contains(path) ? widths[path].max() ?? 1 : entry.original.border?.lineWidth ?? 1
                let radius = tolerance + width / 2
                if Self.distance(point, to: samples) <= radius { return ScoreAnnotationHit(key: entry.key, path: path) }
            }
        }
        return nil
    }

    /// Read this before editing a page. On iOS, PDFKit's /CA getter is routed to widget captions.
    /// The Core Graphics dictionary exposes the standard numeric opacity without that ambiguity.
    static func opacity(_ annotation: PDFAnnotation) -> CGFloat {
        let alpha = annotation.color.cgColor.alpha
        if alpha < 0.999 || annotation is ScoreVariableInkAnnotation { return alpha }
        if let number = annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/CA")) as? NSNumber { return CGFloat(truncating: number) }
        guard let page = annotation.page, let dictionary = page.pageRef?.dictionary,
              let index = page.annotations.firstIndex(where: { $0 === annotation }) else { return alpha }
        var array: CGPDFArrayRef?, item: CGPDFDictionaryRef?, opacity: CGPDFReal = 1
        guard CGPDFDictionaryGetArray(dictionary, "Annots", &array), let array,
              index < CGPDFArrayGetCount(array), CGPDFArrayGetDictionary(array, index, &item), let item,
              CGPDFDictionaryGetNumber(item, "CA", &opacity) else { return alpha }
        return min(1, max(0, opacity))
    }

    static func widths(_ annotation: PDFAnnotation) -> [[CGFloat]] {
        (annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/ReaddleWidthList")) as? [[NSNumber]])?.map { $0.map { CGFloat(truncating: $0) } } ?? []
    }

    static func points(_ path: CGPath) -> [CGPoint] {
        var result: [CGPoint] = [], start = CGPoint.zero
        path.applyWithBlock { element in
            let item = element.pointee
            switch item.type {
            case .moveToPoint: start = item.points[0]; result.append(start)
            case .addLineToPoint: result.append(item.points[0])
            case .addQuadCurveToPoint:
                let from = result.last ?? .zero, control = item.points[0], end = item.points[1]
                for step in 1...16 {
                    let t = CGFloat(step) / 16, u = 1 - t
                    result.append(CGPoint(x: u*u*from.x + 2*u*t*control.x + t*t*end.x, y: u*u*from.y + 2*u*t*control.y + t*t*end.y))
                }
            case .addCurveToPoint:
                let from = result.last ?? .zero, c1 = item.points[0], c2 = item.points[1], end = item.points[2]
                for step in 1...24 {
                    let t = CGFloat(step) / 24, u = 1 - t
                    result.append(CGPoint(x: u*u*u*from.x + 3*u*u*t*c1.x + 3*u*t*t*c2.x + t*t*t*end.x,
                                          y: u*u*u*from.y + 3*u*u*t*c1.y + 3*u*t*t*c2.y + t*t*t*end.y))
                }
            case .closeSubpath: result.append(start)
            @unknown default: break
            }
        }
        return result
    }

    private static func distance(_ point: CGPoint, to samples: [CGPoint]) -> CGFloat {
        guard let first = samples.first else { return .infinity }
        var best = hypot(point.x - first.x, point.y - first.y)
        for (a, b) in zip(samples, samples.dropFirst()) {
            let dx = b.x - a.x, dy = b.y - a.y, length = dx*dx + dy*dy
            let t = length > 0 ? min(1, max(0, ((point.x-a.x)*dx + (point.y-a.y)*dy) / length)) : 0
            best = min(best, hypot(point.x - a.x - t*dx, point.y - a.y - t*dy))
        }
        return best
    }
}

/// Stays attached to its PDF page for hit testing, selection and accessibility.
/// Only its display moves to the high-resolution overlay. Export always loads
/// the immutable original PDF and therefore never serializes this proxy.
final class ScoreOverlayInkAnnotation: PDFAnnotation {
    let rendered: PDFAnnotation

    init(displaying source: PDFAnnotation) {
        rendered = source
        var properties = source.annotationKeyValues
        properties.removeValue(forKey: "/AP")
        properties.removeValue(forKey: "/AAPL:AKExtras")
        super.init(bounds: source.bounds, forType: source.type == "Square" ? .square : .ink, withProperties: properties)
        color = source.color
        border = source.border?.copy() as? PDFBorder
        contents = source.contents
        userName = source.userName
        shouldDisplay = source.shouldDisplay
        shouldPrint = source.shouldPrint
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(with box: PDFDisplayBox, in context: CGContext) {}
}

/// A screen-sized, noninteractive surface below new PencilKit ink. It redraws
/// visible vectors at the screen's pixel density, never a magnified page bitmap.
final class ScoreImportedInkView: UIView {
    private var ink: [ScoreOverlayInkAnnotation] = []
    private var pageToView = CGAffineTransform.identity
    private var displayBox = PDFDisplayBox.cropBox

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        isHidden = true
        contentMode = .redraw
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(page: PDFPage, in pdfView: PDFView) {
        let next = page.annotations.compactMap { $0 as? ScoreOverlayInkAnnotation }
        isHidden = next.isEmpty
        guard !next.isEmpty else { ink = []; return }
        let origin = convert(pdfView.convert(CGPoint.zero, from: page), from: pdfView)
        let x = convert(pdfView.convert(CGPoint(x: 1, y: 0), from: page), from: pdfView)
        let y = convert(pdfView.convert(CGPoint(x: 0, y: 1), from: page), from: pdfView)
        let transform = CGAffineTransform(a: x.x-origin.x, b: x.y-origin.y,
            c: y.x-origin.x, d: y.y-origin.y, tx: origin.x, ty: origin.y)
        let components: [CGFloat] = [transform.a, transform.b, transform.c, transform.d, transform.tx, transform.ty]
        guard components.allSatisfy({ $0.isFinite }),
              abs(transform.a*transform.d - transform.b*transform.c) > 0.000001 else { return }
        let changed = next.map(ObjectIdentifier.init) != ink.map(ObjectIdentifier.init)
        if changed || transform != pageToView || displayBox != pdfView.displayBox {
            ink = next; pageToView = transform; displayBox = pdfView.displayBox
            setNeedsDisplay()
        }
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.saveGState()
        context.concatenate(pageToView)
        for annotation in ink where annotation.shouldDisplay {
            // Clip by the screen viewport, including a little antialiasing space.
            guard annotation.bounds.applying(pageToView).insetBy(dx: -2, dy: -2).intersects(rect) else { continue }
            context.saveGState()
            annotation.rendered.draw(with: displayBox, in: context)
            context.restoreGState()
        }
        context.restoreGState()
    }
}

/// PDFKit fits an appearance stream uniformly into /Rect. Standard PDF appearance mapping
/// scales the two axes independently. PDF Reader Pro can write different aspect ratios after
/// moving/undoing ink, making horizontal strokes appear shorter in PDFKit than in other readers.
/// Correct only the display transform; exports still load and preserve the original PDF objects.
private final class ScoreInkAppearance: PDFAnnotation {
    private var source: PDFAnnotation?
    private var correction = CGSize(width: 1, height: 1)

    static func annotation(_ source: PDFAnnotation, on page: PDFPage, at index: Int) -> PDFAnnotation {
        guard source.type == "Ink", let dictionary = page.pageRef?.dictionary else { return source }
        var annotations: CGPDFArrayRef?, item: CGPDFDictionaryRef?, appearances: CGPDFDictionaryRef?
        var stream: CGPDFStreamRef?, box: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(dictionary, "Annots", &annotations), let annotations,
              index < CGPDFArrayGetCount(annotations),
              CGPDFArrayGetDictionary(annotations, index, &item), let item,
              CGPDFDictionaryGetDictionary(item, "AP", &appearances), let appearances,
              CGPDFDictionaryGetStream(appearances, "N", &stream), let stream,
              let properties = CGPDFStreamGetDictionary(stream),
              CGPDFDictionaryGetArray(properties, "BBox", &box), let box,
              CGPDFArrayGetCount(box) == 4 else { return source }
        var values = [CGPDFReal](repeating: 0, count: 4)
        for i in values.indices {
            guard CGPDFArrayGetNumber(box, i, &values[i]), values[i].isFinite else { return source }
        }
        var bounds = CGRect(x: values[0], y: values[1], width: values[2]-values[0], height: values[3]-values[1])
        var matrix: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(properties, "Matrix", &matrix), let matrix {
            guard CGPDFArrayGetCount(matrix) == 6 else { return source }
            var m = [CGPDFReal](repeating: 0, count: 6)
            for i in m.indices {
                guard CGPDFArrayGetNumber(matrix, i, &m[i]), m[i].isFinite else { return source }
            }
            bounds = bounds.applying(CGAffineTransform(a: m[0], b: m[1], c: m[2], d: m[3], tx: m[4], ty: m[5]))
        }
        guard bounds.width > 0, bounds.height > 0 else { return source }
        let sx = source.bounds.width / bounds.width, sy = source.bounds.height / bounds.height
        guard sx.isFinite, sy.isFinite, sx > 0, sy > 0, abs(log(sx / sy)) > 0.001 else { return source }
        let correction = CGSize(width: sx / min(sx, sy), height: sy / min(sx, sy))
        guard correction.width.isFinite, correction.height.isFinite else { return source }
        var keys = source.annotationKeyValues
        keys.removeValue(forKey: "/AP"); keys.removeValue(forKey: "/AAPL:AKExtras")
        let result = ScoreInkAppearance(bounds: source.bounds, forType: .ink, withProperties: keys)
        result.source = source
        result.correction = correction
        return result
    }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        guard let source else { return }
        context.saveGState()
        context.translateBy(x: bounds.midX, y: bounds.midY)
        context.scaleBy(x: correction.width, y: correction.height)
        context.translateBy(x: -bounds.midX, y: -bounds.midY)
        source.draw(with: box, in: context)
        context.restoreGState()
    }
}

/// Standard /Ink plus a vector appearance for variable-width strokes. Other readers can edit the InkList.
final class ScoreVariableInkAnnotation: PDFAnnotation {
    var strokeWidths: [[CGFloat]] = []
    static func make(bounds: CGRect, opacity: CGFloat) -> ScoreVariableInkAnnotation {
        let annotation = ScoreVariableInkAnnotation(bounds: bounds, forType: .ink, withProperties: nil)
        annotation.color = UIColor.black.withAlphaComponent(opacity)
        return annotation
    }
    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        guard let paths, !paths.isEmpty else { return }
        let shape = CGMutablePath()
        for (index, path) in paths.enumerated() {
            let points = ScorePDFAnnotations.points(path.cgPath)
            let storedWidths = strokeWidths
            let widths = storedWidths.indices.contains(index) ? storedWidths[index] : []
            let fallback = max(0.1, border?.lineWidth ?? 1)
            if let point = points.first, points.allSatisfy({ hypot($0.x-point.x, $0.y-point.y) < 0.0001 }) {
                let width = widths.first ?? fallback
                shape.addEllipse(in: CGRect(x: point.x-width/2, y: point.y-width/2, width: width, height: width))
            }
            guard points.count > 1 else { continue }
            for i in 1..<points.count {
                let width = widths.indices.contains(i) ? (widths[i-1] + widths[i]) / 2 : fallback
                if hypot(points[i].x-points[i-1].x, points[i].y-points[i-1].y) < 0.0001 { continue }
                let segment = CGMutablePath(); segment.move(to: points[i-1]); segment.addLine(to: points[i])
                shape.addPath(segment.copy(strokingWithWidth: max(0.1, width), lineCap: .round, lineJoin: .round, miterLimit: 2))
            }
        }
        let alpha = (value(forAnnotationKey: PDFAnnotationKey(rawValue: "/CA")) as? NSNumber)?.doubleValue ?? Double(color.cgColor.alpha)
        context.saveGState()
        context.translateBy(x: bounds.minX, y: bounds.minY)
        context.setFillColor(color.withAlphaComponent(1).cgColor)
        context.setAlpha(alpha)
        context.addPath(shape); context.fillPath()
        context.restoreGState()
    }
}

extension ScorePDFExport {
    struct ImportedMetadata {
        let opacity: CGFloat
        let name: String?
    }

    static func editable(source: URL, drawings: [Int: Data], edits: ScoreAnnotationEdits = .init(), title: String? = nil) throws -> URL {
        guard let document = PDFDocument(url: source), !document.isLocked else { throw ScoreLibraryError.invalidPDF }
        // Read before edits reorder the annotation array. On older PDFKit,
        // writing an unchanged annotation can discard standard /CA and /NM.
        var imported: [ObjectIdentifier: ImportedMetadata] = [:]
        for index in 0..<document.pageCount {
            for annotation in document.page(at: index)?.annotations ?? [] {
                imported[ObjectIdentifier(annotation)] = .init(opacity: ScorePDFAnnotations.opacity(annotation),
                    name: annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/NM")) as? String)
            }
        }
        let annotations = ScorePDFAnnotations(document: document)
        annotations.apply(edits)
        var changedAnnotations = edits.items.keys.compactMap { annotations.live[$0] } + Array(annotations.coverAnnotations.values)
        for (pageNumber, data) in drawings.sorted(by: { $0.key < $1.key }) {
            let drawing = try PKDrawing(data: data)
            guard let page = document.page(at: pageNumber - 1) else { continue }
            for stroke in drawing.strokes {
                for annotation in inkAnnotations(stroke, on: page) {
                    page.addAnnotation(annotation); changedAnnotations.append(annotation)
                }
            }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ScoreExport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(fileName(for: title ?? source.deletingPathExtension().lastPathComponent))
        try writeEditable(document, to: url, changedAnnotations: changedAnnotations, imported: imported)
        return url
    }

    /// PDFKit reserves /CA for widget captions and rejects numeric annotation opacity.
    /// Write a unique temporary PDF name, then replace that name with /CA plus padding.
    /// Equal byte lengths preserve every xref/stream offset; a UUID avoids touching imported content.
    /// A missing marker fails export instead of silently losing transparency.
    static func writeEditable(_ document: PDFDocument, to url: URL, changedAnnotations: [PDFAnnotation],
                              imported: [ObjectIdentifier: ImportedMetadata] = [:]) throws {
        let name = "/MusicFocusOpacity" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let key = PDFAnnotationKey(rawValue: name)
        let nameMarker = name + "Name", nameKey = PDFAnnotationKey(rawValue: name + "Name")
        let legacy: Bool
        if #available(iOS 27.0, *) { legacy = false } else { legacy = true }
        let changedIDs = Set(changedAnnotations.map(ObjectIdentifier.init))
        let all = (0..<document.pageCount).flatMap { document.page(at: $0)?.annotations ?? [] }
        var count = 0, nameCount = 0
        for annotation in all {
            let original = imported[ObjectIdentifier(annotation)]
            let opacity = original?.opacity ?? annotation.color.cgColor.alpha
            if opacity < 0.999 && (legacy || changedIDs.contains(ObjectIdentifier(annotation))) {
                guard annotation.setValue(NSNumber(value: Double(opacity)), forAnnotationKey: key) else { throw CocoaError(.fileWriteUnknown) }
                count += 1
            }
            if legacy, let preservedName = original?.name ?? (annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/NM")) as? String) {
                guard annotation.setValue(preservedName, forAnnotationKey: nameKey) else { throw CocoaError(.fileWriteUnknown) }
                nameCount += 1
            }
        }
        defer { for annotation in all { annotation.removeValue(forAnnotationKey: key); annotation.removeValue(forAnnotationKey: nameKey) } }
        guard document.write(to: url) else { throw CocoaError(.fileWriteUnknown) }
        guard count > 0 || nameCount > 0 else { return }
        var data = try Data(contentsOf: url)
        // Longest marker first, because the name marker includes the opacity prefix.
        for (field, target, expected) in [(nameMarker,"/NM",nameCount),(name,"/CA",count)] where expected > 0 {
            let marker = Data(field.utf8), replacement = Data((target + String(repeating: " ", count: field.utf8.count - target.utf8.count)).utf8)
            var location = 0, replaced = 0
            while let range = data.range(of: marker, in: location..<data.count) {
                let next = range.upperBound < data.count ? data[range.upperBound] : 0
                guard [9, 10, 13, 32].contains(next) else { throw CocoaError(.fileWriteUnknown) }
                data.replaceSubrange(range, with: replacement)
                location = range.upperBound; replaced += 1
            }
            guard replaced >= expected else { throw CocoaError(.fileWriteUnknown) }
        }
        try data.write(to: url, options: .atomic)
    }

    /// Respect PencilKit eraser masks: each surviving range becomes one editable PDF ink stroke.
    static func inkAnnotations(_ stroke: PKStroke, on page: PDFPage) -> [PDFAnnotation] {
        let crop = page.bounds(for: .cropBox)
        // Sample in page points, not the stroke's native coordinate scale.
        // Small transformed glyphs otherwise expand into millions of PDF points.
        let pageScale = max(hypot(stroke.transform.a, stroke.transform.b), hypot(stroke.transform.c, stroke.transform.d))
        let sampleDistance = 0.5 / max(0.001, pageScale)
        return stroke.maskedPathRanges.compactMap { range in
            let samples = Array(stroke.path.interpolatedPoints(in: range, by: .distance(sampleDistance)))
            guard !samples.isEmpty else { return nil }
            let points = samples.map { point -> CGPoint in
                let p = point.location.applying(stroke.transform)
                return CGPoint(x: crop.minX + p.x, y: crop.maxY - p.y)
            }
            let scale = hypot(stroke.transform.a, stroke.transform.c)
            var widths = samples.map { max(0.1, $0.size.width * scale) }
            // Broad monoline ink can render wider than its recorded point size
            // (observed on iPadOS 27). Recover the constant tip diameter from
            // PencilKit's public rendered bounds rather than guessing a multiplier.
            // Leave pressure-varying and masked strokes in their original geometry.
            if stroke.mask == nil, stroke.ink.inkType != .marker,
               let minimum = widths.min(), let maximum = widths.max(), maximum - minimum < 0.02 {
                let xs = points.map(\.x), ys = points.map(\.y)
                let paddingX = stroke.renderBounds.width - (xs.max()! - xs.min()!)
                let paddingY = stroke.renderBounds.height - (ys.max()! - ys.min()!)
                let renderedWidth = min(paddingX, paddingY)
                // Integer rounding of renderBounds must not inflate fine pen tips.
                if renderedWidth.isFinite, renderedWidth > maximum + max(3, maximum * 0.3) {
                    widths = widths.map { _ in renderedWidth }
                }
            }
            let extent = (widths.max() ?? 1) / 2 + 1
            let xs = points.map(\.x), ys = points.map(\.y)
            let bounds = CGRect(x: xs.min()!-extent, y: ys.min()!-extent,
                                width: xs.max()!-xs.min()!+2*extent, height: ys.max()!-ys.min()!+2*extent)
            // PencilKit can record values above 1 (e.g. monoline records ~1.5).
            // They mean full coverage, not permission to amplify the ink's alpha.
            let opacity = stroke.ink.color.cgColor.alpha * min(1, max(0, samples.first?.opacity ?? 1))
            let ink = ScoreVariableInkAnnotation.make(bounds: bounds, opacity: opacity)
            let path = UIBezierPath()
            path.move(to: CGPoint(x: points[0].x-bounds.minX, y: points[0].y-bounds.minY))
            for p in points.dropFirst() { path.addLine(to: CGPoint(x: p.x-bounds.minX, y: p.y-bounds.minY)) }
            ink.add(path)
            ink.strokeWidths = [widths]
            ink.color = stroke.ink.color.withAlphaComponent(opacity)
            ink.setValue([widths], forAnnotationKey: PDFAnnotationKey(rawValue: "/ReaddleWidthList"))
            let border = PDFBorder(); border.lineWidth = widths.reduce(0,+) / CGFloat(widths.count); ink.border = border
            ink.userName = "MusicFocus"; ink.shouldPrint = true
            ink.setValue(UUID().uuidString, forAnnotationKey: PDFAnnotationKey(rawValue: "/NM"))
            return ink
        }
    }
}
