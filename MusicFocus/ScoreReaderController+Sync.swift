import PDFKit
import PencilKit
import SwiftUI
import Combine

// MARK: - Nearby score sync (see ScoreSync*.swift)

extension ScoreReaderController {
    /// In-memory annotations, including ink that is not yet on disk.
    func syncSnapshot() -> ScoreAnnotationSnapshot {
        .init(drawings: drawings, edits: annotationEdits, fingerings: fingeringMarks)
    }

    var pdfViewForTesting: PDFView? { pdfView }

    /// The visible area relative to the page that fills most of the screen.
    func syncViewport() -> ScoreSyncViewport? {
        guard let view = pdfView, let document, view.bounds.width > 0, view.bounds.height > 0 else { return nil }
        let anchor = view.visiblePages.max { visibleArea(of: $0, in: view) < visibleArea(of: $1, in: view) }
        guard let page = anchor ?? view.currentPage else { return nil }
        let index = document.index(for: page)
        let box = page.bounds(for: .cropBox)
        guard index != NSNotFound, box.width > 0, box.height > 0 else { return nil }
        let visible = view.convert(view.bounds, to: page)
        return .init(page: index + 1,
                     x: (visible.minX - box.minX) / box.width, y: (box.maxY - visible.maxY) / box.height,
                     width: visible.width / box.width, height: visible.height / box.height,
                     twoPages: twoPages)
    }

    private func visibleArea(of page: PDFPage, in view: PDFView) -> CGFloat {
        let rect = view.convert(page.bounds(for: .cropBox), from: page).intersection(view.bounds)
        return rect.isNull ? 0 : rect.width * rect.height
    }

    /// Shows the same part of the score as the presenter: same layout, the
    /// presenter's visible area fitted to this screen and centred.
    func followViewport(_ viewport: ScoreSyncViewport) {
        if twoPages != viewport.twoPages { twoPages = viewport.twoPages }
        guard let view = pdfView, let page = document?.page(at: viewport.page - 1),
              view.bounds.width > 0, view.bounds.height > 0 else { return }
        // Remote navigation is an explicit zoom/position, never an automatic fit.
        fitsWholePage = false
        fittedScale = nil
        pendingInitialPage = nil
        pendingTurnPage = nil
        let box = page.bounds(for: .cropBox)
        let wanted = CGRect(x: box.minX + viewport.x * box.width, y: box.maxY - (viewport.y + viewport.height) * box.height,
                            width: viewport.width * box.width, height: viewport.height * box.height)
        // Size of the area at scale 1, in screen orientation (rotated pages swap).
        let onScreen = view.convert(wanted, from: page)
        let current = view.scaleFactor
        guard current > 0, onScreen.width > 0, onScreen.height > 0 else { return }
        let fit = min(view.bounds.width / (onScreen.width / current), view.bounds.height / (onScreen.height / current))
        let scale = min(view.maxScaleFactor, max(view.minScaleFactor, fit))
        if abs(scale - current) > 0.001 {
            view.autoScales = false
            view.scaleFactor = scale
            view.layoutIfNeeded()
        }
        let center = view.convert(CGPoint(x: wanted.midX, y: wanted.midY), from: page)
        guard let scroll = scrollView else {
            view.go(to: PDFDestination(page: page, at: CGPoint(x: wanted.minX, y: wanted.maxY)))
            return
        }
        let inset = scroll.adjustedContentInset
        var offset = scroll.contentOffset
        offset.x += center.x - view.bounds.midX
        offset.y += center.y - view.bounds.midY
        offset.x = min(max(offset.x, -inset.left), max(-inset.left, scroll.contentSize.width + inset.right - scroll.bounds.width))
        offset.y = min(max(offset.y, -inset.top), max(-inset.top, scroll.contentSize.height + inset.bottom - scroll.bounds.height))
        scroll.setContentOffset(offset, animated: false)
        schedulePageUpdate()
    }

    /// Replaces the reader's annotations with ones received from a nearby iPad.
    /// Visible pages refresh in place. Undo history is cleared: its snapshots
    /// predate the replacement and would bring the old ink back.
    func replaceSyncedAnnotations(with snapshot: ScoreAnnotationSnapshot) {
        finishInkInput()
        inkSelectionEditor.clear()
        endedInkInput.removeAll()
        cancelFingering()
        finishAnnotationGesture()
        coverEditor.select(nil)
        selectedFingering = nil
        select(nil)
        drawingBefore.removeAll()
        let empty = PKDrawing().dataRepresentation()
        for page in Set(drawings.keys).union(snapshot.drawings.keys) {
            let data = snapshot.drawings[page] ?? empty
            guard (drawings[page] ?? empty) != data else { continue }
            guard let drawing = try? PKDrawing(data: data) else { errorMessage = "score.annotationReadError".localized; continue }
            drawings[page] = data; dirty[page] = data
            displayDrawing(drawing, on: page)
        }
        if fingeringMarks != snapshot.fingerings { fingeringMarks = snapshot.fingerings; dirtyFingerings = true; fingeringHitCache.removeAll() }
        if annotationEdits != snapshot.edits { updateAnnotations(snapshot.edits, save: false) }
        undoHistory.removeAll()
        redoHistory.removeAll()
        updateUndoState()
        queueSave()
    }
}
