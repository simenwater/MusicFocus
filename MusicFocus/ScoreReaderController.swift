import PDFKit
import PencilKit
import SwiftUI
import Combine

/// Holds the PDF for the lifetime of the reader. SwiftUI timer updates never replace it.
@MainActor
final class ScoreReaderController: NSObject, ObservableObject, @preconcurrency PDFPageOverlayViewProvider, PKCanvasViewDelegate, UIGestureRecognizerDelegate {
    @Published private(set) var ready = false
    @Published private(set) var pages: [Int] = []
    @Published private(set) var hasUnsavedChanges = false
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published var errorMessage: String?
    @Published var editing = false { willSet { finishInkInput() } didSet { cancelFingering(); clearSelectionForCurrentTool(); applyTool() } }
    @Published var fingerDrawing = false { didSet { applyTool() } }
    @Published private(set) var preferredPenTool = ScoreInkTool.pen
    @Published var tool = ScoreInkTool.pen {
        willSet { finishInkInput() }
        didSet {
            if tool.isPen {
                preferredPenTool = tool
                inkDefaults.set(tool.rawValue, forKey: "score.penMode.v1")
            }
            cancelFingering(); clearSelectionForCurrentTool(); applyTool()
        }
    }
    @Published var selectedFingering: ScoreFingeringSelection?
    @Published private(set) var selectedCoverID: UUID?
    @Published private(set) var coverColor = ScoreAnnotationColor(.white)
    let coverEditor = ScoreCoverEditor()
    let inkSelectionEditor = ScoreInkSelectionEditor()
    @Published private(set) var selectedInkCount = 0
    func deleteSelectedInk() { inkSelectionEditor.deleteSelection() }
    private var inkMovePreview: (page: Int, background: PKDrawing)?
    var selectedCover: ScorePageCover? { annotationEdits.covers.first { $0.id == selectedCoverID } }

    func selectCover(_ id: UUID?) {
        selectedFingering = nil
        select(nil)
        coverEditor.select(id)
    }

    func saveCover(_ cover: ScorePageCover) {
        guard cover.isValid, let page = document?.page(at: cover.page-1) else { return }
        finishInkInput()
        let before = annotationEdits
        var after = before
        let value = cover.constrained(to: page.bounds(for: .cropBox))
        if let index = after.covers.firstIndex(where: { $0.id == value.id }) { after.covers[index] = value }
        else { after.covers.append(value) }
        guard before != after else { return }
        updateAnnotations(after)
        record(.annotations(before, after))
    }

    func deleteSelectedCover() {
        guard let id = selectedCoverID else { return }
        finishInkInput()
        let before = annotationEdits
        var after = before; after.covers.removeAll { $0.id == id }
        guard before != after else { return }
        updateAnnotations(after); record(.annotations(before,after)); selectCover(nil)
    }

    func chooseCoverColor(_ color: UIColor) {
        coverColor = ScoreAnnotationColor(color)
        coverEditor.color = coverColor
        if let data = try? JSONEncoder().encode(coverColor) { inkDefaults.set(data,forKey: "score.pageCover.color.v1") }
        if var cover = selectedCover { cover.color = coverColor; saveCover(cover) }
    }

    @Published private(set) var fingeringSizeMode: ScoreFingeringSizeMode = .first
    @Published private(set) var fixedFingeringHeight = ScoreFingeringSizing.defaultHeight
    @Published private(set) var fingeringHeight: Double?
    @Published private(set) var fingeringCoverEnabled = false
    @Published private(set) var fingeringCoverStyle = ScoreFingeringCover()

    func setFingeringCoverEnabled(_ enabled: Bool) {
        cancelFingering()
        fingeringCoverEnabled = enabled
        inkDefaults.set(enabled, forKey: ScoreFingeringCover.enabledKey)
    }

    func setFingeringCoverStyle(_ style: ScoreFingeringCover) {
        cancelFingering()
        fingeringCoverStyle = style.validated
        if let data = try? JSONEncoder().encode(fingeringCoverStyle) { inkDefaults.set(data, forKey: ScoreFingeringCover.styleKey) }
    }

    func setFingeringSizeMode(_ mode: ScoreFingeringSizeMode) {
        guard mode != fingeringSizeMode else { return }
        cancelFingering()
        fingeringSizeMode = mode
        inkDefaults.set(mode.rawValue, forKey: ScoreFingeringSizing.modeKey)
    }

    func setFixedFingeringHeight(_ height: Double) {
        guard height.isFinite else { return }
        let value = min(ScoreFingeringSizing.fixedHeightRange.upperBound, max(ScoreFingeringSizing.fixedHeightRange.lowerBound, height))
        guard value != fixedFingeringHeight else { return }
        cancelFingering()
        fixedFingeringHeight = value
        inkDefaults.set(value, forKey: ScoreFingeringSizing.fixedHeightKey)
    }

    func resetFingeringSize() {
        cancelFingering()
        fingeringHeight = nil
        if let score { inkDefaults.removeObject(forKey: ScoreFingeringSizing.heightKey(scoreID: score.id)) }
    }

    func rememberFingeringSize(_ replacement: ScoreFingeringReplacement) {
        guard fingeringSizeMode == .first, fingeringHeight == nil, !replacement.preservesDigitSize, let score else { return }
        let height = ScoreFingeringSizing.digitBounds(replacement).height
        guard ScoreFingeringSizing.validHeight(height) else { return }
        fingeringHeight = height
        inkDefaults.set(height, forKey: ScoreFingeringSizing.heightKey(scoreID: score.id))
    }
    var fingeringMarks: [Int: [ScoreFingeringMark]] = [:]
    var dirtyFingerings = false
    @Published var voiceNotes: [ScoreVoiceNote] = []
    @Published var selectedVoiceNote: ScoreVoiceNote?
    @Published var voiceEditorExpanded = false
    @Published var movingVoiceID: UUID?
    @Published var voiceColor = ScoreAnnotationColor(.systemPurple)
    var dirtyVoiceNotes = false
    let voiceLayer = ScoreVoicePinLayer()
    private lazy var voiceTap = UITapGestureRecognizer(target: self, action: #selector(tappedVoice(_:)))
    lazy var voiceDrag = ScoreVoicePanRecognizer(target: self, action: #selector(draggedVoice(_:)))
    private lazy var voiceHold = ScoreVoiceHoldRecognizer(target: self, action: #selector(heldVoice(_:)))
    var voiceDragPreview: ScoreVoiceNote?
    var voiceDragDidMove = false
    var voiceDragID: UUID?
    var voiceDragGrabOffset = CGPoint.zero
    let voiceAudio = ScoreVoiceAudio()
    private var voiceObservation: AnyCancellable?
    private var voiceBusy = false

    let fingeringRecognition: ScoreFingeringRecognition?
    var fingeringTask: Task<Void, Never>?
    var fingeringComputation: Task<[ScoreFingeringReplacement], Never>?
    var fingeringRevision = 0
    var recentFingering: [Int: [UUID: Date]] = [:]
    var newFingeringIDs: [Int: Set<UUID>] = [:]
    var endedFingeringInput: [Int: Data] = [:]
    @Published private var inkStyles: [String: ScoreInkStyle] = [:]
    @Published private(set) var inkColorPresets = ScoreInkPalette.initialPresets
    let inkDefaults: UserDefaults
    private static let inkSettingsKey = "score.inkStyles.v1"

    init(inkDefaults: UserDefaults = .standard,
         fingeringRecognition: ScoreFingeringRecognition? = nil) {
        self.inkDefaults = inkDefaults
        self.fingeringRecognition = fingeringRecognition
        super.init()
        undoBridge.reader = self
        fingeringSizeMode = ScoreFingeringSizing.mode(in: inkDefaults)
        fixedFingeringHeight = ScoreFingeringSizing.fixedHeight(in: inkDefaults)
        fingeringCoverEnabled = inkDefaults.bool(forKey: ScoreFingeringCover.enabledKey)
        fingeringCoverStyle = ScoreFingeringCover.saved(in: inkDefaults)
        if let raw = inkDefaults.string(forKey: "score.penMode.v1"), let saved = ScoreInkTool(rawValue: raw), saved.isPen {
            preferredPenTool = saved; tool = saved
        }
        if let data = inkDefaults.data(forKey: "score.pageCover.color.v1"),
           let color = try? JSONDecoder().decode(ScoreAnnotationColor.self,from: data),
           [color.red,color.green,color.blue].allSatisfy({ $0.isFinite && (0...1).contains($0) }) { coverColor = color }
        coverEditor.color = coverColor
        coverEditor.onSelection = { [weak self] id in
            guard let self else { return }
            if id != nil { inkSelectionEditor.clear(); selectedFingering = nil; select(nil) }
            if selectedCoverID != id { selectedCoverID = id }
        }
        coverEditor.onCommit = { [weak self] cover in self?.saveCover(cover) }
        coverEditor.onPreview = { [weak self] covers in
            guard let self else { return }
            annotations?.applyCovers(covers)
            if let view = pdfView {
                view.setNeedsDisplay()
                for overlay in overlays.values { overlay.updateViewport(in: view) }
            }
        }
        voiceObservation = voiceAudio.$recording.combineLatest(voiceAudio.$playing, voiceAudio.$preparing)
            .map { $0 || $1 || $2 }.removeDuplicates().sink { [weak self] busy in
                self?.voiceBusy = busy; self?.updateUndoState()
            }
        showsPageBadges = inkDefaults.object(forKey: Self.badgeSettingsKey) as? Bool ?? true
        if let data = inkDefaults.data(forKey: ScoreInkPalette.defaultsKey),
           let colors = try? JSONDecoder().decode([ScoreAnnotationColor].self, from: data) {
            inkColorPresets = ScoreInkPalette.validated(colors)
        }
        if let data = inkDefaults.data(forKey: Self.inkSettingsKey),
           let saved = try? JSONDecoder().decode([String: ScoreInkStyle].self, from: data) {
            for tool in ScoreInkTool.allCases where tool.inkType != nil {
                if let value = saved[tool.rawValue] { inkStyles[tool.rawValue] = value.validated(for: tool) }
            }
        }
    }

    var inkStyle: ScoreInkStyle { inkStyles[tool.rawValue] ?? .initial(for: tool) }
    var currentColor: UIColor {
        if tool == .cover || selectedCover != nil { return (selectedCover?.color ?? coverColor).uiColor }
        if tool == .voice { return (selectedVoiceNote?.color ?? voiceColor).uiColor }
        if let key = selectedAnnotation, tool == .select, let annotation = annotations?.live[key] {
            return annotation.color.withAlphaComponent(1)
        }
        return inkStyle.color.uiColor
    }
    var currentOpacity: Double {
        if let key = selectedAnnotation, tool == .select, let entry = annotations?.entry(key) {
            return annotationEdits.items[key]?.opacity ?? Double(entry.opacity)
        }
        return inkStyle.opacity
    }
    var canSetOpacity: Bool { tool.inkType != nil || (tool == .select && selectedAnnotation.flatMap { annotations?.live[$0]?.type } == "Ink") }
    func updateInkStyle(_ change: (inout ScoreInkStyle) -> Void) {
        guard tool.inkType != nil else { return }
        var style = inkStyle; change(&style)
        inkStyles[tool.rawValue] = style.validated(for: tool)
        if let data = try? JSONEncoder().encode(inkStyles) { inkDefaults.set(data, forKey: Self.inkSettingsKey) }
        applyTool(restoreKeyboardFocus: false)
    }
    func chooseWidth(_ width: Double) { updateInkStyle { $0.width = width } }
    func setInkColorPreset(_ color: UIColor, at index: Int) {
        guard inkColorPresets.indices.contains(index) else { return }
        var value = ScoreAnnotationColor(color)
        guard [value.red, value.green, value.blue].allSatisfy(\.isFinite) else { return }
        value.red = min(1, max(0, value.red))
        value.green = min(1, max(0, value.green))
        value.blue = min(1, max(0, value.blue))
        let old = inkColorPresets[index]
        guard value != old else { return }
        let followsActivePen = tool.inkType != nil && ScoreAnnotationColor(currentColor) == old
        inkColorPresets[index] = value
        if let data = try? JSONEncoder().encode(inkColorPresets) {
            inkDefaults.set(data, forKey: ScoreInkPalette.defaultsKey)
        }
        // Editing the active pen's preset updates its next stroke. Editing a
        // palette must never recolor a selected, existing PDF annotation.
        if followsActivePen { chooseColor(value.uiColor) }
    }
    func chooseOpacity(_ opacity: Double) {
        let opacity = min(1, max(0.1, opacity.isFinite ? opacity : 1))
        if let key = selectedAnnotation, tool == .select, canSetOpacity {
            editAnnotation(key) { $0.opacity = opacity }
        } else { updateInkStyle { $0.opacity = opacity } }
    }
    @Published var twoPages = false { didSet { updateLayout() } }
    /// Practice tag in each page's corner (hidden while annotating).
    @Published var showsPageBadges = true {
        didSet {
            inkDefaults.set(showsPageBadges, forKey: Self.badgeSettingsKey)
            updatePageBadges()
        }
    }
    /// Page whose practice details were asked for by tapping its tag.
    @Published var badgePage: Int?
    private static let badgeSettingsKey = "score.pageBadges.v1"
    private var pageBadges: [Int: ScorePageBadgeInfo] = [:]
    private let badgeLayer = ScorePageBadgeLayer()
    private(set) var document: PDFDocument?
    var score: LibraryScore?
    var disk: ScoreLibraryDisk?
    weak var pdfView: PDFView?
    var overlays: [PDFPage: ScorePageOverlay] = [:]
    // PDFKit can retain and reuse an offscreen overlay without asking the provider
    // for it again. Keep weak references so history/sync updates its ink buffer too.
    private let liveOverlays = NSHashTable<ScorePageOverlay>.weakObjects()
    var drawings: [Int: Data] = [:]
    var dirty: [Int: Data] = [:]
    private var writeTask: Task<Void, Never>?
    private weak var activeCanvas: ScoreCanvas?
    private var pageObservers: [NSObjectProtocol] = []
    var scrollObservation: NSKeyValueObservation?
    weak var scrollView: UIScrollView?
    /// The user scrolled, zoomed or turned the page (not code). Live sync stops following.
    var onUserNavigation: (() -> Void)?
    private var updateScheduled = false
    var pendingInitialPage: Int?
    var pendingTurnPage: Int?
    var fitsWholePage = true
    var fittedScale: CGFloat?
    var viewportSize = CGSize.zero
    private(set) var annotations: ScorePDFAnnotations?
    var annotationEdits = ScoreAnnotationEdits()
    var dirtyEdits = false
    @Published var selectedAnnotation: String?
    let selectionLayer = CAShapeLayer()
    let pencilNavigation = ScorePencilNavigationGuard()
    private lazy var fingeringTap = UITapGestureRecognizer(target: self, action: #selector(selectFingeringGesture(_:)))
    private let fingeringDrag = ScoreObjectDragRecognizer()
    var fingeringDragHit: ScoreFingeringSelection?
    struct FingeringDragState {
        let selection: ScoreFingeringSelection
        let before: PKDrawing
        let overlay: ScorePageOverlay
        let origin: CGPoint
        var translation: ScoreInkTranslation
        let preview: ScoreInkDragPreview
    }
    var fingeringDragState: FingeringDragState?
    var fingeringHitCache: [Int: (data: Data, marks: [(ScoreFingeringMark, CGRect)])] = [:]
    private lazy var annotationTap = UITapGestureRecognizer(target: self, action: #selector(selectAnnotation(_:)))
    lazy var annotationPan = UIPanGestureRecognizer(target: self, action: #selector(moveAnnotation(_:)))
    private lazy var annotationEraser = UILongPressGestureRecognizer(target: self, action: #selector(eraseAnnotation(_:)))
    var gestureBefore: ScoreAnnotationEdits?
    var dragOrigin: CGPoint?
    var panStart: CGPoint?
    var panKey: String?
    var dragOffset = CGPoint.zero
    var drawingBefore: [Int: Data] = [:]
    private var applyingHistory = false
    struct EndedInkInput {
        let canvas: ObjectIdentifier
        let before: Data
        var after: Data
        let additive: Bool
    }
    private var inputIsAdditive = false
    var endedInkInput: [Int: EndedInkInput] = [:]
    // A programmatic replacement ends the old PencilKit input generation. Late
    // callbacks may acknowledge it, but cannot start a new edit on their own.
    private var replacedInkPages = Set<Int>()
    private var retiredInkIDs: [Int: Set<UUID>] = [:]
    enum Change {
        /// Pen input as the user drew it. A later fingering conversion of these
        /// strokes is merged into it, so one Undo removes the whole digit.
        case ink(Int, Data, Data)
        case drawing(Int, Data, Data)
        case annotations(ScoreAnnotationEdits, ScoreAnnotationEdits)
        case voices([ScoreVoiceNote], [ScoreVoiceNote])

        /// Pen input and other ink edits apply the same way.
        var asDrawing: Change {
            if case let .ink(page, before, after) = self { return .drawing(page, before, after) }
            return self
        }
    }
    var undoHistory: [Change] = []
    var redoHistory: [Change] = []
    /// The one undo manager the canvas and PDF view report to UIKit, so ⌘Z,
    /// the three-finger undo swipe and shake-to-undo use this history too.
    let undoBridge = ScoreUndoBridge()

    func load(score: LibraryScore, disk: ScoreLibraryDisk) async {
        guard !ready else { return }
        self.score = score; self.disk = disk
        let savedHeight = inkDefaults.double(forKey: ScoreFingeringSizing.heightKey(scoreID: score.id))
        fingeringHeight = ScoreFingeringSizing.validHeight(savedHeight) ? savedHeight : nil
        do {
            let url = disk.pdfURL(score.id)
            let edits = try await disk.annotationEdits(score.id)
            let loaded = try await Task.detached(priority: .userInitiated) {
                guard let document = PDFDocument(url: url), !document.isLocked, document.pageCount > 0 else { throw ScoreLibraryError.invalidPDF }
                let annotations = ScorePDFAnnotations(document: document, correctAppearanceForDisplay: true)
                annotations.apply(edits)
                return (document, annotations)
            }.value
            drawings = try await disk.drawings(score.id)
            fingeringMarks = (try? await disk.fingerings(score.id)) ?? [:]
            voiceNotes = try await disk.voiceNotes(score.id).map { try $0.validated(pageCount: score.pageCount) }
            annotationEdits = edits
            self.document = loaded.0
            self.annotations = loaded.1
            ready = true
        } catch { errorMessage = error.localizedDescription }
    }

    func attach(_ view: PDFView, badgeHost: UIView? = nil) {
        pdfView = view
        let host = badgeHost ?? view
        badgeLayer.frame = host.bounds
        badgeLayer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        badgeLayer.onTap = { [weak self] page in self?.badgePage = page }
        host.addSubview(badgeLayer)
        voiceLayer.frame = host.bounds
        voiceLayer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        voiceLayer.onActivate = { [weak self] id in self?.selectVoice(id) }
        host.addSubview(voiceLayer)
        (view as? ScorePDFViewport)?.undoBridge = undoBridge
        (view as? ScorePDFViewport)?.onPageKey = { [weak self] delta in self?.go(by: delta) }
        fitsWholePage = true
        fittedScale = nil
        viewportSize = .zero
        pendingInitialPage = min(max(1, score?.lastPage ?? 1), document?.pageCount ?? 1)
        (view as? ScorePDFViewport)?.didChangeSize = { [weak self] in self?.schedulePageUpdate() }
        view.backgroundColor = .secondarySystemBackground
        view.displayBox = .cropBox
        view.displayDirection = .vertical
        view.pageBreakMargins = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        view.displaysAsBook = false
        view.pageOverlayViewProvider = self
        view.document = document
        // PDFKit autoScales fits WIDTH in continuous mode, not the whole page.
        // Fit once the viewport has its real size; scrolling must never refit it.
        view.autoScales = false
        updateLayout()
        selectionLayer.strokeColor = UIColor.systemBlue.cgColor
        selectionLayer.fillColor = UIColor.systemBlue.withAlphaComponent(0.08).cgColor
        selectionLayer.lineWidth = 1.5
        selectionLayer.lineDashPattern = [5, 3]
        view.layer.addSublayer(selectionLayer)
        voiceTap.numberOfTouchesRequired = 1
        voiceDrag.maximumNumberOfTouches = 1
        voiceHold.numberOfTouchesRequired = 1
        voiceHold.minimumPressDuration = 0.45
        voiceHold.cancelsTouchesInView = false
        voiceTap.require(toFail: voiceDrag)
        voiceTap.require(toFail: voiceHold)
        annotationPan.maximumNumberOfTouches = 1
        fingeringDrag.onUpdate = { [weak self] in self?.dragFingering($0) }
        fingeringDrag.onCancel = { [weak self] in self?.finishFingeringDrag(commit: false) }
        annotationTap.require(toFail: annotationPan)
        annotationEraser.minimumPressDuration = 0
        annotationEraser.allowableMovement = .greatestFiniteMagnitude
        annotationEraser.cancelsTouchesInView = false
        for recognizer in [annotationTap, annotationPan, annotationEraser, fingeringTap, fingeringDrag, voiceTap, voiceDrag, voiceHold] {
            recognizer.delegate = self
            if recognizer === fingeringDrag { host.addGestureRecognizer(recognizer) }
            else { view.addGestureRecognizer(recognizer) }
        }
        coverEditor.covers = annotationEdits.covers
        coverEditor.attach(to: view, host: host)
        inkSelectionEditor.context = { [weak self] point in
            guard let self, let view = self.pdfView else { return nil }
            for overlay in self.overlays.values where overlay.bounds.contains(overlay.convert(point,from: view)) {
                let data = self.drawings[overlay.canvas.pageNumber] ?? PKDrawing().dataRepresentation()
                if let drawing = try? PKDrawing(data: data) { return (overlay,drawing) }
            }
            return nil
        }
        inkSelectionEditor.excludes = { [weak self] point in
            guard let self else { return true }
            return self.coverEditor.accepts(point) || self.voiceHit(at: point) != nil || self.hit(at: point) != nil
        }
        inkSelectionEditor.expandGroup = { [weak self] page,drawing,indices in
            var result = indices
            let ids = drawing.strokes.map(\.legacyFingeringID)
            let touched = Set(indices.map { ids[$0] })
            for mark in ScoreFingeringMark.active(in: drawing,marks: self?.fingeringMarks[page] ?? []) where !mark.strokeIDs.isDisjoint(with: touched) {
                result.formUnion(ids.indices.filter { mark.strokeIDs.contains(ids[$0]) })
            }
            return result
        }
        inkSelectionEditor.onPreview = { [weak self] page,background in
            guard let self else { return }
            if let background {
                self.cancelFingering()
                self.inkMovePreview = (page,background)
                self.displayDrawing(background,on: page)
            } else {
                self.inkMovePreview = nil
                if let data = self.drawings[page], let drawing = try? PKDrawing(data: data) { self.displayDrawing(drawing,on: page) }
            }
        }
        inkSelectionEditor.onSelection = { [weak self] count in
            guard let self else { return }
            if count > 0 {
                coverEditor.select(nil); select(nil)
                if selectedFingering != nil { selectedFingering = nil }
                if selectedVoiceNote != nil { selectedVoiceNote = nil }
            }
            if selectedInkCount != count { selectedInkCount = count }
        }
        inkSelectionEditor.onCommit = { [weak self] page,before,after in self?.commitInkMove(page: page,before: before,after: after) }
        inkSelectionEditor.attach(to: view,host: host)
        view.addGestureRecognizer(pencilNavigation.contact)
        applyTool()
        pageObservers = [Notification.Name.PDFViewPageChanged, .PDFViewVisiblePagesChanged, .PDFViewScaleChanged].map { name in
            NotificationCenter.default.addObserver(forName: name, object: view, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.schedulePageUpdate() }
            }
        }
        schedulePageUpdate()
    }

    func detach() {
        finishInkInput()
        coverEditor.detach()
        inkSelectionEditor.detach()
        voiceDragPreview = nil; voiceDragID = nil
        voiceLayer.removeFromSuperview()
        voiceLayer.onActivate = nil
        badgeLayer.removeFromSuperview()
        badgeLayer.onTap = nil
        cancelFingering()
        pageObservers.forEach(NotificationCenter.default.removeObserver)
        pageObservers.removeAll()
        scrollObservation = nil
        scrollView?.panGestureRecognizer.removeTarget(self, action: #selector(userMovedScore(_:)))
        scrollView?.pinchGestureRecognizer?.removeTarget(self, action: #selector(userMovedScore(_:)))
        scrollView = nil
        pencilNavigation.detach()
        (pdfView as? ScorePDFViewport)?.didChangeSize = nil
        (pdfView as? ScorePDFViewport)?.undoBridge = nil
        (pdfView as? ScorePDFViewport)?.onPageKey = nil
        pendingInitialPage = nil
        pendingTurnPage = nil
        fittedScale = nil
        viewportSize = .zero
        finishAnnotationGesture()
        selectionLayer.removeFromSuperlayer()
        for recognizer in [annotationTap, annotationPan, annotationEraser, fingeringTap, fingeringDrag, voiceTap, voiceDrag, voiceHold] { recognizer.view?.removeGestureRecognizer(recognizer) }
        pdfView?.pageOverlayViewProvider = nil
        pdfView = nil
        for overlay in liveOverlays.allObjects {
            overlay.canvas.delegate = nil
            overlay.canvas.undoBridge = nil
            overlay.canvas.onPageKey = nil
        }
        liveOverlays.removeAllObjects()
        overlays.removeAll()
        activeCanvas = nil
        drawingBefore.removeAll()
        endedInkInput.removeAll()
        replacedInkPages.removeAll()
        retiredInkIDs.removeAll()
    }

    func schedulePageUpdate() {
        guard !updateScheduled else { return }
        updateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updateScheduled = false
            guard let view = self.pdfView, let document = self.document,
                  view.bounds.width > 0, view.bounds.height > 0 else { return }
            self.preserveManualZoom(in: view)
            let resized = self.viewportSize != view.bounds.size
            self.viewportSize = view.bounds.size
            if let restoredPage = self.pendingInitialPage {
                self.pendingInitialPage = nil
                view.layoutDocumentView()
                self.go(to: restoredPage)
            } else if resized && self.fitsWholePage {
                self.fitPage()
            }
            guard let page = view.currentPage else { return }
            self.updateZoomLimits()
            if self.scrollObservation == nil { self.observeScrolling(in: view) }
            let index = document.index(for: page)
            guard index != NSNotFound else { return }
            var visibleHeights: [Int: CGFloat] = [:]
            for candidate in view.visiblePages {
                let candidateIndex = document.index(for: candidate)
                guard candidateIndex != NSNotFound else { continue }
                let rect = view.convert(candidate.bounds(for: .cropBox), from: candidate).intersection(view.bounds)
                guard !rect.isNull, rect.width > 0, rect.height > 0 else { continue }
                let group = self.twoPages ? (candidateIndex / 2) * 2 : candidateIndex
                // Compare vertical coverage: a final one-page spread must not lose
                // to two partly visible pages merely because their areas add together.
                visibleHeights[group] = max(visibleHeights[group, default: 0], rect.height)
            }
            let fallback = self.twoPages ? (index / 2) * 2 : index
            let start = visibleHeights.keys.sorted().max { visibleHeights[$0, default: 0] < visibleHeights[$1, default: 0] } ?? fallback
            let visible = Array((start + 1)...min(document.pageCount, start + (self.twoPages ? 2 : 1)))
            if self.pages != visible {
                self.pages = visible
                if let key = self.selectedAnnotation, let page = self.annotations?.entry(key)?.pageNumber, !visible.contains(page) {
                    self.selectedAnnotation = nil
                }
            }
            self.pendingTurnPage = nil
            for overlay in self.overlays.values { overlay.updateViewport(in: view) }
            self.updatePageBadges()
            self.refreshSelection()
            self.coverEditor.refresh()
            self.inkSelectionEditor.refresh()
        }
    }

    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
        if let existing = overlays[page] { return existing }
        guard let document else { return nil }
        let index = document.index(for: page) + 1
        let overlay = ScorePageOverlay(pageSize: page.bounds(for: .cropBox).size, pageNumber: index)
        overlay.importedPage = page
        if let data = drawings[index] {
            do { overlay.canvas.drawing = try PKDrawing(data: data) }
            catch {
                DispatchQueue.main.async { [weak self] in self?.errorMessage = "score.annotationReadError".localized }
                return nil
            }
        }
        overlay.canvas.delegate = self
        overlay.canvas.undoBridge = undoBridge
        overlay.canvas.onPageKey = { [weak self] delta in self?.go(by: delta) }
        overlay.routesToFingering = { [weak self, weak overlay] point in
            guard let self, let overlay, self.canMoveFingerings, let view = self.pdfView else { return false }
            // Use the same screen-space hit target as the drag recognizer, so a
            // finger near a small digit never begins a stray PencilKit stroke.
            return self.fingeringHit(at: overlay.convert(point, to: view)) != nil
        }
        overlay.routesToPDFAnnotation = { [weak self, weak overlay] point in
            guard let self, let overlay, self.editing, let view = self.pdfView else { return false }
            let pointInView = overlay.convert(point, to: view)
            if self.coverEditor.accepts(pointInView) { return true }
            guard self.tool == .select else { return false }
            if let key = self.selectedAnnotation, let annotation = self.annotations?.live[key], let page = annotation.page,
               view.convert(annotation.bounds, from: page).insetBy(dx: -5, dy: -5).contains(pointInView) { return true }
            return self.hit(at: pointInView) != nil
        }
        overlay.canvas.drawingGestureRecognizer.require(toFail: annotationPan)
        overlay.canvas.drawingGestureRecognizer.require(toFail: fingeringTap)
        overlays[page] = overlay
        liveOverlays.add(overlay)
        configure(overlay)
        return overlay
    }

    func pdfView(_ pdfView: PDFView, willDisplayOverlayView overlayView: UIView, for page: PDFPage) {
        guard self.pdfView === pdfView, let overlay = overlayView as? ScorePageOverlay else { return }
        overlays[page] = overlay
        liveOverlays.add(overlay)
        restoreDrawing(on: overlay.canvas)
        configure(overlay)
        overlay.updateViewport(in: pdfView)
    }

    func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFPage) {
        // An older overlay can finish disappearing after its replacement exists.
        if overlays[page] === overlayView { overlays.removeValue(forKey: page) }
    }

    private func setDrawing(_ drawing: PKDrawing, on canvas: ScoreCanvas) {
        let wasApplyingHistory = applyingHistory
        applyingHistory = true
        defer { applyingHistory = wasApplyingHistory }
        // iPadOS 27 can retain the rendered position of strokes whose paths/IDs
        // are unchanged but whose transforms were restored by Undo. Rebuild
        // that display generation once at commit/history boundaries, never on
        // pointer updates or while the user is writing.
        if #available(iOS 27.0, *) {
            let previous = canvas.drawing.strokes, restored = drawing.strokes
            if previous.count == restored.count,
               zip(previous,restored).contains(where: { $0.transform != $1.transform }) {
                canvas.drawing = PKDrawing()
            }
        }
        canvas.drawing = drawing
    }

    private func restoreDrawing(on canvas: ScoreCanvas) {
        if let preview = inkMovePreview, preview.page == canvas.pageNumber {
            if canvas.drawing != preview.background { setDrawing(preview.background,on: canvas) }
            return
        }
        if let move = fingeringDragState, move.selection.page == canvas.pageNumber {
            if canvas.drawing != move.translation.background { setDrawing(move.translation.background, on: canvas) }
            return
        }
        let data = drawings[canvas.pageNumber] ?? PKDrawing().dataRepresentation()
        guard let drawing = try? PKDrawing(data: data), canvas.drawing != drawing else { return }
        if drawing.strokes.isEmpty && canvas.drawing.strokes.isEmpty { return }
        setDrawing(drawing, on: canvas)
    }

    func displayDrawing(_ drawing: PKDrawing, on page: Int) {
        endedInkInput.removeValue(forKey: page)
        endedFingeringInput.removeValue(forKey: page)
        drawingBefore.removeValue(forKey: page)
        if activeCanvas?.pageNumber == page { activeCanvas = nil }
        replacedInkPages.insert(page)
        let restoredIDs = Set(drawing.strokes.map(\.fingeringID))
        for overlay in liveOverlays.allObjects where overlay.canvas.pageNumber == page {
            retiredInkIDs[page, default: []].formUnion(overlay.canvas.drawing.strokes.map(\.fingeringID))
            setDrawing(drawing, on: overlay.canvas)
        }
        // Redo and remote restoration explicitly authorize these strokes again.
        retiredInkIDs[page]?.subtract(restoredIDs)
    }

    private func currentInputDrawing(_ canvas: ScoreCanvas) -> PKDrawing {
        let drawing = canvas.drawing
        let page = canvas.pageNumber
        let retired = retiredInkIDs[page] ?? []
        var strokes = drawing.strokes.filter { !retired.contains($0.fingeringID) }
        // Erasing any component removes its cover too. Only intact versions in
        // the gesture baseline participate; older versions remain for Undo.
        if tool == .eraser || tool == .select,
           let data = drawingBefore[page] ?? endedInkInput[page]?.before ?? drawings[page],
           let before = try? PKDrawing(data: data) {
            let current = Dictionary(strokes.map { ($0.legacyFingeringID, $0) }, uniquingKeysWith: { a, _ in a })
            var removed = Set<UUID>()
            for mark in ScoreFingeringMark.active(in: before, marks: fingeringMarks[page] ?? []) where mark.cover != nil {
                guard let original = mark.strokes(in: before) else { continue }
                if mark.strokeIDs.contains(where: { current[$0] == nil || current[$0]?.mask != nil }) {
                    removed.formUnion(mark.strokeIDs)
                    retiredInkIDs[page, default: []].formUnion(original.map(\.fingeringID))
                }
            }
            if !removed.isEmpty { strokes.removeAll { removed.contains($0.legacyFingeringID) } }
        }
        guard strokes.count != drawing.strokes.count else { return drawing }
        let cleaned = PKDrawing(strokes: strokes)
        setDrawing(cleaned, on: canvas)
        return cleaned
    }

    private func commitInk(_ data: Data, page: Int) {
        guard drawings[page] != data else { return }
        drawings[page] = data
        dirty[page] = data
        queueSave()
    }

    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        guard let canvas = canvasView as? ScoreCanvas, !applyingHistory else { return }
        if activeCanvas === canvas { return }
        finishInkInput()
        selectedFingering = nil
        cancelFingering(clearRecent: false)
        let page = canvas.pageNumber
        endedFingeringInput.removeValue(forKey: page)
        endedInkInput.removeValue(forKey: page)
        // Use the model as the baseline. Assigning canvas.drawing from inside
        // didBeginUsingTool can cancel PencilKit's in-flight touch (even when
        // merely normalizing an empty drawing's archive).
        activeCanvas = canvas
        inputIsAdditive = tool.inkType != nil
        drawingBefore[page] = drawings[page] ?? PKDrawing().dataRepresentation()
    }

    func finishInkInput() {
        coverEditor.finish(commit: true)
        inkSelectionEditor.finish(commit: true)
        finishFingeringDrag(commit: true)
        if let canvas = activeCanvas { canvasViewDidEndUsingTool(canvas) }
        // A fast next stroke/tool change can precede the delegate's last update.
        // Consume the completed gesture's current buffer before closing it.
        for overlay in liveOverlays.allObjects {
            let canvas = overlay.canvas
            if endedInkInput[canvas.pageNumber]?.canvas == ObjectIdentifier(canvas) {
                canvasViewDrawingDidChange(canvas)
            }
        }
    }

    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        guard let canvas = canvasView as? ScoreCanvas, activeCanvas === canvas,
              let before = drawingBefore.removeValue(forKey: canvas.pageNumber) else { return }
        activeCanvas = nil
        let page = canvas.pageNumber
        let drawing = currentInputDrawing(canvas)
        let beforeDrawing = try? PKDrawing(data: before)
        let unchanged = beforeDrawing?.hasSameVisibleInk(as: drawing) == true
        let after = unchanged ? before : drawing.dataRepresentation()
        commitInk(after, page: page)
        endedFingeringInput[page] = before
        if before != after { record(.ink(page, before, after)) }
        // Retain even an empty gesture: PencilKit can deliver its first/final ink
        // after pen-up. Refinements update this same step, never add another Undo.
        endedInkInput[page] = EndedInkInput(canvas: ObjectIdentifier(canvas), before: before,
                                           after: after, additive: inputIsAdditive)
        if before != after { scheduleFingering(canvas, before: before) }
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard let canvas = canvasView as? ScoreCanvas, !applyingHistory else { return }
        let page = canvas.pageNumber
        // A drag preview removes its group only from the visible canvas, never
        // from the model. Ignore asynchronous acknowledgements of that display.
        guard fingeringDragState?.selection.page != page, inkMovePreview?.page != page else { return }
        let drawing = currentInputDrawing(canvas)
        if drawing.strokes.isEmpty,
           drawings[page].flatMap({ try? PKDrawing(data: $0) })?.strokes.isEmpty ?? true { return }
        let data = drawing.dataRepresentation()
        guard drawings[page] != data else { return }
        // Selecting restored ink can update PencilKit's private archive metadata
        // without changing a visible stroke. That is not a new Undo operation.
        if activeCanvas !== canvas, let saved = drawings[page].flatMap({ try? PKDrawing(data: $0) }),
           saved.hasSameVisibleInk(as: drawing) { return }
        if activeCanvas === canvas, drawingBefore[page] != nil {
            commitInk(data, page: page)
        } else if var ended = endedInkInput[page], ended.canvas == ObjectIdentifier(canvas),
                  (drawings[page] ?? PKDrawing().dataRepresentation()) == ended.after {
            if ended.additive, let previous = try? PKDrawing(data: ended.after),
               let baseline = try? PKDrawing(data: ended.before) {
                let ids = Set(canvas.drawing.strokes.map(\.fingeringID))
                // Legacy identity includes path points, which can change while
                // PencilKit refines the newest stroke. Only older ink is fixed.
                guard canvas.drawing.strokes.count >= previous.strokes.count,
                      baseline.strokes.allSatisfy({ ids.contains($0.fingeringID) }) else {
                    restoreDrawing(on: canvas); return
                }
            }
            if ended.before == ended.after {
                record(.ink(page, ended.before, data))
            } else if case let .ink(lastPage, before, after)? = undoHistory.last,
                      lastPage == page, before == ended.before, after == ended.after {
                undoHistory[undoHistory.count - 1] = .ink(page, before, data)
            } else { restoreDrawing(on: canvas); return }
            ended.after = data
            endedInkInput[page] = ended
            commitInk(data, page: page)
            if let start = endedFingeringInput[page] { scheduleFingering(canvas, before: start) }
        } else if replacedInkPages.contains(page) || activeCanvas != nil {
            restoreDrawing(on: canvas)
        } else {
            // Keep compatibility with unbracketed initial canvas edits. Once
            // history exists, changes belong to an explicit tool interaction.
            let before = drawings[page] ?? PKDrawing().dataRepresentation()
            record(.ink(page, before, data))
            commitInk(data, page: page)
        }
    }

    func hasActiveNavigationGesture(around canvas: ScoreCanvas) -> Bool {
        var ancestor = canvas.superview
        while let view = ancestor {
            if let scroll = view as? UIScrollView, scroll.isDragging || scroll.isZooming || scroll.isDecelerating { return true }
            ancestor = view.superview
        }
        return false
    }

    func queueSave() {
        hasUnsavedChanges = true
        let previous = writeTask
        writeTask = Task { [weak self] in
            await previous?.value
            await self?.persistDirtyDrawings()
        }
    }

    private func persistDirtyDrawings() async {
        guard let disk, let score else { return }
        let snapshot = dirty
        for (page, data) in snapshot {
            do {
                try await disk.saveDrawing(data, scoreID: score.id, page: page)
                if dirty[page] == data { dirty.removeValue(forKey: page) }
            } catch { errorMessage = "score.annotationSaveError".localized; break }
        }
        if dirtyEdits {
            let snapshot = annotationEdits
            do {
                try await disk.saveAnnotationEdits(snapshot, scoreID: score.id)
                if annotationEdits == snapshot { dirtyEdits = false }
            } catch { errorMessage = "score.annotationSaveError".localized }
        }
        if dirtyFingerings {
            let snapshot = fingeringMarks
            do {
                try await disk.saveFingerings(snapshot, scoreID: score.id)
                if fingeringMarks == snapshot { dirtyFingerings = false }
            } catch { errorMessage = "score.annotationSaveError".localized }
        }
        if dirtyVoiceNotes {
            let snapshot = voiceNotes
            do {
                try await disk.saveVoiceNotes(snapshot, scoreID: score.id)
                if voiceNotes == snapshot { dirtyVoiceNotes = false }
            } catch { errorMessage = "score.annotationSaveError".localized }
        }
        hasUnsavedChanges = !dirty.isEmpty || dirtyEdits || dirtyFingerings || dirtyVoiceNotes
    }

    func flush() async -> Bool {
        // Export/close saves the visible ink. A late recognizer result must not
        // change the document after it was exported or the reader disappeared.
        finishInkInput()
        cancelFingering()
        finishAnnotationGesture()
        endedInkInput.removeAll()
        replacedInkPages.formUnion(drawings.keys)
        await writeTask?.value
        await persistDirtyDrawings()
        return dirty.isEmpty && !dirtyEdits && !dirtyFingerings && !dirtyVoiceNotes
    }

    private func clearSelectionForCurrentTool() {
        inkSelectionEditor.clear()
        coverEditor.select(nil)
        if !editing || tool != .voice { movingVoiceID = nil }
        selectedFingering = nil
        if !editing || tool != .select { select(nil) }
    }

    /// Also called by makeUIView: configure UIKit without publishing SwiftUI state.
    /// Selection changes belong to user actions; history changes belong to record/undo/redo.
    private func applyTool(restoreKeyboardFocus: Bool = true) {
        coverEditor.mode = !editing ? .inactive : tool == .cover ? .create : tool == .select ? .select : .inactive
        coverEditor.refresh()
        inkSelectionEditor.enabled = editing && tool == .select
        pdfView?.isInMarkupMode = editing
        pencilNavigation.editing = editing
        let editingTouches = fingerDrawing || tool == .select ? [UITouch.TouchType.pencil, .direct, .indirectPointer] : [.pencil]
        for gesture in [annotationPan, annotationTap, annotationEraser] {
            gesture.allowedTouchTypes = editingTouches.map { NSNumber(value: $0.rawValue) }
            gesture.requiresExclusiveTouchType = true
        }
        annotationPan.isEnabled = editing && tool == .select
        annotationTap.isEnabled = editing && tool == .select
        annotationEraser.isEnabled = editing && tool == .eraser
        fingeringTap.allowedTouchTypes = [UITouch.TouchType.direct, .indirectPointer].map { NSNumber(value: $0.rawValue) }
        fingeringTap.isEnabled = editing && tool == .fingering
        refreshSelection()
        for overlay in liveOverlays.allObjects { configure(overlay) }
        updatePageBadges()
        updateVoicePins()
        // Setting a PencilKit tool can change the first responder. Restore keys
        // after configuration, not before; style fields keep their own focus.
        if restoreKeyboardFocus { focusKeys() }
    }

    func setPageBadges(_ badges: [Int: ScorePageBadgeInfo]) {
        guard badges != pageBadges else { return }
        pageBadges = badges
        updatePageBadges()
    }

    private func updatePageBadges() {
        updateVoicePins()
        guard let view = pdfView, let document else { return }
        var placements: [Int: (ScorePageBadgeInfo, CGRect)] = [:]
        if showsPageBadges && !editing {
            for page in view.visiblePages {
                let index = document.index(for: page) + 1
                guard let info = pageBadges[index] else { continue }
                let rect = view.convert(page.bounds(for: .cropBox), from: page)
                placements[index] = (info, badgeLayer.convert(rect, from: view))
            }
        }
        badgeLayer.update(placements)
        badgeLayer.superview?.bringSubviewToFront(badgeLayer)
    }

    private func configure(_ overlay: ScorePageOverlay) {
        overlay.drawingEnabled = editing && tool != .voice && tool != .cover && tool != .select
        overlay.canvas.drawingPolicy = fingerDrawing || tool == .select ? .anyInput : .pencilOnly
        switch tool {
        case .pen, .monoline, .marker, .fingering: overlay.canvas.tool = inkStyle.inkingTool(for: tool)
        case .eraser: overlay.canvas.tool = PKEraserTool(.vector)
        case .select, .voice, .cover: overlay.canvas.tool = PKLassoTool()
        }
        overlay.canvas.followPageZoom(overlay.canvas.zoomScale)
    }

    /// Coalesce only input belonging to the converted strokes. Earlier ordinary
    /// notes and unconverted strokes remain independent undo steps. PencilKit's
    /// late final callback can update a path without changing its stroke IDs.
    func popPenInput(page: Int, endingAt drawing: Data, consuming convertedIDs: Set<UUID>) -> Data {
        func ids(_ data: Data) -> [UUID]? { (try? PKDrawing(data: data))?.strokes.map(\.fingeringID) }
        var start = drawing, popped = 0
        while case let .ink(inkPage, before, after)? = undoHistory.last, inkPage == page,
              let afterIDs = ids(after), afterIDs == ids(start),
              let beforeIDs = ids(before), !convertedIDs.isDisjoint(with: afterIDs),
              beforeIDs.filter({ !convertedIDs.contains($0) }) == afterIDs.filter({ !convertedIDs.contains($0) }) {
            undoHistory.removeLast()
            start = before
            popped += 1
        }
        return popped > 0 ? start : drawing
    }

    func record(_ change: Change) {
        endedInkInput.removeAll()
        if case let .drawing(page, _, _) = change.asDrawing { replacedInkPages.insert(page) }
        undoHistory.append(change)
        if undoHistory.count > 50 { undoHistory.removeFirst() }
        redoHistory.removeAll()
        updateUndoState()
    }

    func updateUndoState() {
        let undoAvailable = !voiceBusy && !undoHistory.isEmpty, redoAvailable = !voiceBusy && !redoHistory.isEmpty
        if canUndo != undoAvailable { canUndo = undoAvailable }
        if canRedo != redoAvailable { canRedo = redoAvailable }
    }

    func apply(_ change: Change, forward: Bool) {
        switch change.asDrawing {
        case let .drawing(page, before, after):
            let data = forward ? after : before
            do {
                let drawing = try PKDrawing(data: data)
                drawings[page] = data; dirty[page] = data
                displayDrawing(drawing, on: page)
                queueSave()
            } catch { errorMessage = "score.annotationReadError".localized }
        case let .annotations(before, after): updateAnnotations(forward ? after : before)
        case let .voices(before, after):
            selectedVoiceNote = nil; movingVoiceID = nil
            setVoiceNotes(forward ? after : before)
        case .ink: break // asDrawing never returns .ink
        }
    }

    func undo() {
        guard !voiceAudio.isBusy else { return }
        finishInkInput()
        inkSelectionEditor.clear()
        selectedFingering = nil
        cancelFingering()
        finishAnnotationGesture()
        guard let change = undoHistory.popLast() else { return }
        apply(change, forward: false); redoHistory.append(change); updateUndoState()
    }
    func redo() {
        guard !voiceAudio.isBusy else { return }
        finishInkInput()
        inkSelectionEditor.clear()
        selectedFingering = nil
        cancelFingering()
        guard let change = redoHistory.popLast() else { return }
        apply(change, forward: true); undoHistory.append(change); updateUndoState()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if gestureRecognizer === voiceTap || gestureRecognizer === voiceDrag || gestureRecognizer === voiceHold {
            // Let an already tracking recognizer see a second finger so it can
            // cancel its preview instead of treating a pinch as a one-finger move.
            if gestureRecognizer.numberOfTouches > 0 { return true }
            guard !voiceAudio.isBusy else { return false }
            // Pencil ink keeps its normal path. A free finger can move a pin
            // while the user is annotating with Apple Pencil.
            guard !editing || tool == .voice || tool == .select || (touch.type != .pencil && !fingerDrawing) else { return false }
            let id = voiceHit(at: touch.location(in: pdfView))
            if gestureRecognizer === voiceDrag {
                voiceDragID = id; voiceDragDidMove = false
                if let id, let note = voiceNotes.first(where: { $0.id == id }), let center = voicePoint(note) {
                    let finger = touch.location(in: pdfView)
                    voiceDragGrabOffset = CGPoint(x: finger.x - center.x, y: finger.y - center.y)
                }
            }
            return (gestureRecognizer === voiceTap && editing && tool == .voice) || id != nil
        }
        guard editing else { return false }
        if coverEditor.accepts(touch.location(in: pdfView)) { return false }
        if gestureRecognizer === fingeringDrag {
            if gestureRecognizer.numberOfTouches > 0 { return true }
            guard touch.type != .pencil, !pencilNavigation.pencilDown, canMoveFingerings else { return false }
            fingeringDragHit = fingeringHit(at: touch.location(in: pdfView))
            return fingeringDragHit != nil
        }
        if gestureRecognizer === fingeringTap {
            return tool == .fingering && fingeringHit(at: touch.location(in: pdfView)) != nil
        }
        if gestureRecognizer === annotationEraser { return tool == .eraser && (fingerDrawing || touch.type == .pencil) }
        if gestureRecognizer === annotationTap {
            // Blank/native ink belongs to PencilKit's selection tool. A PDF tap
            // recognizer accepting every contact swallows its tap-to-select.
            return tool == .select && hit(at: touch.location(in: pdfView)) != nil
        }
        if gestureRecognizer === annotationPan, tool == .select {
            let point = touch.location(in: pdfView)
            panStart = point
            panKey = hit(at: point)?.key
            if let key = selectedAnnotation, let annotation = annotations?.live[key], let page = annotation.page,
               pdfView?.convert(annotation.bounds, from: page).insetBy(dx: -5, dy: -5).contains(point) == true { panKey = key }
            return panKey != nil
        }
        return tool == .select
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === fingeringDrag {
            return editing && fingeringDragHit != nil && gestureRecognizer.numberOfTouches == 1
        }
        if gestureRecognizer === voiceTap || gestureRecognizer === voiceDrag || gestureRecognizer === voiceHold { return gestureRecognizer.numberOfTouches == 1 && !voiceAudio.isBusy }
        guard editing else { return false }
        if gestureRecognizer === fingeringTap { return tool == .fingering }
        if gestureRecognizer === annotationPan { return tool == .select && panKey != nil }
        if gestureRecognizer === annotationTap { return tool == .select }
        return tool == .eraser
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        if (gestureRecognizer === voiceDrag && other === voiceHold) || (gestureRecognizer === voiceHold && other === voiceDrag) { return true }
        return gestureRecognizer === annotationEraser || other === annotationEraser
    }

    func export(flattened: Bool = false) async -> URL? {
        guard await flush(), let score, let disk else { return nil }
        let source = disk.pdfURL(score.id), ink = drawings, edits = annotationEdits, title = score.title
        do {
            return try await Task.detached(priority: .userInitiated) {
                let editable = try ScorePDFExport.editable(source: source, drawings: ink, edits: edits, title: title)
                if !flattened { return editable }
                defer { try? FileManager.default.removeItem(at: editable.deletingLastPathComponent()) }
                return try ScorePDFExport.create(source: editable, drawings: [:], title: title)
            }.value
        } catch { errorMessage = error.localizedDescription; return nil }
    }
    /// The untouched imported file, for sending to someone who will join a live lesson.
    func exportOriginal() async -> URL? {
        guard let score, let disk else { return nil }
        let source = disk.pdfURL(score.id), title = score.title
        do {
            return try await Task.detached(priority: .userInitiated) {
                try ScorePDFExport.original(source: source, title: title)
            }.value
        } catch { errorMessage = error.localizedDescription; return nil }
    }

}
