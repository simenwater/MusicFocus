import PDFKit
import PencilKit
import SwiftUI
import Combine

/// Page turns, zoom limits and fitting the page to the screen.
extension ScoreReaderController {
    /// Return keyboard focus to the reader after changing tools/closing a panel.
    /// While writing, ScoreCanvas handles pedals and undo itself.
    func focusKeys() {
        guard let view = pdfView, view.window != nil, !view.isFirstResponder else { return }
        view.becomeFirstResponder()
    }

    func go(by delta: Int) {
        guard let document else { return }
        onUserNavigation?()
        // Prefer the pages the reader computed as visible. In two-up layouts
        // PDFView.currentPage can name a page of the next row, skipping a spread.
        let current: Int
        if let first = pendingTurnPage ?? pages.first {
            current = first
        } else if let page = pdfView?.currentPage {
            current = document.index(for: page) + 1
        } else { return }
        go(to: Self.targetPage(from: current, by: delta, twoPages: twoPages, pageCount: document.pageCount))
    }

    /// One-based page to show after `delta` page turns (a spread is one turn).
    nonisolated static func targetPage(from page: Int, by delta: Int, twoPages: Bool, pageCount: Int) -> Int {
        guard pageCount > 0 else { return 1 }
        let start = twoPages ? ((page - 1) / 2) * 2 + 1 : page
        return min(pageCount, max(1, start + delta * (twoPages ? 2 : 1)))
    }

    func go(to page: Int) {
        let index = twoPages ? ((page - 1) / 2) * 2 : page - 1
        guard let target = document?.page(at: index), let view = pdfView else { return }
        if view.bounds.width <= 0 || view.bounds.height <= 0 {
            pendingInitialPage = index + 1
            return
        }
        pendingInitialPage = nil
        pendingTurnPage = index + 1
        preserveManualZoom(in: view)
        if fitsWholePage { applyWholePageFit(in: view, page: index + 1) }
        let bounds = target.bounds(for: .cropBox)
        if fitsWholePage {
            view.go(to: bounds, on: target)
            alignFittedPage(target, in: view)
        } else {
            view.go(to: PDFDestination(page: target, at: CGPoint(x: bounds.minX, y: bounds.maxY)))
        }
        schedulePageUpdate()
    }

    private func alignFittedPage(_ page: PDFPage, in view: PDFView) {
        view.layoutIfNeeded()
        if scrollObservation == nil { observeScrolling(in: view) }
        guard let scrollView, let document else { return }
        var rect = view.convert(page.bounds(for: .cropBox), from: page)
        if twoPages, let next = document.page(at: document.index(for: page) + 1) {
            rect = rect.union(view.convert(next.bounds(for: .cropBox), from: next))
        }
        guard !rect.isNull, rect.width.isFinite, rect.height.isFinite else { return }
        // PDFKit's destinations can leave different top offsets when moving
        // backwards. Centre the fitted page/spread so its bottom is never cut off.
        var offset = scrollView.contentOffset
        offset.x += rect.midX - view.bounds.midX
        offset.y += rect.midY - view.bounds.midY
        let inset = scrollView.adjustedContentInset
        offset.x = min(max(offset.x, -inset.left), max(-inset.left, scrollView.contentSize.width + inset.right - scrollView.bounds.width))
        offset.y = min(max(offset.y, -inset.top), max(-inset.top, scrollView.contentSize.height + inset.bottom - scrollView.bounds.height))
        scrollView.setContentOffset(offset, animated: false)
    }

    func fitPage() {
        guard let view = pdfView else { return }
        let page = pages.first ?? pendingInitialPage ?? view.currentPage.map { (document?.index(for: $0) ?? 0) + 1 } ?? 1
        fitsWholePage = true
        fittedScale = nil
        go(to: page)
    }

    func updateLayout() {
        guard let view = pdfView else { return }
        let page = pages.first ?? pendingInitialPage ?? 1
        fitsWholePage = true
        fittedScale = nil
        pendingInitialPage = page
        view.displayMode = twoPages ? .twoUpContinuous : .singlePageContinuous
        view.autoScales = false
        view.layoutDocumentView()
        scrollObservation = nil
        schedulePageUpdate()
    }

    func updateZoomLimits() {
        guard let view = pdfView, view.scaleFactorForSizeToFit > 0 else { return }
        // A shorter scanned page must not raise the minimum above the current
        // zoom and make PDFKit move the document while the user is scrolling.
        let minimum = min(view.scaleFactorForSizeToFit, wholePageScale(in: view), view.scaleFactor)
        guard minimum.isFinite, minimum > 0 else { return }
        let maximum = max(minimum * 5, 5, view.scaleFactor)
        if view.minScaleFactor != minimum { view.minScaleFactor = minimum }
        if view.maxScaleFactor != maximum { view.maxScaleFactor = maximum }
    }

    func preserveManualZoom(in view: PDFView) {
        if let fittedScale, abs(view.scaleFactor - fittedScale) > 0.001 {
            fitsWholePage = false
        }
    }

    private func applyWholePageFit(in view: PDFView, page: Int) {
        let scale = wholePageScale(in: view, pageNumber: page)
        guard scale.isFinite, scale > 0 else { return }
        view.autoScales = false
        view.maxScaleFactor = max(scale * 5, 5)
        view.minScaleFactor = min(scale, view.scaleFactorForSizeToFit > 0 ? view.scaleFactorForSizeToFit : scale)
        view.scaleFactor = scale
        fittedScale = view.scaleFactor
        viewportSize = view.bounds.size
        view.layoutDocumentView()
    }

    private func wholePageScale(in view: PDFView, pageNumber: Int? = nil) -> CGFloat {
        guard let document, let page = pageNumber.flatMap({ document.page(at: $0 - 1) }) ?? view.currentPage else { return view.scaleFactorForSizeToFit }
        let index = document.index(for: page)
        guard index != NSNotFound else { return view.scaleFactorForSizeToFit }
        let start = twoPages ? (index / 2) * 2 : index
        var width: CGFloat = 0, height: CGFloat = 0
        for offset in 0..<(twoPages ? 2 : 1) {
            guard let item = document.page(at: start + offset) else { continue }
            let box = item.bounds(for: .cropBox)
            let rotated = item.rotation % 180 != 0
            width += rotated ? box.height : box.width
            height = max(height, rotated ? box.width : box.height)
        }
        guard width > 0, height > 0 else { return view.scaleFactorForSizeToFit }
        return max(0.01, min((view.bounds.width - 32) / width, (view.bounds.height - 24) / height))
    }

    /// Observe the native scroll view without replacing its delegate or gestures.
    /// Only the few visible pages are inspected; page context changes once at the midpoint.
    func observeScrolling(in view: UIView) {
        if let scroll = view as? UIScrollView {
            pencilNavigation.observe(scroll)
            scrollView = scroll
            scroll.panGestureRecognizer.addTarget(self, action: #selector(userMovedScore(_:)))
            scroll.pinchGestureRecognizer?.addTarget(self, action: #selector(userMovedScore(_:)))
            scroll.panGestureRecognizer.require(toFail: annotationPan)
            scroll.panGestureRecognizer.require(toFail: voiceDrag)
            scrollObservation = scroll.observe(\.contentOffset, options: .new) { [weak self] _, _ in
                Task { @MainActor in self?.schedulePageUpdate() }
            }
            return
        }
        for child in view.subviews where scrollObservation == nil { observeScrolling(in: child) }
    }

    @objc func userMovedScore(_ recognizer: UIGestureRecognizer) {
        if recognizer.state == .began {
            pendingTurnPage = nil
            if recognizer === scrollView?.pinchGestureRecognizer { fitsWholePage = false }
            onUserNavigation?()
        }
    }
}
