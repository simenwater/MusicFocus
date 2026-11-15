import PDFKit
import PencilKit
import SwiftUI
import Combine

/// Whichever reader surface owns keyboard focus must handle pedal keys before
/// PencilKit/scroll-view arrow navigation. Keep all other system shortcuts intact.
enum ScorePageKeys {
    static let next = [UIKeyCommand.inputDownArrow, UIKeyCommand.inputRightArrow, UIKeyCommand.inputPageDown, " "]
    static let previous = [UIKeyCommand.inputUpArrow, UIKeyCommand.inputLeftArrow, UIKeyCommand.inputPageUp]

    /// Dedicated page keys can arrive as HID presses instead of key commands.
    /// Modified keys retain their normal text-selection/application shortcuts.
    static func direction(for keyCode: UIKeyboardHIDUsage, modifiers: UIKeyModifierFlags) -> Int? {
        guard modifiers.intersection([.command, .control, .alternate, .shift]).isEmpty else { return nil }
        switch keyCode {
        case .keyboardPageDown: return 1
        case .keyboardPageUp: return -1
        default: return nil
        }
    }

    static func unhandled(_ presses: Set<UIPress>, handler: ((Int) -> Void)?, invoke: Bool) -> Set<UIPress> {
        guard let handler else { return presses }
        return Set(presses.filter { press in
            guard let key = press.key, let delta = direction(for: key.keyCode, modifiers: key.modifierFlags) else { return true }
            if invoke { handler(delta) }
            return false
        })
    }

    static func commands(next forward: Selector, previous backward: Selector, retaining system: [UIKeyCommand]?) -> [UIKeyCommand] {
        let pedals: [(String, UIKeyModifierFlags, Selector)] =
            next.map { ($0, [], forward) } + previous.map { ($0, [], backward) }
        return pedals.map { input, modifiers, action in
            let command = UIKeyCommand(input: input, modifierFlags: modifiers, action: action)
            command.wantsPriorityOverSystemBehavior = true
            return command
        } + (system ?? []).filter { command in
            !pedals.contains { $0.0 == command.input && $0.1 == command.modifierFlags }
        }
    }
}

/// SwiftUI creates the view before assigning its final size. Restore position after layout.
final class ScorePDFViewport: PDFView {
    var didChangeSize: (() -> Void)?
    weak var undoBridge: UndoManager?
    override var undoManager: UndoManager? { undoBridge ?? super.undoManager }
    /// UIKit sends ⌘Z and the three-finger undo swipe to the first responder's
    /// undo manager; SwiftUI otherwise leaves no responder while annotating.
    override var canBecomeFirstResponder: Bool { undoBridge != nil || onPageKey != nil }
    // Hardware page-turn/undo focus must not open a software keyboard when
    // UIKit restores this responder around a menu. Text-edit alerts own theirs.
    private lazy var pedalInputView = UIView(frame: .zero)
    override var inputView: UIView? { pedalInputView }

    /// Bluetooth page-turn pedals (AirTurn, PageFlip and similar) are keyboards.
    /// Depending on their mode they send arrows, Page Up/Down or Space.
    var onPageKey: ((Int) -> Void)?
    static let nextPageInputs = ScorePageKeys.next
    static let previousPageInputs = ScorePageKeys.previous
    override var keyCommands: [UIKeyCommand]? {
        guard onPageKey != nil else { return super.keyCommands }
        return ScorePageKeys.commands(next: #selector(nextPageKey), previous: #selector(previousPageKey), retaining: super.keyCommands)
    }
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let other = ScorePageKeys.unhandled(presses, handler: onPageKey, invoke: true)
        if !other.isEmpty { super.pressesBegan(other, with: event) }
    }
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let other = ScorePageKeys.unhandled(presses, handler: onPageKey, invoke: false)
        if !other.isEmpty { super.pressesEnded(other, with: event) }
    }
    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let other = ScorePageKeys.unhandled(presses, handler: onPageKey, invoke: false)
        if !other.isEmpty { super.pressesCancelled(other, with: event) }
    }
    @objc func nextPageKey() { onPageKey?(1) }
    @objc func previousPageKey() { onPageKey?(-1) }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, canBecomeFirstResponder else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil, !self.isFirstResponder else { return }
            self.becomeFirstResponder()
        }
    }
    // The Edit menu's ⌘Z / ⇧⌘Z and the undo gestures send undo:/redo: down the
    // responder chain; PDFView has no handler of its own for them.
    @objc func undo(_ sender: Any?) { undoBridge?.undo() }
    @objc func redo(_ sender: Any?) { undoBridge?.redo() }
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(nextPageKey) || action == #selector(previousPageKey) { return onPageKey != nil }
        if action == #selector(undo(_:)) { return undoBridge?.canUndo ?? false }
        if action == #selector(redo(_:)) { return undoBridge?.canRedo ?? false }
        return super.canPerformAction(action, withSender: sender)
    }
    private var previousSize = CGSize.zero
    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != previousSize else { return }
        previousSize = bounds.size
        didChangeSize?()
    }
}

final class ScoreCanvas: PKCanvasView {
    let pageNumber: Int
    /// PencilKit takes keyboard focus when changing tools or drawing. Forward the
    /// pedals from here too, rather than stealing focus during an active stroke.
    var onPageKey: ((Int) -> Void)?
    override var keyCommands: [UIKeyCommand]? {
        guard onPageKey != nil else { return super.keyCommands }
        return ScorePageKeys.commands(next: #selector(nextPageKey), previous: #selector(previousPageKey), retaining: super.keyCommands)
    }
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let other = ScorePageKeys.unhandled(presses, handler: onPageKey, invoke: true)
        if !other.isEmpty { super.pressesBegan(other, with: event) }
    }
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let other = ScorePageKeys.unhandled(presses, handler: onPageKey, invoke: false)
        if !other.isEmpty { super.pressesEnded(other, with: event) }
    }
    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let other = ScorePageKeys.unhandled(presses, handler: onPageKey, invoke: false)
        if !other.isEmpty { super.pressesCancelled(other, with: event) }
    }
    @objc func nextPageKey() { onPageKey?(1) }
    @objc func previousPageKey() { onPageKey?(-1) }
    /// PencilKit registers every stroke with the canvas's undo manager and UIKit
    /// sends ⌘Z / three-finger swipe / shake there. Without this, those undid ink
    /// behind the reader's back, and the reader's Undo then brought it back.
    weak var undoBridge: UndoManager?
    override var undoManager: UndoManager? { undoBridge ?? super.undoManager }
    // Drawing makes the canvas first responder. PencilKit's own undo:/redo:
    // validate against its private stack (now always empty), which disabled ⌘Z.
    @objc func undo(_ sender: Any?) { undoBridge?.undo() }
    @objc func redo(_ sender: Any?) { undoBridge?.redo() }
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(nextPageKey) || action == #selector(previousPageKey) { return onPageKey != nil }
        if undoBridge != nil, action == #selector(undo(_:)) { return undoBridge?.canUndo ?? false }
        if undoBridge != nil, action == #selector(redo(_:)) { return undoBridge?.canRedo ?? false }
        return super.canPerformAction(action, withSender: sender)
    }
    init(pageNumber: Int) { self.pageNumber = pageNumber; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// PencilKit can re-enable its pinch when a tool/window changes. Keep its
    /// zoom range fixed to PDFKit's current scale as well as refusing navigation.
    /// This still lets PencilKit render ink at native resolution at any PDF zoom.
    func followPageZoom(_ zoom: CGFloat) {
        if minimumZoomScale > zoom { minimumZoomScale = zoom }
        if maximumZoomScale != zoom { maximumZoomScale = zoom }
        if minimumZoomScale != zoom { minimumZoomScale = zoom }
        if abs(zoomScale - zoom) > 0.0001 { setZoomScale(zoom, animated: false) }
        pinchGestureRecognizer?.isEnabled = false
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === pinchGestureRecognizer || gestureRecognizer === panGestureRecognizer { return false }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }
}

/// Canvas coordinates remain in crop-box points across zooming and orientation changes.
final class ScorePageOverlay: UIView {
    let canvas: ScoreCanvas
    let importedInk = ScoreImportedInkView(frame: .zero)
    weak var importedPage: PDFPage?
    var routesToPDFAnnotation: ((CGPoint) -> Bool)?
    var routesToFingering: ((CGPoint) -> Bool)?
    var drawingEnabled = false
    private let pageSize: CGSize
    private weak var viewport: UIView?
    init(pageSize: CGSize, pageNumber: Int) {
        self.pageSize = pageSize
        canvas = ScoreCanvas(pageNumber: pageNumber)
        super.init(frame: CGRect(origin: .zero, size: pageSize))
        backgroundColor = .clear
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.isScrollEnabled = false
        canvas.contentSize = pageSize
        canvas.contentInsetAdjustmentBehavior = .never
        // isScrollEnabled disables panning, but PencilKit's pinch recognizer
        // remains enabled. It can zoom only the ink while PDFKit stays still.
        // PDFKit owns touch navigation; updateViewport alone sets canvas zoom
        // programmatically so the ink stays sharp and registered to the page.
        canvas.followPageZoom(1)
        canvas.showsHorizontalScrollIndicator = false
        canvas.showsVerticalScrollIndicator = false
        canvas.overrideUserInterfaceStyle = .light // Ink colors belong to white PDF paper.
        clipsToBounds = true
        canvas.accessibilityIdentifier = "scoreCanvas-\(pageNumber)"
        addSubview(importedInk)
        addSubview(canvas)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard drawingEnabled else { return nil } // reading: PDFKit owns every other touch
        // Recognized digit groups are moved by the PDF-level finger recognizer.
        // Keep these contacts away from PencilKit's internal selection gestures;
        // Pencil contacts still use the ordinary handwriting path.
        let contact = event?.allTouches?.filter { $0.phase == .began }.min {
            let a = $0.location(in: self), b = $1.location(in: self)
            return hypot(a.x-point.x, a.y-point.y) < hypot(b.x-point.x, b.y-point.y)
        }
        if let contact, contact.type != .pencil,
           routesToFingering?(point) == true { return nil }
        // Imported PDF annotations belong to the PDF editor, not PencilKit's lasso.
        // Send their initial contact below the canvas so those recognizers cannot compete.
        if routesToPDFAnnotation?(point) == true { return nil }
        guard ScoreGestureRouting.routesToCanvas(point: point, event: event, in: self,
                                                  fingerDrawing: canvas.drawingPolicy == .anyInput) else { return nil }
        return super.hitTest(point, with: event)
    }
    func drawingPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x * pageSize.width / max(bounds.width, 0.01),
                y: point.y * pageSize.height / max(bounds.height, 0.01))
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        if let viewport { updateViewport(in: viewport) }
        else { canvas.frame = bounds }
    }

    /// PDFKit scales its overlay externally. Let PencilKit render at that same zoom,
    /// then counter-scale its view so its Metal surface has one point per screen point.
    /// Crop the canvas to the viewport: a 5x zoom must not allocate a 5x full-page surface.
    /// Drawing coordinates stay in the original crop box; no strokes are transformed or resaved.
    func updateViewport(in viewport: UIView) {
        self.viewport = viewport
        guard superview != nil, pageSize.width > 0, pageSize.height > 0, bounds.width > 0 else { return }
        let visible = convert(viewport.bounds, from: viewport).intersection(bounds)
        guard !visible.isNull, visible.width > 0, visible.height > 0 else { return }
        let origin = convert(CGPoint.zero, to: viewport)
        let unit = convert(CGPoint(x: 1, y: 0), to: viewport)
        let displayScale = hypot(unit.x - origin.x, unit.y - origin.y)
        let pageScale = bounds.width / pageSize.width
        let zoom = displayScale * pageScale
        guard displayScale.isFinite, displayScale > 0, zoom.isFinite, (0.1...20).contains(zoom) else { return }
        let size = CGSize(width: visible.width * displayScale, height: visible.height * displayScale)
        let offset = CGPoint(x: (visible.minX - bounds.minX) * displayScale,
                             y: (visible.minY - bounds.minY) * displayScale)
        let center = CGPoint(x: visible.midX, y: visible.midY)
        let transform = CGAffineTransform(scaleX: 1 / displayScale, y: 1 / displayScale)
        if importedInk.bounds.size != size { importedInk.bounds.size = size }
        if importedInk.center != center { importedInk.center = center }
        if importedInk.transform != transform { importedInk.transform = transform }
        if let page = importedPage, let pdfView = viewport as? PDFView {
            importedInk.update(page: page, in: pdfView)
        }
        if canvas.bounds.size != size { canvas.bounds.size = size }
        if canvas.center != center { canvas.center = center }
        if canvas.transform != transform { canvas.transform = transform }
        canvas.followPageZoom(zoom)
        let contentSize = CGSize(width: pageSize.width * zoom, height: pageSize.height * zoom)
        if canvas.contentSize != contentSize { canvas.contentSize = contentSize }
        if canvas.contentOffset != offset { canvas.setContentOffset(offset, animated: false) }
    }

}

/// UndoManager facade over the reader's own history. Registrations from PencilKit
/// or PDFKit are ignored (registration stays disabled); system undo and redo
/// call the reader, so buttons and gestures always walk the same steps.
final class ScoreUndoBridge: UndoManager {
    weak var reader: ScoreReaderController?

    override init() {
        super.init()
        disableUndoRegistration()
    }

    override func enableUndoRegistration() {}
    override var canUndo: Bool { MainActor.assumeIsolated { reader?.canUndo ?? false } }
    override var canRedo: Bool { MainActor.assumeIsolated { reader?.canRedo ?? false } }
    override func undo() { MainActor.assumeIsolated { reader?.undo() } }
    override func redo() { MainActor.assumeIsolated { reader?.redo() } }
    override func undoNestedGroup() { undo() }
}

/// A normal UIKit container keeps tag touch/accessibility routing outside PDFKit.
final class ScoreReaderViewport: UIView {
    let pdfView = ScorePDFViewport()
    override init(frame: CGRect) {
        super.init(frame: frame)
        pdfView.frame = bounds
        pdfView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(pdfView)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
