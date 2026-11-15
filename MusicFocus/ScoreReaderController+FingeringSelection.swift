import PDFKit
import PencilKit
import SwiftUI
import Combine

/// Selecting, moving, covering and correcting converted fingering marks.
extension ScoreReaderController {
    /// Page coordinates are stable across viewport zoom/crop; match only intact
    /// converted ink, never imported PDF marks or ordinary handwritten strokes.
    func fingering(at point: CGPoint, page: Int, tolerance: CGFloat = 4) -> ScoreFingeringSelection? {
        guard let data = drawings[page] else { return nil }
        if fingeringHitCache[page]?.data != data {
            guard let drawing = try? PKDrawing(data: data) else { return nil }
            let byID = Dictionary(drawing.strokes.map { ($0.legacyFingeringID, $0) }, uniquingKeysWith: { a, _ in a })
            let hits = ScoreFingeringMark.active(in: drawing, marks: fingeringMarks[page] ?? []).map { mark in
                (mark, PKDrawing(strokes: mark.strokeIDs.compactMap { byID[$0] }).bounds)
            }
            fingeringHitCache[page] = (data, hits)
        }
        for (mark, bounds) in fingeringHitCache[page]?.marks ?? [] {
            if bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(point) { return .init(page: page, mark: mark) }
        }
        return nil
    }

    var canMoveFingerings: Bool {
        // In a Pencil workflow the free finger can reposition a digit without
        // changing pens. Finger drawing with ordinary brushes keeps its ink path.
        editing && (tool == .fingering || (tool.inkType != nil && !fingerDrawing))
    }

    func fingeringHit(at point: CGPoint) -> ScoreFingeringSelection? {
        guard let view = pdfView else { return nil }
        for overlay in overlays.values {
            let local = overlay.convert(point, from: view)
            guard overlay.bounds.contains(local) else { continue }
            let unit = overlay.convert(CGPoint(x: 1, y: 0), to: view)
            let origin = overlay.convert(CGPoint.zero, to: view)
            let scale = max(0.01, hypot(unit.x-origin.x, unit.y-origin.y))
            if let hit = fingering(at: overlay.drawingPoint(local), page: overlay.canvas.pageNumber,
                                   tolerance: min(8, 10 / scale)) { return hit }
        }
        return nil
    }

    @objc func selectFingeringGesture(_ sender: UITapGestureRecognizer) {
        guard sender.state == .ended, let hit = fingeringHit(at: sender.location(in: pdfView)) else { return }
        cancelFingering()
        selectedFingering = hit
    }

    func dragFingering(_ sender: ScoreObjectDragRecognizer) {
        if sender.state == .began, let hit = fingeringDragHit,
           let overlay = overlays.values.first(where: { $0.canvas.pageNumber == hit.page }) {
            let position = sender.location(in: overlay), translation = sender.translation(in: overlay)
            let origin = overlay.drawingPoint(CGPoint(x: position.x-translation.x, y: position.y-translation.y))
            beginFingeringMove(hit, on: overlay, origin: origin)
        }
        if [.began, .changed, .ended].contains(sender.state), let state = fingeringDragState {
            updateFingeringMove(to: state.overlay.drawingPoint(sender.location(in: state.overlay)))
        }
        if sender.state == .ended { finishFingeringDrag(commit: true) }
        if sender.state == .cancelled || sender.state == .failed { finishFingeringDrag(commit: false) }
    }

    func beginFingeringMove(_ selection: ScoreFingeringSelection, on overlay: ScorePageOverlay, origin: CGPoint) {
        finishInkInput()
        guard let data = drawings[selection.page], let before = try? PKDrawing(data: data),
              selection.mark.strokes(in: before) != nil else { return }
        cancelFingering(); selectedFingering = nil
        let indices = Set(before.strokes.enumerated().filter { selection.mark.strokeIDs.contains($0.element.legacyFingeringID) }.map(\.offset))
        let translation = ScoreInkTranslation(drawing: before, indices: indices)
        let preview = ScoreInkDragPreview(drawing: translation.original, in: overlay)
        fingeringDragState = .init(selection: selection, before: before, overlay: overlay, origin: origin,
                                  translation: translation, preview: preview)
        // Exactly one page update on pickup. Pointer samples move only the small
        // preview view, independent of the number of notes on this page.
        displayDrawing(translation.background, on: selection.page)
    }

    func updateFingeringMove(to point: CGPoint) {
        guard var state = fingeringDragState else { return }
        state.translation.move(to: CGPoint(x: point.x-state.origin.x, y: point.y-state.origin.y))
        state.preview.move(to: state.translation.offset)
        fingeringDragState = state
    }

    func finishFingeringDrag(commit: Bool) {
        guard let state = fingeringDragState else { return }
        fingeringDragState = nil; fingeringDragHit = nil
        defer { state.preview.removeFromSuperview() }
        if commit && state.translation.hasMoved {
            commitInkMove(page: state.selection.page,before: state.before,after: state.translation.result)
        } else { displayDrawing(state.before, on: state.selection.page) }
    }

    func commitInkMove(page: Int, before: PKDrawing, after: PKDrawing) {
        guard let data = drawings[page], let current = try? PKDrawing(data: data),
              current.hasSameVisibleInk(as: before), !before.hasSameVisibleInk(as: after) else { return }
        cancelFingering()
        let change = Change.drawing(page,data,after.dataRepresentation())
        // Translation preserves stroke identity, so digit/circle/cover metadata
        // remains valid without appending another identical fingering history.
        apply(change,forward: true); record(change)
    }

    func setSelectedFingeringCover(_ cover: ScoreFingeringCover?) {
        guard let selection = selectedFingering, selection.mark.cover != cover,
              let data = drawings[selection.page], let drawing = try? PKDrawing(data: data),
              let ink = selection.mark.glyphStrokes(in: drawing) else { return }
        let plain = ScoreFingeringReplacement(sourceIDs: [], drawing: PKDrawing(strokes: ink), digit: selection.mark.digit,
                                             circled: selection.mark.circled, font: selection.mark.font ?? .handwritten)
        let replacement = cover?.applying(to: plain) ?? plain
        replaceFingering(selection, drawing: replacement.drawing, digit: replacement.digit, cover: replacement.cover, keepSelection: true)
    }

    func deleteSelectedFingering() {
        guard let selection = selectedFingering else { return }
        replaceFingering(selection, drawing: PKDrawing(), digit: selection.mark.digit, cover: nil)
    }

    private func replaceFingering(_ selection: ScoreFingeringSelection, drawing clean: PKDrawing,
                                  digit: Int, cover: ScoreFingeringCover?, keepSelection: Bool = false) {
        guard let data = drawings[selection.page], let drawing = try? PKDrawing(data: data),
              selection.mark.strokes(in: drawing) != nil,
              let index = drawing.strokes.firstIndex(where: { selection.mark.strokeIDs.contains($0.legacyFingeringID) }) else { return }
        cancelFingering()
        var strokes = drawing.strokes.filter { !selection.mark.strokeIDs.contains($0.legacyFingeringID) }
        strokes.insert(contentsOf: clean.strokes, at: min(index, strokes.count))
        let mark = ScoreFingeringMark(drawing: clean, digit: digit, circled: selection.mark.circled,
                                     font: selection.mark.font ?? .handwritten, cover: cover)
        if !clean.strokes.isEmpty { fingeringMarks[selection.page, default: []].append(mark); dirtyFingerings = true }
        let change = Change.drawing(selection.page, data, PKDrawing(strokes: strokes).dataRepresentation())
        apply(change, forward: true); record(change)
        selectedFingering = keepSelection ? .init(page: selection.page, mark: mark) : nil
    }

    func correctFingering(to digit: Int) {
        guard (1...5).contains(digit), let selection = selectedFingering,
              let data = drawings[selection.page], let drawing = try? PKDrawing(data: data),
              let ink = selection.mark.glyphStrokes(in: drawing) else { selectedFingering = nil; return }
        let ring = selection.mark.circled ? ink.last : nil
        let digits = selection.mark.circled ? Array(ink.dropLast()) : ink
        let target = ScoreFingeringSizing.inkBounds(digits)
        guard let clean = ScoreFingeringBeautifier.render(digit: digit, from: digits, circle: ring,
                targetBounds: target, font: selection.mark.font ?? .handwritten), !clean.strokes.isEmpty else { return }
        var plain = ScoreFingeringReplacement(sourceIDs: [], drawing: clean, digit: digit,
            circled: selection.mark.circled, font: selection.mark.font ?? .handwritten)
        // Different glyph shapes have different rounded renderBounds. Keep the
        // actual digit height/center exactly stable when correcting 1 to 5, etc.
        let bounds = ScoreFingeringSizing.digitBounds(plain)
        if bounds.height > 0, target.height > 0 {
            let scale = target.height / bounds.height
            let fitted = clean.transformed(using: CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
                tx: target.midX - bounds.midX * scale, ty: target.midY - bounds.midY * scale))
            plain = .init(sourceIDs: [], drawing: fitted, digit: digit, circled: plain.circled, font: plain.font)
        }
        let replacement = selection.mark.cover?.applying(to: plain) ?? plain
        replaceFingering(selection, drawing: replacement.drawing, digit: digit, cover: replacement.cover)
    }
}
