import UIKit

/// Only a selected editable object contact is accepted by its delegate. A tap
/// stays available to the normal correction tap; a second finger cancels the
/// move so PDFKit can zoom. Updates follow the actual touch sample, keeping
/// the preview and final commit in one lifecycle even around native ink input.
final class ScoreObjectDragRecognizer: UIGestureRecognizer {
    var onUpdate: ((ScoreObjectDragRecognizer) -> Void)?
    var onCancel: (() -> Void)?
    private var touch: UITouch?
    private var origin = CGPoint.zero
    private var moving = false

    func translation(in view: UIView?) -> CGPoint {
        guard let touch else { return .zero }
        let start = view?.convert(origin, from: touch.window) ?? origin
        let point = touch.location(in: view)
        return CGPoint(x: point.x-start.x, y: point.y-start.y)
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard !hasMultipleFingers(event), touch == nil, touches.count == 1, let first = touches.first else { cancel(); return }
        touch = first; origin = first.location(in: first.window)
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard !hasMultipleFingers(event) else { cancel(); return }
        guard touch != nil, state == .possible || state == .began || state == .changed else { return }
        let offset = translation(in: view)
        if !moving {
            guard hypot(offset.x, offset.y) >= 3 else { return }
            state = .began
            guard state == .began else { return }
            moving = true
        } else { state = .changed }
        onUpdate?(self)
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        if moving { state = .ended; moving = false; onUpdate?(self) }
        else { state = .failed }
    }
    private func hasMultipleFingers(_ event: UIEvent) -> Bool {
        (event.allTouches?.filter { $0.type != .pencil && $0.phase != .ended && $0.phase != .cancelled }.count ?? 0) > 1
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { cancel() }
    private func cancel() {
        let hadMove = moving; moving = false
        state = hadMove ? .cancelled : .failed
        if hadMove { onCancel?() }
    }
    override func reset() {
        if moving { moving = false; onCancel?() }
        touch = nil; super.reset()
    }
    override func canPrevent(_ other: UIGestureRecognizer) -> Bool {
        other is UIPinchGestureRecognizer ? false : super.canPrevent(other)
    }
    override func canBePrevented(by other: UIGestureRecognizer) -> Bool {
        other is UIPinchGestureRecognizer || other.numberOfTouches > 1
    }
}

/// One owner for navigation: PDFKit handles fingers; PencilKit handles the pen.
/// Do not count a palm alongside a Pencil as a two-finger navigation gesture.
enum ScoreGestureRouting {
    static func routesToCanvas(type: UITouch.TouchType, fingerCount: Int, fingerDrawing: Bool) -> Bool {
        if type == .pencil { return true }
        return fingerDrawing && ((type == .direct && fingerCount == 1) || type == .indirectPointer)
    }

    static func routesToCanvas(point: CGPoint, event: UIEvent?, in view: UIView, fingerDrawing: Bool) -> Bool {
        guard let touches = event?.allTouches, !touches.isEmpty else { return true }
        let active = touches.filter { $0.phase != .ended && $0.phase != .cancelled }
        let beginning = active.filter { $0.phase == .began }
        // hitTest is called for each new contact. A Pencil already on the page
        // must not cause a newly arriving finger to be routed to the ink canvas.
        let candidates = beginning.isEmpty ? active : beginning
        guard let touch = candidates.min(by: {
            let a = $0.location(in: view), b = $1.location(in: view)
            return hypot(a.x - point.x, a.y - point.y) < hypot(b.x - point.x, b.y - point.y)
        }) else { return false }
        return routesToCanvas(type: touch.type, fingerCount: active.filter { $0.type == .direct }.count,
                              fingerDrawing: fingerDrawing)
    }
}

/// Observes Pencil contact simultaneously, without delaying or cancelling ink.
/// A tool's didBegin callback alone is too late for a palm touching at pen-down.
final class ScorePencilContactRecognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
    var contactChanged: ((Bool) -> Void)?
    private var contacting = false

    init() {
        super.init(target: nil, action: nil)
        delegate = self
        allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        requiresExclusiveTouchType = false
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    private func setContact(_ value: Bool) {
        guard contacting != value else { return }
        contacting = value
        contactChanged?(value)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        touch.type == .pencil
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) { setContact(true); state = .began }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) { state = .changed }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { setContact(false); state = .ended }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { setContact(false); state = .cancelled }
    override func reset() { super.reset(); setContact(false) }
    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
}

/// Freeze only navigation while the Pencil is down. Keep the scroll view and
/// ink canvas alive, and restore the original settings when the reader detaches.
@MainActor
final class ScorePencilNavigationGuard {
    let contact = ScorePencilContactRecognizer()
    private weak var scrollView: UIScrollView?
    private var previous: (panTypes: [NSNumber], pinchTypes: [NSNumber]?)?
    private var suspended: [(UIGestureRecognizer, Bool)] = []
    private(set) var pencilDown = false
    var editing = false {
        didSet {
            contact.isEnabled = editing
            if !editing { setPencilDown(false) }
        }
    }

    init() {
        contact.isEnabled = false
        contact.contactChanged = { [weak self] in self?.setPencilDown($0) }
    }

    func observe(_ scroll: UIScrollView) {
        guard scrollView !== scroll else { return }
        restoreNavigation()
        restoreSettings()
        scrollView = scroll
        previous = (scroll.panGestureRecognizer.allowedTouchTypes,
                    scroll.pinchGestureRecognizer?.allowedTouchTypes)
        // Native navigation must never interpret a Pencil stroke as a scroll.
        let navigationTypes = [UITouch.TouchType.direct, .indirect, .indirectPointer].map { NSNumber(value: $0.rawValue) }
        scroll.panGestureRecognizer.allowedTouchTypes = navigationTypes
        scroll.pinchGestureRecognizer?.allowedTouchTypes = navigationTypes
        if pencilDown { suspendNavigation() }
    }

    func setPencilDown(_ down: Bool) {
        let next = down && editing
        guard next != pencilDown else { return }
        pencilDown = next
        if next { suspendNavigation() } else { restoreNavigation() }
    }

    private func suspendNavigation() {
        guard suspended.isEmpty, let scroll = scrollView else { return }
        suspended = [scroll.panGestureRecognizer, scroll.pinchGestureRecognizer].compactMap { $0 }.map { ($0, $0.isEnabled) }
        for (gesture, _) in suspended { gesture.isEnabled = false }
    }

    private func restoreNavigation() {
        for (gesture, enabled) in suspended { gesture.isEnabled = enabled }
        suspended.removeAll()
    }

    private func restoreSettings() {
        guard let scroll = scrollView, let previous else { return }
        scroll.panGestureRecognizer.allowedTouchTypes = previous.panTypes
        if let types = previous.pinchTypes { scroll.pinchGestureRecognizer?.allowedTouchTypes = types }
    }

    func detach() {
        editing = false
        contact.view?.removeGestureRecognizer(contact)
        restoreNavigation()
        restoreSettings()
        scrollView = nil; previous = nil
    }
}
