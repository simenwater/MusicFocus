import PDFKit

/// Owns only whiteout gestures. It never transforms or assigns a PKDrawing.
@MainActor
final class ScoreCoverEditor: NSObject, UIGestureRecognizerDelegate {
    enum Mode { case inactive, create, select }
    var mode = Mode.inactive
    var color = ScoreAnnotationColor(.white)
    var covers: [ScorePageCover] = []
    var onSelection: ((UUID?) -> Void)?
    var onPreview: (([ScorePageCover]) -> Void)?
    var onCommit: ((ScorePageCover) -> Void)?
    private(set) var selectedID: UUID?
    private weak var pdfView: PDFView?
    private let outline = ScoreCoverOutline()
    private let drag = ScoreObjectDragRecognizer()
    private lazy var tap = ScoreCoverTapRecognizer(target: self, action: #selector(tapped(_:)))
    private enum Operation { case create, move, resize(CGPoint) }
    private struct Contact {
        var original: ScorePageCover
        var start: CGPoint
        var operation: Operation
        var preview: ScorePageCover?
    }
    private var contact: Contact?

    func attach(to view: PDFView, host: UIView) {
        pdfView = view
        outline.frame = host.bounds; outline.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.addSubview(outline)
        drag.delegate = self; tap.delegate = self
        drag.onUpdate = { [weak self] in self?.dragged($0) }
        drag.onCancel = { [weak self] in self?.finish(commit: false) }
        tap.require(toFail: drag)
        host.addGestureRecognizer(drag); host.addGestureRecognizer(tap)
    }

    func detach() {
        finish(commit: false)
        drag.view?.removeGestureRecognizer(drag); tap.view?.removeGestureRecognizer(tap)
        outline.removeFromSuperview(); pdfView = nil
    }

    func select(_ id: UUID?) {
        selectedID = id
        onSelection?(id)
        refresh()
    }

    func refresh() {
        guard mode != .inactive, let view = pdfView, let cover = contact?.preview ?? covers.first(where: { $0.id == selectedID }),
              let page = view.document?.page(at: cover.page-1) else { outline.update(points: []); return }
        outline.update(points: corners(cover.bounds).map { outline.convert(view.convert($0, from: page), from: view) })
    }

    /// Used before PencilKit's hit-testing, to leave object gestures to this editor.
    func accepts(_ point: CGPoint) -> Bool {
        guard mode != .inactive, let view = pdfView, view.bounds.contains(point) else { return false }
        if mode == .create { return view.page(for: point, nearest: false) != nil }
        return hit(point) != nil || corner(at: point) != nil
    }

    private func hit(_ point: CGPoint) -> ScorePageCover? {
        guard let view = pdfView, let page = view.page(for: point, nearest: false), let document = view.document else { return nil }
        let number = document.index(for: page)+1, local = view.convert(point, to: page)
        return covers.reversed().first { $0.page == number && $0.bounds.contains(local) }
    }

    private func corners(_ rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.minX,y: rect.minY), CGPoint(x: rect.minX,y: rect.maxY),
         CGPoint(x: rect.maxX,y: rect.minY), CGPoint(x: rect.maxX,y: rect.maxY)]
    }

    private func corner(at point: CGPoint) -> (ScorePageCover, CGPoint)? {
        guard let view = pdfView, let cover = covers.first(where: { $0.id == selectedID }),
              let page = view.document?.page(at: cover.page-1) else { return nil }
        let box = view.convert(cover.bounds, from: page)
        // Even a very small cover has a usable center for dragging the whole object.
        if box.insetBy(dx: box.width*0.25, dy: box.height*0.25).contains(point) { return nil }
        let points = corners(cover.bounds)
        guard let closest = points.indices.min(by: {
            let a=view.convert(points[$0], from: page), b=view.convert(points[$1], from: page)
            return hypot(a.x-point.x,a.y-point.y) < hypot(b.x-point.x,b.y-point.y)
        }) else { return nil }
        let handle = view.convert(points[closest], from: page)
        return hypot(handle.x-point.x,handle.y-point.y) <= 22 ? (cover, points[3-closest]) : nil
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard mode != .inactive, let view = pdfView else { return false }
        if gestureRecognizer === drag, gestureRecognizer.numberOfTouches > 0 { return true }
        let point = touch.location(in: view)
        guard accepts(point) else { return false }
        if gestureRecognizer === drag {
            if let (cover, opposite) = corner(at: point), let page = view.document?.page(at: cover.page-1) {
                contact = .init(original: cover, start: view.convert(point,to: page), operation: .resize(opposite))
            } else if let cover = hit(point), let page = view.document?.page(at: cover.page-1) {
                contact = .init(original: cover, start: view.convert(point,to: page), operation: .move)
            } else if mode == .create, let page = view.page(for: point,nearest: false), let document = view.document {
                let local = view.convert(point,to: page)
                contact = .init(original: .init(page: document.index(for: page)+1,
                    bounds: CGRect(x: local.x,y: local.y,width: 2,height: 2), color: color), start: local, operation: .create)
            } else { return false }
        }
        return true
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        mode != .inactive && gestureRecognizer.numberOfTouches == 1
    }

    @objc private func tapped(_ sender: UITapGestureRecognizer) {
        contact = nil
        guard let view = pdfView else { return }
        let point = sender.location(in: view)
        if let cover = hit(point) { select(cover.id); return }
        guard mode == .create, let page = view.page(for: point,nearest: false), let document = view.document else { select(nil); return }
        let center = view.convert(point,to: page)
        let cover = ScorePageCover(page: document.index(for: page)+1,
            bounds: CGRect(x: center.x-30,y: center.y-16,width: 60,height: 32),color: color).constrained(to: page.bounds(for: .cropBox))
        onCommit?(cover); select(cover.id)
    }

    private func dragged(_ recognizer: ScoreObjectDragRecognizer) {
        guard var state = contact, let view = pdfView, let page = view.document?.page(at: state.original.page-1) else { return }
        if recognizer.state == .began { select(state.original.id) }
        let point = view.convert(recognizer.location(in: view),to: page)
        let crop = page.bounds(for: .cropBox)
        func clipped(_ point: CGPoint) -> CGPoint {
            CGPoint(x: min(crop.maxX,max(crop.minX,point.x)),y: min(crop.maxY,max(crop.minY,point.y)))
        }
        var preview = state.original
        switch state.operation {
        case .create:
            preview.bounds = rectangle(from: state.start,to: clipped(point))
        case .move:
            preview.bounds = preview.bounds.offsetBy(dx: point.x-state.start.x,dy: point.y-state.start.y)
        case .resize(let opposite):
            // Use the handle's original corner plus the drag delta, avoiding a
            // jump when a finger lands within the larger handle hit target.
            let originalCorner = CGPoint(x: state.original.bounds.minX + state.original.bounds.maxX - opposite.x,
                                         y: state.original.bounds.minY + state.original.bounds.maxY - opposite.y)
            preview.bounds = rectangle(from: opposite,to: clipped(CGPoint(x: originalCorner.x+point.x-state.start.x,
                                                                          y: originalCorner.y+point.y-state.start.y)))
        }
        preview = preview.constrained(to: page.bounds(for: .cropBox))
        state.preview = preview; contact = state
        var values = covers
        if let index = values.firstIndex(where: { $0.id == preview.id }) { values[index] = preview }
        else { values.append(preview) }
        onPreview?(values); refresh()
        if recognizer.state == .ended { finish(commit: true) }
    }

    private func rectangle(from start: CGPoint,to end: CGPoint) -> CGRect {
        CGRect(x: min(start.x,end.x),y: min(start.y,end.y),width: max(2,abs(end.x-start.x)),height: max(2,abs(end.y-start.y)))
    }

    func finish(commit: Bool) {
        let preview = contact?.preview
        contact = nil
        if commit, let preview { onCommit?(preview) }
        else if preview != nil { onPreview?(covers) }
        if !commit, preview != nil, let selectedID, !covers.contains(where: { $0.id == selectedID }) { select(nil) }
        refresh()
    }
}

/// Screen-space handles stay the same usable size at every PDF zoom level.
private final class ScoreCoverOutline: UIView {
    private var points: [CGPoint] = []
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear; isOpaque = false; isUserInteractionEnabled = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update(points: [CGPoint]) {
        guard self.points != points else { return }
        self.points = points; setNeedsDisplay()
        accessibilityElements = points.enumerated().map { index, point in
            let element = UIAccessibilityElement(accessibilityContainer: self)
            element.accessibilityIdentifier = "scoreCoverHandle-\(index)"
            element.accessibilityLabel = "score.coverResize".localized
            element.accessibilityFrameInContainerSpace = CGRect(x: point.x-22,y: point.y-22,width: 44,height: 44)
            return element
        }
    }
    override func draw(_ rect: CGRect) {
        guard points.count == 4, let cg = UIGraphicsGetCurrentContext() else { return }
        cg.setStrokeColor(UIColor.systemBlue.cgColor); cg.setLineWidth(1.5)
        cg.move(to: points[0]); for i in [1,3,2] { cg.addLine(to: points[i]) }; cg.closePath(); cg.strokePath()
        for point in points {
            let box = CGRect(x: point.x-5,y: point.y-5,width: 10,height: 10)
            cg.setFillColor(UIColor.white.cgColor); cg.fillEllipse(in: box); cg.strokeEllipse(in: box)
        }
    }
}

/// A pinch can start with one contact on the floating tools and one on the
/// page. Reject it even when UIKit sends only the page contact to this tap.
private final class ScoreCoverTapRecognizer: UITapGestureRecognizer {
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard (event.allTouches?.filter { $0.phase != .ended && $0.phase != .cancelled }.count ?? 0) <= 1 else {
            state = .failed; return
        }
        super.touchesBegan(touches,with: event)
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard (event.allTouches?.filter { $0.phase != .ended && $0.phase != .cancelled }.count ?? 0) <= 1 else {
            state = .failed; return
        }
        super.touchesMoved(touches,with: event)
    }
}
