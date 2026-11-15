import PDFKit
import PencilKit

/// Owns selection of native ink, independently of PencilKit's text-selection
/// gestures (whose translation disagrees with a counter-scaled PDF overlay).
@MainActor
final class ScoreInkSelectionEditor: NSObject, UIGestureRecognizerDelegate {
    var enabled = false { didSet { if !enabled { finish(commit: false); clear() } } }
    var context: ((CGPoint) -> (ScorePageOverlay, PKDrawing)?)?
    var excludes: ((CGPoint) -> Bool)?
    var expandGroup: ((Int, PKDrawing, Set<Int>) -> Set<Int>)?
    var onPreview: ((Int, PKDrawing?) -> Void)?
    var onCommit: ((Int, PKDrawing, PKDrawing) -> Void)?
    var onSelection: ((Int) -> Void)?
    private let drag = ScoreObjectDragRecognizer()
    private lazy var tap = UITapGestureRecognizer(target: self,action: #selector(tapped(_:)))
    private let outline = CAShapeLayer()
    private weak var view: PDFView?
    private var selected: (overlay: ScorePageOverlay, drawing: PKDrawing, indices: Set<Int>)? {
        didSet {
            let count = selected?.indices.count ?? 0
            if count != (oldValue?.indices.count ?? 0) { onSelection?(count) }
        }
    }
    private var contact: (overlay: ScorePageOverlay, drawing: PKDrawing, origin: CGPoint, indices: Set<Int>)?
    private var move: ScoreInkTranslation?
    private var preview: ScoreInkDragPreview?
    private var rectangle: CGRect?

    func attach(to view: PDFView, host: UIView) {
        self.view = view
        outline.strokeColor = UIColor.systemBlue.cgColor
        outline.fillColor = UIColor.systemBlue.withAlphaComponent(0.06).cgColor
        outline.lineWidth = 1.5; outline.lineDashPattern = [5,3]
        view.layer.addSublayer(outline)
        drag.delegate = self; tap.delegate = self; tap.require(toFail: drag)
        drag.onUpdate = { [weak self] in self?.dragged($0) }
        drag.onCancel = { [weak self] in self?.finish(commit: false) }
        host.addGestureRecognizer(drag); host.addGestureRecognizer(tap)
    }

    func detach() {
        finish(commit: false); clear()
        drag.view?.removeGestureRecognizer(drag); tap.view?.removeGestureRecognizer(tap)
        outline.removeFromSuperlayer(); view = nil
    }

    func clear() { selected = nil; outline.path = nil }

    func deleteSelection() {
        guard let selected else { return }
        let after = PKDrawing(strokes: selected.drawing.strokes.enumerated().filter { !selected.indices.contains($0.offset) }.map(\.element))
        clear()
        onCommit?(selected.overlay.canvas.pageNumber,selected.drawing,after)
    }

    func refresh() {
        guard let selected, let view else { return }
        show(PKDrawing(strokes: selected.indices.sorted().map { selected.drawing.strokes[$0] }).bounds,
             on: selected.overlay, in: view)
    }

    private func show(_ bounds: CGRect, on overlay: ScorePageOverlay, in view: PDFView) {
        let ratio = overlay.bounds.width / max(overlay.drawingPoint(CGPoint(x: overlay.bounds.width,y: 0)).x,0.01)
        let box = overlay.convert(bounds.applying(.init(scaleX: ratio,y: ratio)),to: view)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        outline.path = UIBezierPath(rect: box.insetBy(dx: -4,dy: -4)).cgPath
        CATransaction.commit()
    }

    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard enabled, let view else { return false }
        if recognizer === drag, recognizer.numberOfTouches > 0 { return true }
        let point = touch.location(in: view)
        guard excludes?(point) != true, let (overlay,drawing) = context?(point) else { return false }
        if recognizer === drag {
            let local = overlay.drawingPoint(overlay.convert(point,from: view))
            contact = (overlay,drawing,local,indices(at: local,overlay: overlay,drawing: drawing))
        }
        return true
    }

    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        enabled && recognizer.numberOfTouches == 1
    }

    private func indices(at point: CGPoint, overlay: ScorePageOverlay, drawing: PKDrawing) -> Set<Int> {
        if let selection = selected, selection.overlay === overlay,
           selection.drawing.hasSameVisibleInk(as: drawing),
           PKDrawing(strokes: selection.indices.sorted().map { drawing.strokes[$0] }).bounds.insetBy(dx: -5,dy: -5).contains(point) {
            return selection.indices
        }
        guard let index = Self.hit(point,in: drawing,tolerance: 8 / max(overlay.canvas.zoomScale,0.1)) else { return [] }
        return expandGroup?(overlay.canvas.pageNumber,drawing,[index]) ?? [index]
    }

    static func hit(_ point: CGPoint, in drawing: PKDrawing, tolerance: CGFloat) -> Int? {
        for index in drawing.strokes.indices.reversed() {
            let stroke = drawing.strokes[index]
            guard stroke.renderBounds.insetBy(dx: -tolerance,dy: -tolerance).contains(point) else { continue }
            let points = Array(stroke.path.interpolatedPoints(by: .distance(max(1,tolerance/2))))
            if points.contains(where: {
                let p = $0.location.applying(stroke.transform)
                return hypot(p.x-point.x,p.y-point.y) <= tolerance + max($0.size.width,$0.size.height)/2
            }) { return index }
        }
        return nil
    }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        contact = nil
        guard let view, let (overlay,drawing) = context?(recognizer.location(in: view)) else { return }
        let point = overlay.drawingPoint(recognizer.location(in: overlay))
        let indices = indices(at: point,overlay: overlay,drawing: drawing)
        if indices.isEmpty { clear() }
        else { selected = (overlay,drawing,indices); refresh() }
    }

    private func dragged(_ recognizer: ScoreObjectDragRecognizer) {
        guard let contact, let view else { return }
        let point = contact.overlay.drawingPoint(recognizer.location(in: contact.overlay))
        if recognizer.state == .began {
            clear()
            if !contact.indices.isEmpty {
                let translation = ScoreInkTranslation(drawing: contact.drawing,indices: contact.indices)
                move = translation
                preview = ScoreInkDragPreview(drawing: translation.original,in: contact.overlay)
                onPreview?(contact.overlay.canvas.pageNumber,translation.background)
            }
        }
        if var translation = move {
            translation.move(to: CGPoint(x: point.x-contact.origin.x,y: point.y-contact.origin.y))
            move = translation; preview?.move(to: translation.offset)
            show(translation.original.bounds.offsetBy(dx: translation.offset.x,dy: translation.offset.y),on: contact.overlay,in: view)
        } else {
            let bounds = CGRect(x: min(point.x,contact.origin.x),y: min(point.y,contact.origin.y),
                                width: abs(point.x-contact.origin.x),height: abs(point.y-contact.origin.y))
            rectangle = bounds; show(bounds,on: contact.overlay,in: view)
        }
        if recognizer.state == .ended { finish(commit: true) }
    }

    func finish(commit: Bool) {
        guard let contact else { return }
        let translation = move, bounds = rectangle
        self.contact = nil; move = nil; rectangle = nil
        defer { preview?.removeFromSuperview(); preview = nil }
        if let translation {
            if commit && translation.hasMoved {
                onCommit?(contact.overlay.canvas.pageNumber,contact.drawing,translation.result)
                selected = (contact.overlay,translation.result,contact.indices)
            } else { selected = (contact.overlay,contact.drawing,contact.indices) }
            onPreview?(contact.overlay.canvas.pageNumber,nil)
        } else if commit, let bounds, bounds.width > 3, bounds.height > 3 {
            var indices = Set(contact.drawing.strokes.indices.filter { bounds.intersects(contact.drawing.strokes[$0].renderBounds) })
            indices = expandGroup?(contact.overlay.canvas.pageNumber,contact.drawing,indices) ?? indices
            selected = indices.isEmpty ? nil : (contact.overlay,contact.drawing,indices)
        }
        outline.path = nil; refresh()
    }
}
