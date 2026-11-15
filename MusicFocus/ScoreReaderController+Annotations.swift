import PDFKit
import PencilKit
import SwiftUI
import Combine

/// Editing the PDF's own annotations: selection, colour, move and erase gestures.
extension ScoreReaderController {
    func updateAnnotations(_ edits: ScoreAnnotationEdits, save: Bool = true) {
        annotationEdits = edits
        annotations?.apply(edits)
        coverEditor.covers = edits.covers
        if let selectedCoverID, !edits.covers.contains(where: { $0.id == selectedCoverID }) { coverEditor.select(nil) }
        coverEditor.refresh()
        objectWillChange.send()
        if let view = pdfView {
            for overlay in overlays.values { overlay.updateViewport(in: view) }
        }
        dirtyEdits = true
        pdfView?.setNeedsDisplay()
        refreshSelection()
        if save { queueSave() }
    }

    func editAnnotation(_ key: String, change: (inout ScoreAnnotationEdit) -> Void) {
        guard annotations?.entry(key) != nil else { return }
        let before = annotationEdits
        var after = before, patch = after.items[key] ?? .init()
        change(&patch); after.items[key] = patch
        guard before != after else { return }
        updateAnnotations(after)
        record(.annotations(before, after))
    }

    func select(_ key: String?) {
        if key != nil { inkSelectionEditor.clear() }
        if selectedAnnotation != key { selectedAnnotation = key }
        refreshSelection()
    }

    func chooseColor(_ index: Int) {
        guard ScoreInkPalette.colors.indices.contains(index) else { return }
        chooseColor(ScoreInkPalette.colors[index])
    }

    func chooseColor(_ color: UIColor) {
        if tool == .cover || selectedCover != nil { chooseCoverColor(color); return }
        if tool == .voice {
            guard !voiceAudio.isBusy else { return }
            voiceColor = .init(color)
            if var note = selectedVoiceNote {
                note.color = voiceColor
                if voiceNotes.contains(where: { $0.id == note.id }) { saveVoiceNote(note) }
                selectedVoiceNote = note
            }
            return
        }
        if let key = selectedAnnotation, tool == .select {
            editAnnotation(key) { $0.color = .init(color) }
        } else {
            if tool.inkType == nil { tool = .pen }
            updateInkStyle { $0.color = .init(color) }
        }
    }

    func deleteSelectedAnnotation() {
        guard let key = selectedAnnotation else { return }
        editAnnotation(key) { $0.deleted = true }
        select(nil)
    }

    var selectedText: String? {
        guard let key = selectedAnnotation, let annotation = annotations?.live[key],
              ["Text", "FreeText"].contains(annotation.type ?? "") else { return nil }
        return annotation.contents ?? ""
    }

    func setSelectedText(_ text: String) {
        guard let key = selectedAnnotation, selectedText != nil else { return }
        editAnnotation(key) { $0.text = text }
    }

    func refreshSelection() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard editing, tool == .select, let key = selectedAnnotation,
              let annotation = annotations?.live[key], let page = annotation.page, let view = pdfView else {
            selectionLayer.path = nil; return
        }
        selectionLayer.path = UIBezierPath(rect: view.convert(annotation.bounds, from: page).insetBy(dx: -4, dy: -4)).cgPath
    }

    func hit(at point: CGPoint, inkOnly: Bool = false) -> ScoreAnnotationHit? {
        guard let view = pdfView, let document, let page = view.page(for: point, nearest: false) else { return nil }
        return annotations?.hit(pageNumber: document.index(for: page) + 1,
                                point: view.convert(point, to: page), tolerance: 5 / max(0.01, view.scaleFactor), inkOnly: inkOnly)
    }

    @objc func selectAnnotation(_ sender: UITapGestureRecognizer) {
        select(hit(at: sender.location(in: pdfView))?.key)
    }

    @objc func moveAnnotation(_ sender: UIPanGestureRecognizer) {
        guard let view = pdfView else { return }
        if sender.state == .began, let key = panKey, let start = panStart, let entry = annotations?.entry(key) {
            select(key)
            gestureBefore = annotationEdits
            dragOrigin = view.convert(start, to: entry.page)
            dragOffset = annotationEdits.items[key]?.offset ?? .zero
        }
        if [.began, .changed, .ended].contains(sender.state), let key = selectedAnnotation, let entry = annotations?.entry(key), let origin = dragOrigin {
            let point = view.convert(sender.location(in: view), to: entry.page)
            var after = annotationEdits, patch = after.items[key] ?? .init()
            let crop = entry.page.bounds(for: .cropBox), bounds = entry.original.bounds
            patch.offset = CGPoint(x: min(crop.maxX-bounds.maxX, max(crop.minX-bounds.minX, dragOffset.x+point.x-origin.x)),
                                   y: min(crop.maxY-bounds.maxY, max(crop.minY-bounds.minY, dragOffset.y+point.y-origin.y)))
            after.items[key] = patch
            updateAnnotations(after, save: false)
        }
        if [.ended, .cancelled, .failed].contains(sender.state) { finishAnnotationGesture() }
    }

    @objc func eraseAnnotation(_ sender: UILongPressGestureRecognizer) {
        if sender.state == .began { gestureBefore = annotationEdits }
        if sender.state == .began || sender.state == .changed,
           let hit = hit(at: sender.location(in: pdfView), inkOnly: true), let path = hit.path {
            var after = annotationEdits, patch = after.items[hit.key] ?? .init()
            patch.removedPaths.insert(path); after.items[hit.key] = patch
            updateAnnotations(after, save: false)
        }
        if [.ended, .cancelled, .failed].contains(sender.state) { finishAnnotationGesture() }
    }

    func finishAnnotationGesture() {
        defer { gestureBefore = nil; dragOrigin = nil }
        guard let before = gestureBefore, before != annotationEdits else { return }
        record(.annotations(before, annotationEdits))
        queueSave()
    }
}
