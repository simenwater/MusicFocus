#if DEBUG || MUSICFOCUS_HOMR
import SwiftUI
import PDFKit
import UniformTypeIdentifiers

struct ScoreAuditionSupport: ViewModifier {
    @ObservedObject var reader: ScoreReaderController
    @Binding var presented: Bool
    @EnvironmentObject private var focus: FocusManager
    @StateObject private var player = ScoreAuditionPlayer()
    @State private var importing = false
    @State private var loading = false
    @State private var digest: String?
    #if MUSICFOCUS_HOMR
    @StateObject private var recognition = ScoreRecognitionJob()
    @State private var choosingPages = false
    @AppStorage("dev.scoreAuditionAutomatic") private var automaticRecognition = true
    @AppStorage("dev.scoreAuditionIdleReading") private var idleReading = false
    @AppStorage("dev.scoreAuditionOrnaments") private var ornaments = true
    @AppStorage("dev.scoreAuditionTrillFromUpper") private var trillFromUpper = true
    @AppStorage("dev.scoreAuditionRepeats") private var repeats = true
    @State private var automaticPage: Int?
    @State private var waitingToPlay: Int?
    @State private var attemptedPages: Set<Int> = []
    #endif
    @State private var automaticPages = true

    private var recognitionTaskID: String? {
        guard let digest else { return nil }
        #if MUSICFOCUS_HOMR
        return presented || (automaticRecognition && idleReading) ? "\(digest)-\(presented)-\(idleReading)-\(automaticRecognition)" : nil
        #else
        return presented ? digest : nil
        #endif
    }

    func body(content: Content) -> some View {
        content
            .overlay {
                if presented, player.package != nil {
                    ScoreAuditionOverlay(reader: reader, player: player).allowsHitTesting(false)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if presented {
                    panel
                }
            }
            .task(id: reader.ready) {
                guard reader.ready, let score = reader.score, let disk = reader.disk else { return }
                player.bind(focus: focus, voice: reader.voiceAudio)
                do {
                    let hash = try await Task.detached(priority: .utility) { try ScoreLibraryDisk.sha256(of: disk.pdfURL(score.id)) }.value
                    digest = hash
                } catch { player.error = error.localizedDescription }
            }
            .task(id: recognitionTaskID) {
                guard recognitionTaskID != nil, let digest, let score = reader.score else { return }
                let page = reader.pages.first ?? 1
                #if MUSICFOCUS_HOMR
                let minimumRevision: Int? = ScoreAuditionPackage.currentRecognitionRevision
                let performedRepeats: Bool? = automaticRecognition ? repeats : nil
                #else
                let minimumRevision: Int? = nil
                let performedRepeats: Bool? = nil
                #endif
                if presented, let package = await Task.detached(priority: .utility, operation: {
                    ScoreAuditionPackage.cached(digest: digest, page: page, pageCount: score.pageCount, minimumRevision: minimumRevision, performsRepeats: performedRepeats)
                }).value, !Task.isCancelled, reader.pages.first == page { player.offer(package, page: page) }
                #if MUSICFOCUS_HOMR
                await maintainAutomaticRecognition()
                #endif
            }
            .onChange(of: presented) { _, value in if !value { player.unload(); cancelRecognition() } }
            .onChange(of: reader.editing) { _, editing in
                if editing {
                    player.cancelLoopSelection()
                    #if DEBUG && MUSICFOCUS_HOMR
                    if recognition.running {
                        if let automaticPage { attemptedPages.remove(automaticPage) }
                        cancelRecognition()
                    }
                    #endif
                }
            }
            .onReceive(Metronome.shared.$isRunning) { if $0 { player.pause() } }
            .onDisappear { player.pause(); cancelRecognition() }
            .onChange(of: player.position) { _, position in
                if player.playing { followAudition(at: position) }
            }
            .onChange(of: player.seekRevision) { _, _ in followAudition(at: player.position) }
            #if MUSICFOCUS_HOMR
            .onChange(of: automaticRecognition) { _, value in if value { attemptedPages = [] } }
            .onChange(of: player.completionRevision) { _, _ in
                guard automaticRecognition, let last = player.package?.cues.map(\.page).max(),
                      last < (reader.score?.pageCount ?? 0) else { return }
                waitingToPlay = last + 1; reader.go(to: last + 1)
            }
            .sheet(isPresented: $choosingPages) {
                if let score = reader.score, let disk = reader.disk, let digest {
                    ScoreRecognitionOptions(pageCount: score.pageCount, currentPage: reader.pages.first ?? 1) { pages, layout, tempo, ornaments, trillFromUpper, ignoreColoredMarks, repeats in
                        choosingPages = false
                        automaticPage = nil; waitingToPlay = nil
                        recognition.start(.init(url: disk.pdfURL(score.id), digest: digest, title: score.title, pages: pages, layout: layout, tempo: tempo, ornaments: ornaments, ignoreColoredMarks: ignoreColoredMarks, trillFromUpper: trillFromUpper, repeats: repeats)) { package in
                            player.load(package)
                        }
                    }
                }
            }
            #endif
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                guard case .success(let url) = result else { return }
                guard let digest, let pageCount = reader.score?.pageCount else { return }
                loading = true
                Task {
                    defer { loading = false }
                    do {
                        let package = try await Task.detached(priority: .userInitiated) {
                            let package = try ScoreAuditionPackage.read(url, digest: digest, pageCount: pageCount)
                            try package.cache()
                            return package
                        }.value
                        player.load(package)
                    } catch { player.error = error.localizedDescription }
                }
            }
    }
    #if MUSICFOCUS_HOMR
    @MainActor private func maintainAutomaticRecognition() async {
        guard let score = reader.score, let disk = reader.disk, let digest else { return }
        var lastPage = reader.pages.first ?? 1, idleSince = Date()
        var cacheCheckedPage: Int?
        attemptedPages = []
        defer { if automaticPage != nil { recognition.cancel(); automaticPage = nil }; waitingToPlay = nil }
        while !Task.isCancelled {
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            let page = reader.pages.first ?? 1
            let scroll = reader.scrollView
            let busy = reader.editing || scroll?.isTracking == true || scroll?.isDragging == true || scroll?.isDecelerating == true
                || scroll?.isZooming == true || player.scrubbing || player.preparing || reader.voiceAudio.isBusy || focus.isActive
                || UIApplication.shared.applicationState != .active || ProcessInfo.processInfo.isLowPowerModeEnabled
                || ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical
            if page != lastPage {
                lastPage = page; idleSince = Date(); cacheCheckedPage = nil
                if !reader.editing { player.followReaderPage(page) }
                if waitingToPlay != page { waitingToPlay = nil }
            }
            if busy || !automaticRecognition || choosingPages {
                idleSince = Date()
                if let runningPage = automaticPage, recognition.running {
                    recognition.cancel(); attemptedPages.remove(runningPage); automaticPage = nil
                }
                continue
            }
            if recognition.running { continue }
            if let finishedPage = automaticPage {
                if finishedPage != page { recognition.clearError() }
                automaticPage = nil
            }
            if presented, player.package?.cues.contains(where: { $0.page == page }) != true, !player.playing, cacheCheckedPage != page {
                cacheCheckedPage = page
                let performedRepeats = repeats
                let cached = await Task.detached(priority: .utility) { ScoreAuditionPackage.cached(digest: digest, page: page, pageCount: score.pageCount, minimumRevision: ScoreAuditionPackage.currentRecognitionRevision, performsRepeats: performedRepeats) }.value
                guard !Task.isCancelled else { return }
                if let cached, reader.pages.first == page, !reader.editing, !player.playing, !player.scrubbing {
                    player.offer(cached, page: page); attemptedPages.insert(page)
                    if waitingToPlay == page { waitingToPlay = nil; player.play() }
                }
            }
            guard automaticRecognition, Date().timeIntervalSince(idleSince) >= 2 else { continue }
            let needed = player.package?.cues.contains(where: { $0.page == page }) == true ? page + 1 : page
            guard needed <= score.pageCount,
                  let next = (needed...score.pageCount).first(where: { !attemptedPages.contains($0) }) else { continue }
            let performedRepeats = repeats
            let reviewRhythm = presented
            let cached = await Task.detached(priority: .utility) { ScoreAuditionPackage.cached(digest: digest, page: next, pageCount: score.pageCount, minimumRevision: ScoreAuditionPackage.revision(reviewRhythm:reviewRhythm), performsRepeats: performedRepeats) }.value
            guard !Task.isCancelled else { return }
            attemptedPages.insert(next)
            if cached != nil { continue }
            guard reader.pages.first == page, !reader.editing, !focus.isActive, !reader.voiceAudio.isBusy else {
                attemptedPages.remove(next); idleSince = Date(); continue
            }
            automaticPage = next
            recognition.start(.init(url: disk.pdfURL(score.id), digest: digest, title: score.title, pages: [next], layout: .automatic,
                                    ornaments: ornaments, trillFromUpper: trillFromUpper, repeats: repeats, connectCachedPages: true, reviewRhythm: reviewRhythm)) { package in
                if presented, package.cues.contains(where: { reader.pages.contains($0.page) }), !reader.editing {
                    player.offer(package, page: reader.pages.first ?? next)
                    if waitingToPlay == next { waitingToPlay = nil; player.play() }
                }
            }
            idleSince = Date()
        }
    }
    #endif
    private func followAudition(at position: Double) {
        guard automaticPages, !reader.editing, !player.scrubbing,
              let cue = player.package?.followCue(at: position),
              !reader.pages.contains(cue.page) else { return }
        reader.go(to: cue.page)
    }
    private func cancelRecognition() {
        #if MUSICFOCUS_HOMR
        recognition.cancel()
        automaticPage = nil; waitingToPlay = nil
        #endif
    }
    @ViewBuilder private var panel: some View {
        #if MUSICFOCUS_HOMR
        ScoreAuditionPanel(player: player, loading: loading, editing: reader.editing, importResult: { importing = true },
                          recognizing: recognition.running, fraction: recognition.fraction, status: recognition.status,
                          recognitionError: automaticPage.map { reader.pages.contains($0) } == false ? nil : recognition.error,
                          recognitionReady: digest != nil, recognize: { player.pause(); cancelRecognition(); choosingPages = true },
                          cancelRecognition: { automaticRecognition = false; cancelRecognition() }, automaticPages: $automaticPages, automaticRecognition: $automaticRecognition, idleReading: $idleReading,
                          close: { player.pause(); recognition.cancel(); presented = false; reader.focusKeys() })
        #else
        ScoreAuditionPanel(player: player, loading: loading, editing: reader.editing, importResult: { importing = true }, automaticPages: $automaticPages,
                          close: { player.pause(); presented = false; reader.focusKeys() })
        #endif
    }

}

private struct ScoreAuditionPanel: View {
    @ObservedObject var player: ScoreAuditionPlayer
    var loading: Bool
    var editing: Bool
    var importResult: () -> Void
    var recognizing = false
    var fraction = 0.0
    var status = ""
    var recognitionError: String?
    var recognitionReady = true
    var recognize: (() -> Void)?
    var cancelRecognition: () -> Void = {}
    @Binding var automaticPages: Bool
    var automaticRecognition: Binding<Bool>?
    var idleReading: Binding<Bool>?
    var close: () -> Void
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var showingInfo = false
    private func text(_ zh: String, _ en: String) -> String { ScoreAuditionText.value(zh, en) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let package = player.package {
                HStack(spacing: 4) {
                    Button { player.playing || player.preparing ? player.pause() : player.play() } label: {
                        Image(systemName: player.playing ? "pause.fill" : "play.fill")
                            .font(.title3).frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(player.playing ? text("暂停试听", "Pause audition") : text("播放试听", "Play audition"))
                    .accessibilityValue(Set(package.cues.map(\.page)).sorted().map { text("第 \($0) 页", "Page \($0)") }.joined(separator: ", "))
                    .accessibilityIdentifier("scoreAuditionPlay")
                    ScoreAuditionScrubber(player: player, duration: package.duration).frame(minWidth: 32, minHeight: 44)
                    Text(String(format: "%.1f / %.1f", player.position, package.duration))
                        .font(.caption.monospacedDigit()).lineLimit(1).minimumScaleFactor(0.65)
                        .frame(width: sizeClass == .compact ? 52 : 90)
                        .accessibilityIdentifier("scoreAuditionTime")
                    Button { player.selectingLoop ? player.cancelLoopSelection() : player.beginLoopSelection() } label: {
                        Image(systemName: "repeat").frame(width: 44, height: 44)
                            .foregroundStyle(player.selectingLoop || player.loopEnabled ? Color.accentColor : Color.primary)
                    }
                    .disabled(editing || package.bars == nil)
                    .accessibilityLabel(player.selectingLoop ? text("取消选段", "Cancel selection") : text("选段循环", "Select loop"))
                    .accessibilityIdentifier("scoreAuditionSelectLoop")
                    more
                    closeButton
                }
                if player.selectingLoop {
                    Text(player.loopAnchor == nil
                         ? text("点起始小节，再点结束小节；同一小节点两次可循环一小节。", "Tap the first bar, then the last. Tap the same bar twice to repeat one bar.")
                         : text("起点：第 \(player.loopAnchor?.printedMeasure ?? 1) 小节，请点结束小节。", "Start: bar \(player.loopAnchor?.printedMeasure ?? 1). Tap the last bar to include it in the loop."))
                        .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("scoreAuditionTapHint")
                } else if let loop = player.loop {
                    HStack(spacing: 8) {
                        Toggle(text("第 \(loop.firstMeasure)–\(loop.lastMeasure) 小节", "Bars \(loop.firstMeasure)–\(loop.lastMeasure)"),
                               isOn: Binding(get: { player.loopEnabled }, set: { player.setLoopEnabled($0) }))
                            .fixedSize().font(.caption).accessibilityIdentifier("scoreAuditionLoopEnabled")
                        Button { player.clearLoop() } label: { Image(systemName: "xmark.circle").frame(width: 44, height: 32) }
                            .accessibilityLabel(text("清除循环", "Clear loop")).accessibilityIdentifier("scoreAuditionClearLoop")
                        Spacer(minLength: 0)
                    }
                }
            } else {
                HStack {
                    Label(text("听谱 · 实验版", "Score audition · Preview"), systemImage: "music.note").font(.subheadline)
                    Spacer()
                    if let recognize {
                        Button(action: recognize) { Image(systemName: "viewfinder").frame(width: 44, height: 44) }
                            .disabled(loading || recognizing || !recognitionReady)
                            .accessibilityLabel(text("选页识别", "Recognize pages")).accessibilityIdentifier("scoreRecognizePages")
                    }
                    more; closeButton
                }
                if automaticRecognition?.wrappedValue == true, !recognizing, recognitionError == nil {
                    Text(text("停止操作后，自动准备当前页和后续谱页。", "When idle, this page and the following pages prepare automatically."))
                        .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("scoreAuditionIdle")
                } else if let recognize, !recognizing {
                    Button(action: recognize) {
                        Label(text("在 iPad 本机识别", "Recognize on this iPad"), systemImage: "viewfinder").frame(maxWidth: .infinity, minHeight: 44)
                    }.buttonStyle(.borderedProminent).disabled(loading || !recognitionReady).accessibilityIdentifier("scoreRecognizeLocally")
                } else if recognize == nil {
                    Text(text("当前构建已关闭本机识谱。", "On-device recognition is turned off in this build."))
                        .font(.caption).accessibilityIdentifier("scoreRecognitionUnavailable")
                }
            }
            if recognizing {
                HStack {
                    ProgressView(value: fraction).frame(maxWidth: 100)
                    Text(status).font(.caption).lineLimit(1)
                    Spacer(minLength: 0)
                    Button(text("取消", "Cancel"), action: cancelRecognition).accessibilityIdentifier("scoreRecognitionCancel")
                }.frame(minHeight: 28)
            }
            if let error = recognitionError { Text(error).font(.caption).foregroundStyle(.red) }
            if loading || player.preparing { ProgressView().controlSize(.mini) }
            if let error = player.error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .padding(.horizontal, 12).padding(.vertical, 6).background(.regularMaterial)
        .accessibilityElement(children: .contain).accessibilityIdentifier("scoreAuditionPanel")
        .popover(isPresented: $showingInfo) {
            VStack(alignment: .leading, spacing: 12) {
                Text(text("听谱 · 实验版", "Score audition · Preview")).font(.headline)
                Text(player.package?.notice ?? text("在本机识别原谱，不读取独立笔记层。", "Recognizes the original score on this device, without separate annotation layers."))
                Text(text("试听不计入练琴。关闭画笔后可点谱播放，双指缩放和翻页照常使用。", "Listening is not practice time. Close the pen tools to tap notes; pinch and scroll as usual."))
                if player.package?.bars == nil { Text(text("当前结果没有可靠的小节边界，暂不能选段循环。", "Reliable bar boundaries are not available for looping.")) }
            }.font(.callout).padding().frame(maxWidth: 340).presentationCompactAdaptation(.popover)
        }
    }
    private var closeButton: some View {
        Button(action: close) { Image(systemName: "xmark").frame(width: 44, height: 44) }
            .accessibilityLabel(text("关闭试听", "Close audition")).accessibilityIdentifier("scoreAuditionClose")
    }
    private var more: some View {
        Menu {
            if let package = player.package {
                Menu {
                    ForEach([0.5, 0.75, 1, 1.25, 1.5], id: \.self) { rate in
                        Button(String(format: "%.2g× · %.0f BPM", rate, package.tempo * rate)) { player.setRate(rate) }
                    }
                } label: { Label(String(format: "%.0f BPM", package.tempo * player.rate), systemImage: "speedometer") }
                    .accessibilityIdentifier("scoreAuditionTempo")
                if package.audioWithClicks != nil {
                    Toggle(text("试听节拍声", "Audition click track"), isOn: Binding(get: { player.clicks }, set: { player.setClicks($0) }))
                        .accessibilityIdentifier("scoreAuditionClicks")
                }
                let pages = Set(package.cues.map(\.page)).sorted()
                Text(text("已准备第 \(pages.first ?? 1)–\(pages.last ?? 1) 页", "Prepared pages \(pages.first ?? 1)–\(pages.last ?? 1)"))
                Toggle(text("自动翻页", "Follow pages"), isOn: $automaticPages).accessibilityIdentifier("scoreAuditionFollow")
                Divider()
            }
            if let recognize {
                Button(action: recognize) { Label(text("选页重新识别", "Recognize pages again"), systemImage: "viewfinder") }
                    .disabled(loading || recognizing || !recognitionReady).accessibilityIdentifier("scoreRecognizePages")
            }
            if let automaticRecognition {
                Toggle(text("空闲时自动准备后续谱页", "Prepare following pages while idle"), isOn: automaticRecognition)
                    .accessibilityIdentifier("scoreAuditionAutomatic")
                if let idleReading, automaticRecognition.wrappedValue {
                    Toggle(text("仅看谱时也自动准备", "Prepare while reading, too"), isOn: idleReading)
                        .accessibilityIdentifier("scoreAuditionIdleReading")
                }
            }
            Button(text("识别说明", "About this preview"), systemImage: "info.circle") { showingInfo = true }
            Button(action: importResult) { Label(text("导入已有试听结果", "Import an existing preview"), systemImage: "square.and.arrow.down") }
                .disabled(loading || recognizing).accessibilityIdentifier("scoreAuditionImport")
        } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
            .accessibilityLabel(text("更多试听操作", "More audition options")).accessibilityIdentifier("scoreAuditionMore")
    }
}

private struct ScoreAuditionScrubber: UIViewRepresentable {
    @ObservedObject var player: ScoreAuditionPlayer
    let duration: Double
    @MainActor final class Coordinator: NSObject {
        var player: ScoreAuditionPlayer
        init(_ player: ScoreAuditionPlayer) { self.player = player }
        @objc func began(_ slider: UISlider) { player.beginScrubbing() }
        @objc func changed(_ slider: UISlider) {
            if abs(Double(slider.value) - player.position) > 0.001 { player.seek(Double(slider.value)) }
        }
        @objc func ended(_ slider: UISlider) { player.endScrubbing() }
    }
    func makeCoordinator() -> Coordinator { Coordinator(player) }
    func makeUIView(context: Context) -> UISlider {
        let slider = UISlider()
        slider.accessibilityIdentifier = "scoreAuditionSeek"
        slider.accessibilityLabel = ScoreAuditionText.value("试听进度", "Audition position")
        slider.addTarget(context.coordinator, action: #selector(Coordinator.began), for: .touchDown)
        slider.addTarget(context.coordinator, action: #selector(Coordinator.changed), for: .valueChanged)
        slider.addTarget(context.coordinator, action: #selector(Coordinator.ended), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        return slider
    }
    func updateUIView(_ slider: UISlider, context: Context) {
        context.coordinator.player = player
        slider.minimumValue = 0; slider.maximumValue = Float(duration)
        slider.isEnabled = !player.preparing || player.scrubbing
        // The finger owns the thumb until touch-up. Audio-clock publications
        // must never reposition it midway through UIKit's tracking gesture.
        if !slider.isTracking { slider.value = Float(player.position) }
    }
}

private struct ScoreAuditionOverlay: UIViewRepresentable {
    let reader: ScoreReaderController
    let player: ScoreAuditionPlayer
    func makeUIView(context: Context) -> ScoreAuditionBallView {
        let view = ScoreAuditionBallView(); view.reader = reader; view.player = player
        return view
    }
    func updateUIView(_ view: ScoreAuditionBallView, context: Context) {
        view.reader = reader; view.player = player
        view.setPackage(player.package, revision: player.packageRevision)
    }
    static func dismantleUIView(_ view: ScoreAuditionBallView, coordinator: ()) { view.detachInteraction() }
}

/// Transparent, non-interactive layer. Position conversion follows PDFKit zoom,
/// crop origins and rotation; no note data is ever written into a PDF or PKDrawing.
final class ScoreAuditionBallView: UIView, UIGestureRecognizerDelegate {
    weak var reader: ScoreReaderController?
    weak var player: ScoreAuditionPlayer?
    private var groups: [Int: [ScoreAuditionPackage.Cue]] = [:]
    private var balls: [Int: CALayer] = [:]
    private var revision = -1
    private var displayLink: CADisplayLink?
    private weak var attachedPDF: PDFView?
    private lazy var scoreTap = UITapGestureRecognizer(target: self, action: #selector(tappedScore(_:)))
    private let selectionLayer = CAShapeLayer()
    private var measureElements: [ScoreAuditionMeasureElement] = []
    private var barBounds: [(page: Int, measure: Int, rect: CGRect)] = []
    private var lastAccessibilityUpdate = 0.0
    private final class Target: NSObject {
        weak var view: ScoreAuditionBallView?
        @objc func tick() { view?.tick() }
    }
    private let target = Target()
    override init(frame: CGRect) {
        super.init(frame: frame); isUserInteractionEnabled = false; clipsToBounds = true; target.view = self
        scoreTap.delegate = self; scoreTap.cancelsTouchesInView = false; scoreTap.delaysTouchesEnded = false
        scoreTap.allowedTouchTypes = [UITouch.TouchType.direct, .indirectPointer].map { NSNumber(value: $0.rawValue) }
        scoreTap.numberOfTouchesRequired = 1
        selectionLayer.fillColor = UIColor.systemBlue.withAlphaComponent(0.1).cgColor
        selectionLayer.strokeColor = UIColor.systemBlue.withAlphaComponent(0.55).cgColor
        selectionLayer.lineWidth = 1; layer.addSublayer(selectionLayer)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func didMoveToWindow() {
        super.didMoveToWindow(); displayLink?.invalidate(); displayLink = nil
        guard window != nil else { detachInteraction(); return }
        let link = CADisplayLink(target: target, selector: #selector(Target.tick))
        link.preferredFrameRateRange = .init(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common); displayLink = link
    }
    func setPackage(_ package: ScoreAuditionPackage?, revision: Int) {
        guard self.revision != revision else { return }; self.revision = revision
        groups = Dictionary(grouping: package?.cues ?? [], by: \.staff)
        barBounds = Dictionary(grouping: package?.cues ?? [], by: { "\($0.page):\($0.staff):\($0.printedMeasure)" }).values.compactMap { cues in
            guard let cue = cues.first else { return nil }
            let rect = cues.reduce(CGRect.null) { $0.union(CGRect(x: $1.x - 3, y: $1.y - 3, width: 6, height: 6)) }
            return (cue.page, cue.printedMeasure, rect)
        }
        lastAccessibilityUpdate = 0
        measureElements = Dictionary(grouping: package?.cues ?? [], by: \.printedMeasure).keys.sorted().compactMap { measure in
            guard let cue = package?.cues.first(where: { $0.printedMeasure == measure }) else { return nil }
            let element = ScoreAuditionMeasureElement(accessibilityContainer: self)
            element.cue = cue; element.owner = self; element.accessibilityTraits = .button
            element.accessibilityIdentifier = "scoreAuditionMeasure-\(measure)"
            element.accessibilityLabel = ScoreAuditionText.value("第 \(cue.printedMeasure) 小节，第 \(cue.page) 页", "Bar \(cue.printedMeasure), page \(cue.page)")
            return element
        }
        balls.values.forEach { $0.removeFromSuperlayer() }; balls.removeAll()
        for staff in groups.keys {
            let ball = CALayer(); ball.bounds = CGRect(x: 0, y: 0, width: 12, height: 12); ball.cornerRadius = 6
            ball.backgroundColor = (staff % 2 == 1 ? UIColor.systemBlue : UIColor.systemOrange).cgColor
            ball.borderWidth = 1.5; ball.borderColor = UIColor.white.cgColor; ball.isHidden = true
            layer.addSublayer(ball); balls[staff] = ball
        }
    }
    private func tick() {
        guard let player, let pdf = reader?.pdfView, let document = pdf.document else { return }
        if attachedPDF !== pdf { detachInteraction(); attachedPDF = pdf; pdf.addGestureRecognizer(scoreTap) }
        scoreTap.isEnabled = reader?.editing == false && reader?.voiceAudio.isBusy == false
        let time = player.visualPosition
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        updateSelection(pdf: pdf, document: document, player: player)
        for (staff, cues) in groups {
            guard let ball = balls[staff] else { continue }
            ball.isHidden = true
            var low = 0, high = cues.count
            while low < high { let mid = (low + high) / 2; if cues[mid].time <= time { low = mid + 1 } else { high = mid } }
            guard low > 0 else { continue }
            let cue = cues[low - 1]
            guard time < cue.time + cue.duration + 0.08, let page = document.page(at: cue.page - 1), pdf.visiblePages.contains(page) else { continue }
            let point = CGPoint(x: cue.x, y: cue.y)
            guard page.bounds(for: .cropBox).contains(point) else { continue }
            var destination = convert(pdf.convert(point, from: page), from: pdf)
            if !UIAccessibility.isReduceMotionEnabled, player.playing, low < cues.count {
                let next = cues[low], length = next.time - cue.time
                if next.page == cue.page, abs(next.y - cue.y) < 25, length > 0.02, length < 1.5 {
                    let other = convert(pdf.convert(CGPoint(x: next.x, y: next.y), from: page), from: pdf)
                    let fraction = min(1, max(0, (time - cue.time) / length))
                    destination.x += (other.x - destination.x) * fraction
                    destination.y += (other.y - destination.y) * fraction - sin(fraction * .pi) * 10
                }
            }
            guard destination.x.isFinite, destination.y.isFinite, bounds.contains(destination),
                  convert(pdf.bounds, from: pdf).contains(destination) else { continue }
            ball.position = destination; ball.isHidden = false
        }
    }
    func detachInteraction() { scoreTap.view?.removeGestureRecognizer(scoreTap); attachedPDF = nil }
    private func cue(at point: CGPoint) -> ScoreAuditionPackage.Cue? {
        guard let pdf = attachedPDF, let document = pdf.document, let page = pdf.page(for: point, nearest: false),
              pdf.bounds.contains(point), reader?.voiceHit(at: point) == nil else { return nil }
        let local = pdf.convert(point, to: page)
        if page.annotation(at: local)?.type == "Link" { return nil }
        let number = document.index(for: page) + 1
        var best: ScoreAuditionPackage.Cue?, distance = CGFloat(30)
        for cue in player?.package?.cues ?? [] where cue.page == number {
            let screen = pdf.convert(CGPoint(x: cue.x, y: cue.y), from: page)
            let d = hypot(screen.x - point.x, screen.y - point.y)
            if d < distance { best = cue; distance = d }
        }
        return best
    }
    @objc private func tappedScore(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, reader?.editing == false, let cue = cue(at: gesture.location(in: attachedPDF)) else { return }
        player?.tap(cue)
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard reader?.editing == false, reader?.voiceAudio.isBusy == false, touch.type != .pencil else { return false }
        // Both fingers must reach the recognizer, including a first finger
        // outside a note. Filtering that finger can turn a pinch into a tap
        // from the second finger alone. Hit-test the note only after a tap ends.
        if gestureRecognizer.numberOfTouches > 0 { return true }
        var ancestor = touch.view
        while let view = ancestor, view !== attachedPDF {
            if view is UIControl { return false }; ancestor = view.superview
        }
        return true
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        if let tap = other as? UITapGestureRecognizer, tap.numberOfTapsRequired > 1 { return false }
        return true
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRequireFailureOf other: UIGestureRecognizer) -> Bool {
        guard player?.selectingLoop != true else { return false }
        return (other as? UITapGestureRecognizer).map { $0.numberOfTapsRequired > 1 } ?? false
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        guard player?.selectingLoop == true else { return false }
        return (other as? UITapGestureRecognizer).map { $0.numberOfTapsRequired > 1 } ?? false
    }
    func activate(_ cue: ScoreAuditionPackage.Cue) -> Bool {
        guard reader?.editing == false, reader?.voiceAudio.isBusy == false else { return false }
        player?.tap(cue); return true
    }
    private func updateSelection(pdf: PDFView, document: PDFDocument, player: ScoreAuditionPlayer) {
        // Accessibility geometry does not need audio-frame frequency.
        if CACurrentMediaTime() - lastAccessibilityUpdate > 0.15 {
        lastAccessibilityUpdate = CACurrentMediaTime()
        var visible: [ScoreAuditionMeasureElement] = []
        for element in measureElements {
            guard let cue = element.cue, let page = document.page(at: cue.page - 1), pdf.visiblePages.contains(page) else { continue }
            let point = convert(pdf.convert(CGPoint(x: cue.x, y: cue.y), from: page), from: pdf)
            guard bounds.contains(point) else { continue }
            element.accessibilityFrameInContainerSpace = CGRect(x: point.x - 20, y: point.y - 20, width: 40, height: 40)
            element.accessibilityHint = player.selectingLoop ? ScoreAuditionText.value("选择循环端点", "Select loop endpoint") : ScoreAuditionText.value("从这里播放", "Play from here")
            visible.append(element)
        }
        accessibilityElements = reader?.editing == true ? [] : visible
        }
        let selected = player.selectingLoop ? player.loopAnchor.map { $0.printedMeasure...$0.printedMeasure }
            : player.loopEnabled ? player.loop.map { $0.firstMeasure...$0.lastMeasure } : nil
        let path = UIBezierPath()
        if let selected {
            // Bounds are calculated once per package, never regrouped at 60 Hz.
            for bar in barBounds where selected.contains(bar.measure) {
                guard let page = document.page(at: bar.page - 1), pdf.visiblePages.contains(page) else { continue }
                let displayed = convert(pdf.convert(bar.rect, from: page), from: pdf).insetBy(dx: -5, dy: -8)
                if displayed.intersects(bounds) { path.append(UIBezierPath(roundedRect: displayed, cornerRadius: 5)) }
            }
        }
        selectionLayer.path = path.cgPath
    }
    deinit { displayLink?.invalidate() }
}

private final class ScoreAuditionMeasureElement: UIAccessibilityElement {
    weak var owner: ScoreAuditionBallView?
    var cue: ScoreAuditionPackage.Cue?
    override func accessibilityActivate() -> Bool { guard let cue else { return false }; return owner?.activate(cue) ?? false }
}
#endif
