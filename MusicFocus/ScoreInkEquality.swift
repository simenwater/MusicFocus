import PencilKit

extension PKDrawing {
    /// Archive equality includes native selection metadata. Compare all rendered
    /// ink attributes when a completed gesture has not added/removed a stroke.
    /// A real pen stroke exits at the count check; this is never used per-frame
    /// while drawing. Tolerances cover PencilKit's archive quantization only.
    func hasSameVisibleInk(as other: PKDrawing) -> Bool {
        if self == other { return true }
        guard strokes.count == other.strokes.count else { return false }
        func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a-b) <= 0.0001 }
        for (a, b) in zip(strokes, other.strokes) {
            let ac = ScoreAnnotationColor(a.ink.color), bc = ScoreAnnotationColor(b.ink.color)
            let colorsMatch = zip([ac.red, ac.green, ac.blue, Double(a.ink.color.cgColor.alpha)],
                                  [bc.red, bc.green, bc.blue, Double(b.ink.color.cgColor.alpha)])
                .allSatisfy { abs($0-$1) <= 0.0001 }
            guard a.ink.inkType == b.ink.inkType, colorsMatch,
                  a.mask?.cgPath == b.mask?.cgPath, a.path.count == b.path.count else { return false }
            let t=a.transform, u=b.transform
            guard zip([t.a,t.b,t.c,t.d,t.tx,t.ty], [u.a,u.b,u.c,u.d,u.tx,u.ty]).allSatisfy({ near($0, $1) }) else { return false }
            for (p, q) in zip(a.path, b.path) {
                guard zip([p.location.x,p.location.y,p.size.width,p.size.height,p.opacity,p.force,p.azimuth,p.altitude],
                          [q.location.x,q.location.y,q.size.width,q.size.height,q.opacity,q.force,q.azimuth,q.altitude])
                    .allSatisfy({ near($0, $1) }) else { return false }
            }
        }
        return true
    }
}
