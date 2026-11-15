import PencilKit

/// Prepare a move once. Pointer updates must never scan, archive or replace the
/// page drawing. Only the final translation is applied to the vector strokes.
struct ScoreInkTranslation {
    let original: PKDrawing
    let background: PKDrawing
    private let before: [PKStroke]
    private let indices: Set<Int>
    private(set) var offset = CGPoint.zero

    init(drawing: PKDrawing, indices: Set<Int>) {
        before = drawing.strokes
        self.indices = indices
        original = PKDrawing(strokes: before.enumerated().filter { indices.contains($0.offset) }.map(\.element))
        background = PKDrawing(strokes: before.enumerated().filter { !indices.contains($0.offset) }.map(\.element))
    }

    mutating func move(to offset: CGPoint) {
        guard offset.x.isFinite, offset.y.isFinite else { return }
        self.offset = offset
    }

    var hasMoved: Bool { hypot(offset.x, offset.y) > 0.001 }
    var movedInk: PKDrawing {
        original.transformed(using: CGAffineTransform(translationX: offset.x, y: offset.y))
    }
    var result: PKDrawing {
        let moved = movedInk.strokes
        var index = 0
        return PKDrawing(strokes: before.enumerated().map { position, stroke in
            guard indices.contains(position) else { return stroke }
            defer { index += 1 }
            return moved[index]
        })
    }
}

/// A short-lived image at the current display resolution. The stored and
/// exported annotations remain vector ink. Moving this view changes only its
/// transform; PencilKit's page-sized Metal surface stays untouched until drop.
@MainActor
final class ScoreInkDragPreview: UIImageView {
    private let pageToOverlay: CGFloat

    init(drawing: PKDrawing, in overlay: ScorePageOverlay) {
        let bounds = drawing.bounds.insetBy(dx: -2, dy: -2)
        pageToOverlay = overlay.bounds.width / max(overlay.drawingPoint(CGPoint(x: overlay.bounds.width,y: 0)).x, 0.01)
        let displayScale = overlay.canvas.zoomScale * (overlay.window?.screen.scale ?? 2)
        // Bound temporary memory even for an unusually large handwritten mark.
        let scale = max(0.1, min(displayScale, 4096 / max(max(bounds.width,bounds.height),1)))
        var rendered: UIImage?
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            rendered = drawing.image(from: bounds, scale: scale)
        }
        super.init(image: rendered)
        isUserInteractionEnabled = false
        frame = bounds.applying(CGAffineTransform(scaleX: pageToOverlay,y: pageToOverlay))
        overlay.addSubview(self)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func move(to offset: CGPoint) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        transform = CGAffineTransform(translationX: offset.x * pageToOverlay, y: offset.y * pageToOverlay)
        CATransaction.commit()
    }
}
