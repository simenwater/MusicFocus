import SwiftUI
import PDFKit

struct ScoreReaderView: View {
    let score: LibraryScore
    var showsImportConfirmation = false
    @EnvironmentObject private var library: ScoreLibrary
    @Environment(\.scoreExternalWindowID) private var externalWindowID
    @EnvironmentObject private var focus: FocusManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var reader = ScoreReaderController()
    @ObservedObject private var metronome = Metronome.shared
    @State private var showingJump = false
    @State private var pageInput = ""
    @State private var exporting = false
    @State private var exportItem: ScoreExportItem?
    @State private var isVisible = false
    @State private var closing = false
    @State private var showingTextEdit = false
    @State private var showingAnnotationHelp = false
    @State private var showingInkOptions = false
    @State private var editingColorPreset: ScoreInkPresetSelection?
    @State private var annotationText = ""
    @State private var importConfirmationVisible = false
    @State private var showingSync = false
    #if DEBUG || MUSICFOCUS_HOMR
    @State private var showingAudition = false
    #endif

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    readerToolbar(width: geometry.size.width)
                    if reader.editing { annotationTools }
                    if reader.ready {
                        ScorePracticeSurface(controller: reader)
                            .accessibilityIdentifier("scorePDF")
                            .overlay(alignment: .bottom) {
                                if reader.editing && reader.tool == .cover && reader.selectedCover == nil {
                                    Text("score.pageCoverHint".localized).font(.caption)
                                        .padding(10).background(.regularMaterial,in: RoundedRectangle(cornerRadius: 12))
                                        .frame(maxWidth: 340).padding(12).allowsHitTesting(false)
                                        .accessibilityIdentifier("scoreCoverHint")
                                } else if reader.editing && reader.tool == .select && reader.selectedCover == nil && reader.selectedAnnotation == nil {
                                    Text("score.selectionMoveHint".localized).font(.caption)
                                        .padding(10).background(.regularMaterial,in: RoundedRectangle(cornerRadius: 12))
                                        .frame(maxWidth: 380).padding(12).allowsHitTesting(false)
                                        .accessibilityIdentifier("scoreSelectionHint")
                                }
                            }
                            .overlay(alignment: .top) {
                                if let note = reader.selectedVoiceNote {
                                    ScoreVoiceNotePanel(reader: reader, audio: reader.voiceAudio, note: note)
                                        .id(note.id).frame(maxWidth: min(380, max(240, geometry.size.width-24))).padding(.top, 8)
                                } else if reader.movingVoiceID != nil {
                                    HStack {
                                        Text("score.voiceMoveHint".localized)
                                        Button("Cancel".localized) { reader.movingVoiceID = nil }
                                    }.font(.callout).padding(12).background(.regularMaterial, in: Capsule()).padding(.top, 8)
                                } else if reader.editing && reader.selectedCover != nil {
                                    ScoreCoverControls(reader: reader)
                                        .padding(12).frame(width: min(340,max(240,geometry.size.width-24)))
                                        .background(.regularMaterial,in: RoundedRectangle(cornerRadius: 14)).padding(.top,8)
                                } else if reader.selectedFingering != nil {
                                    ScoreFingeringCorrection(reader: reader).padding(.top, 8)
                                }
                            }
                    } else {
                        Spacer()
                        ProgressView("score.loading".localized)
                        Spacer()
                    }
                }
            }
            .background(Color(.secondarySystemBackground))
            .navigationTitle(score.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
            .overlay { if exporting { ProgressView("score.exporting".localized).padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14)) } }
        }
        .overlay(alignment: .bottom) {
            if importConfirmationVisible {
                Label("score.importSaved".localized, systemImage: "checkmark.circle.fill")
                    .font(.callout).padding(14).background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 20).allowsHitTesting(false)
                    .accessibilityIdentifier("scoreImportSaved")
            }
        }
        .task {
            await reader.load(score: score, disk: library.disk)
            if showsImportConfirmation && reader.ready {
                importConfirmationVisible = true
                try? await Task.sleep(for: .seconds(3))
                importConfirmationVisible = false
            }
        }
        .onAppear { isVisible = true; reader.voiceAudio.bind(focus); updateContext() }
        .onDisappear {
            isVisible = false
            clearContext()
            UIApplication.shared.isIdleTimerDisabled = focus.isActive
            Task { await reader.voiceAudio.stop(); _ = await reader.flush() }
        }
        .onChange(of: reader.pages) { _, _ in updateContext() }
        .onChange(of: library.pendingExternalScore?.id) { _, id in
            guard library.handlesExternalFiles(in: externalWindowID), id != nil else { return }
            if id == score.id {
                library.pendingExternalScore = nil
            } else {
                showingJump = false
                showingTextEdit = false
                showingAnnotationHelp = false
                showingInkOptions = false
                editingColorPreset = nil
                exportItem = nil
                close()
            }
        }
        .onChange(of: library.errorMessage) { _, message in
            if let message, isVisible {
                reader.errorMessage = message
                library.errorMessage = nil
            }
        }
        .onChange(of: scenePhase) { _, _ in
            updateContext()
            if scenePhase == .background { Task { await reader.voiceAudio.stop(); _ = await reader.flush(); await library.persist() } }
        }
        .onChange(of: focus.isActive) { _, _ in
            if isVisible && scenePhase == .active { UIApplication.shared.isIdleTimerDisabled = true }
        }
        .onChange(of: metronome.isRunning) { _, _ in updateContext() }
        .onChange(of: metronome.tempo) { _, _ in updateContext() }
        .onChange(of: metronome.timeSignature) { _, _ in updateContext() }
        .onChange(of: exportItem?.id) { _, _ in updateContext() }
        .modifier(PageBadgeSupport(reader: reader, score: score, focus: focus))
        .modifier(PedalFocusRestorer(reader: reader, closedAlerts: [showingJump, showingTextEdit, showingInkOptions, editingColorPreset != nil, exportItem != nil, reader.badgePage != nil]))
        .modifier(ScoreSyncSupport(reader: reader, score: score, presented: $showingSync))
        #if DEBUG || MUSICFOCUS_HOMR
        .modifier(ScoreAuditionSupport(reader: reader, presented: $showingAudition))
        #endif
        .sheet(item: $editingColorPreset) { preset in
            ScoreInkPresetEditor(reader: reader, index: preset.index)
        }
        .sheet(item: $exportItem) { item in
            ScoreShareSheet(url: item.url)
        }
        .alert("score.editText".localized, isPresented: $showingTextEdit) {
            TextField("score.note".localized, text: $annotationText)
            Button("Save".localized) { reader.setSelectedText(annotationText) }
            Button("Cancel".localized, role: .cancel) { }
        }
        .alert("score.jump".localized, isPresented: $showingJump) {
            TextField("score.pageNumber".localized, text: $pageInput).keyboardType(.numberPad)
            Button("score.go".localized) {
                if let page = Int(pageInput), (1...score.pageCount).contains(page) { reader.go(to: page) }
            }
            Button("Cancel".localized, role: .cancel) { }
        }
        .alert("score.error".localized, isPresented: Binding(get: { reader.errorMessage != nil }, set: { if !$0 { reader.errorMessage = nil } })) {
            Button("OK".localized) { reader.errorMessage = nil }
        } message: { Text(reader.errorMessage ?? "") }
    }

    private var annotationTools: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(ScoreInkTool.toolbarTools, id: \.self) { tool in
                        let selected = reader.tool == tool || (tool == .pen && reader.tool.isPen)
                        Button {
                            if selected && (tool.inkType != nil || tool == .cover) { showingInkOptions = true }
                            else { reader.tool = tool == .pen ? reader.preferredPenTool : tool }
                        } label: {
                            Group {
                                if tool == .fingering { Text("1–5").font(.system(.callout, design: .rounded).weight(.semibold)) }
                                else if tool == .cover { Label("score.cover".localized, systemImage: tool.symbol).font(.callout) }
                                else { Image(systemName: tool.symbol).font(.system(size: 21)) }
                            }
                            .foregroundStyle(selected ? Color.accentColor : .secondary)
                            .frame(width: tool == .cover ? 76 : 44, height: 44)
                            .background(selected ? Color.accentColor.opacity(0.12) : .clear,
                                        in: RoundedRectangle(cornerRadius: 10))
                        }
                        .accessibilityLabel((tool == .pen ? "score.penGroup" : "score." + tool.rawValue).localized)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        .accessibilityIdentifier("scoreTool-\(tool.rawValue)")
                    }
                    if reader.tool == .fingering {
                        Button { reader.setFingeringCoverEnabled(!reader.fingeringCoverEnabled) } label: {
                            Label("score.cover".localized, systemImage: reader.fingeringCoverEnabled ? "checkmark.square.fill" : "square")
                                .font(.callout).frame(minHeight: 44)
                        }
                        .accessibilityLabel("score.fingeringCover".localized)
                        .accessibilityValue(reader.fingeringCoverEnabled ? "On".localized : "Off".localized)
                        .accessibilityIdentifier("scoreFingeringCoverQuick")
                    }
                    Divider().frame(height: 26).padding(.horizontal, 2)
                    ForEach(reader.inkColorPresets.indices, id: \.self) { index in
                        let color = reader.inkColorPresets[index]
                        Button {
                            if ScoreAnnotationColor(reader.currentColor) == color { editingColorPreset = .init(index: index) }
                            else { reader.chooseColor(color.uiColor) }
                        } label: {
                            ScoreInkSwatch(color: color, selected: ScoreAnnotationColor(reader.currentColor) == color)
                        }
                        .accessibilityLabel(ScoreInkPalette.label(for: color))
                        .accessibilityValue(ScoreInkPalette.label(for: color))
                        .accessibilityAddTraits(ScoreAnnotationColor(reader.currentColor) == color ? .isSelected : [])
                        .accessibilityHint("score.directColorHint".localized)
                        .accessibilityIdentifier("scoreQuickColor-\(index)")
                        .accessibilityAction(named: Text("score.editColorPreset".localized)) {
                            if reader.tool.inkType != nil { reader.chooseColor(color.uiColor) }
                            editingColorPreset = .init(index: index)
                        }
                    }
                    if reader.selectedInkCount > 0 {
                        Button { reader.deleteSelectedInk() } label: { Image(systemName: "trash") }
                            .accessibilityLabel("score.deleteAnnotation".localized).accessibilityIdentifier("scoreDeleteInkSelection")
                    }
                    if reader.selectedAnnotation != nil {
                        Button { reader.deleteSelectedAnnotation() } label: { Image(systemName: "trash") }
                            .accessibilityLabel("score.deleteAnnotation".localized).accessibilityIdentifier("scoreDeleteAnnotation")
                        if let text = reader.selectedText {
                            Button { annotationText = text; showingTextEdit = true } label: { Image(systemName: "text.cursor") }
                                .accessibilityLabel("score.editText".localized)
                        }
                    }
                    Button { reader.fingerDrawing.toggle() } label: {
                        Image(systemName: "hand.draw").font(.system(size: 21))
                            .foregroundStyle(reader.fingerDrawing ? Color.accentColor : .secondary)
                            .frame(width: 44, height: 44)
                            .background(reader.fingerDrawing ? Color.accentColor.opacity(0.12) : .clear,
                                        in: RoundedRectangle(cornerRadius: 10))
                    }
                    .accessibilityLabel("score.finger".localized)
                    .accessibilityAddTraits(reader.fingerDrawing ? .isSelected : [])
                    .accessibilityIdentifier("scoreFingerDrawing")
                    Button { showingAnnotationHelp = true } label: { Image(systemName: "questionmark.circle") }
                        .accessibilityLabel("score.annotationHelpTitle".localized)
                        .popover(isPresented: $showingAnnotationHelp) {
                            Text("score.annotationHelp".localized)
                                .font(.callout).frame(width: 300, alignment: .leading).padding()
                                .presentationCompactAdaptation(.popover)
                        }
                    Text(reader.hasUnsavedChanges ? "score.saving".localized : "score.saved".localized)
                        .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("scoreSaveStatus")
                }
            }
            .accessibilityIdentifier("scoreInkToolbar")
            Divider().frame(height: 26)
            // These actions stay visible even on a narrow window.
            Button { showingInkOptions = true } label: {
                Image(systemName: "slider.horizontal.3").font(.system(size: 21))
                    .foregroundStyle(reader.tool == .cover || reader.selectedCover != nil ? Color.primary : Color(uiColor: reader.currentColor))
            }
            .disabled(reader.tool == .voice || reader.tool == .eraser || (reader.tool == .select && reader.selectedAnnotation == nil && reader.selectedCover == nil))
            .accessibilityLabel("score.inkOptions".localized)
            .accessibilityIdentifier("scoreInkOptions")
            .popover(isPresented: $showingInkOptions) {
                Group {
                    if reader.tool == .cover || reader.selectedCover != nil { ScoreCoverControls(reader: reader).padding(20).frame(width: 340) }
                    else { ScoreInkOptions(reader: reader) }
                }.presentationCompactAdaptation(.sheet)
            }
            Button { reader.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!reader.canUndo).accessibilityLabel("score.undo".localized).accessibilityIdentifier("scoreUndo")
            Button { reader.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!reader.canRedo).accessibilityLabel("score.redo".localized).accessibilityIdentifier("scoreRedo")
        }
        .buttonStyle(ScoreInkToolbarButtonStyle())
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.regularMaterial)
    }

    // One stable row owns the session/receipt and popovers, including during rotation.
    // Use the actual window width: iPad multitasking can be narrower than a phone.
    private func readerToolbar(width: CGFloat) -> some View {
        let compact = width < 760
        return HStack(spacing: compact ? 0 : 6) {
            Button { close() } label: {
                Image(systemName: "chevron.left").frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .disabled(closing).accessibilityLabel("score.library".localized)
            .accessibilityIdentifier("scoreReaderClose")
            PracticeSessionControls(density: compact ? .minimal : .condensed, score: score, visiblePage: reader.pages.first,
                                    onDismiss: { reader.focusKeys() })
                .fixedSize(horizontal: true, vertical: false)
                .disabled(!reader.ready)
            ScoreMetronomePill(metronome: metronome, compact: compact)
                .fixedSize(horizontal: true, vertical: false)
            if width >= 600 {
                Text(score.title).font(.subheadline.weight(.semibold))
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity).accessibilityAddTraits(.isHeader)
            } else {
                Spacer(minLength: 0)
            }
            Button { reader.editing.toggle() } label: {
                Image(systemName: reader.editing ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle")
                    .foregroundStyle(reader.editing ? Color.orange : Color.accentColor)
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .accessibilityLabel("score.annotate".localized).accessibilityIdentifier("scoreAnnotate")
            if compact {
                Menu {
                    #if DEBUG || MUSICFOCUS_HOMR
                    auditionAction
                    Divider()
                    #endif
                    pageActions
                    Divider()
                    displayActions
                    Divider()
                    exportActions
                    Divider()
                    Button("score.sync.title".localized, systemImage: "dot.radiowaves.left.and.right") { showingSync = true }
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "ellipsis")
                        Text(pageLabel).font(.system(size: 10, weight: .medium, design: .monospaced))
                            .lineLimit(1).minimumScaleFactor(0.7)
                    }.frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .accessibilityLabel("score.readerOptions".localized)
                .accessibilityValue(pageLabel).accessibilityIdentifier("scoreReaderOptions")
                .disabled(!reader.ready)
            } else {
                #if DEBUG || MUSICFOCUS_HOMR
                auditionAction.labelStyle(.iconOnly)
                #endif
                Menu { pageActions } label: {
                    Text(pageLabel).font(.caption.monospacedDigit().weight(.medium))
                        .foregroundStyle(.secondary).frame(minWidth: 52, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(ScorePageLabel.text(reader.pages) + " / \(score.pageCount)")
                .accessibilityIdentifier("scorePageLabel").disabled(!reader.ready)
                displayActions.labelStyle(.iconOnly)
                Menu { exportActions } label: {
                    Image(systemName: "square.and.arrow.up").frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .disabled(exporting || !reader.ready)
                .accessibilityLabel("score.export".localized).accessibilityIdentifier("scoreExport")
                Button { showingSync = true } label: {
                    Image(systemName: "dot.radiowaves.left.and.right").frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .disabled(!reader.ready)
                .accessibilityLabel("score.sync.title".localized).accessibilityIdentifier("scoreSync")
            }
        }
        .buttonStyle(.borderless).tint(.accentColor)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .padding(.horizontal, compact ? 4 : 12).frame(height: 52).background(.bar)
    }

    private var pageLabel: String {
        (reader.pages.isEmpty ? "—" : reader.pages.map(String.init).joined(separator: "–")) + " / \(score.pageCount)"
    }

    #if DEBUG || MUSICFOCUS_HOMR
    private var auditionAction: some View {
        Button { showingAudition.toggle() } label: {
            Label(ScoreAuditionText.value("听谱（实验）", "Audition (Preview)"), systemImage: "play.circle")
                .frame(minWidth: 44, minHeight: 44)
        }.disabled(!reader.ready).accessibilityIdentifier("scoreAudition")
    }
    #endif

    @ViewBuilder private var pageActions: some View {
        Button("score.previous".localized, systemImage: "chevron.up") { reader.go(by: -1) }
            .disabled((reader.pages.first ?? 1) <= 1)
            .accessibilityIdentifier("scorePreviousPage")
        Button("score.next".localized, systemImage: "chevron.down") { reader.go(by: 1) }
            .disabled((reader.pages.last ?? 1) >= score.pageCount)
            .accessibilityIdentifier("scoreNextPage")
        Button("score.jump".localized, systemImage: "number") {
            pageInput = String(reader.pages.first ?? 1); showingJump = true
        }
        Button("score.fitPage".localized, systemImage: "arrow.down.right.and.arrow.up.left") { reader.fitPage() }
            .accessibilityIdentifier("scoreFitPage")
    }

    @ViewBuilder private var displayActions: some View {
        Button { reader.showsPageBadges.toggle() } label: {
            Label("score.pageBadges".localized, systemImage: reader.showsPageBadges ? "tag.fill" : "tag")
                .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        }.accessibilityIdentifier("scorePageBadges")
        Button { reader.twoPages.toggle() } label: {
            Label("score.twoPages".localized, systemImage: reader.twoPages ? "rectangle.split.2x1.fill" : "rectangle.split.2x1")
                .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        }.accessibilityIdentifier("scoreTwoPages")
    }

    @ViewBuilder private var exportActions: some View {
        if !reader.voiceNotes.isEmpty { Text("score.voicePDFHint".localized) }
        Button("score.exportEditable".localized, systemImage: "pencil.tip") { export(flattened: false) }
            .disabled(exporting || !reader.ready)
        Button("score.exportPrint".localized, systemImage: "printer") { export(flattened: true) }
            .disabled(exporting || !reader.ready)
        Divider()
        Button("score.exportOriginal".localized, systemImage: "doc.on.doc") {
            exporting = true
            Task {
                if let url = await reader.exportOriginal() { exportItem = ScoreExportItem(url: url) }
                exporting = false
            }
        }
        .disabled(exporting || !reader.ready)
        .accessibilityIdentifier("scoreExportOriginal")
    }

    private func export(flattened: Bool) {
        exporting = true
        Task {
            if let url = await reader.export(flattened: flattened) { exportItem = ScoreExportItem(url: url) }
            exporting = false
        }
    }

    private func updateContext() {
        guard isVisible, !closing, scenePhase == .active, !reader.pages.isEmpty,
              exportItem == nil else { clearContext(); return }
        UIApplication.shared.isIdleTimerDisabled = true
        let now = Date()
        library.beginViewing(score, pages: reader.pages, at: now)
        let tempo = metronome.isRunning ? ScorePracticeTempo(bpm: metronome.tempo, signature: metronome.timeSignature.storageValue) : nil
        focus.setScoreContext(ScorePracticeContext(scoreID: score.id, title: score.title, pages: reader.pages, tempo: tempo), at: now)
    }

    private func clearContext() {
        let now = Date()
        library.endViewing(at: now)
        focus.setScoreContext(nil, at: now)
    }

    private func close() {
        guard !closing else { return }
        closing = true
        clearContext()
        Task {
            await reader.voiceAudio.stop()
            if await reader.flush(), await library.persist() { dismiss() }
            else { closing = false; updateContext(); reader.errorMessage = "score.annotationSaveError".localized }
        }
    }
}

private struct ScoreMetronomePill: View {
    @ObservedObject var metronome: Metronome
    var compact = false
    @State private var expanded = false
    var body: some View {
        HStack(spacing: 0) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 6) {
                    if !compact {
                        ScoreBeatLight(metronome: metronome)
                        Text("\(metronome.tempo)").font(.caption.monospacedDigit().weight(.semibold))
                    }
                    Image(systemName: "metronome").font(.caption)
                }.padding(.leading, compact ? 8 : 11).padding(.trailing, 8)
                    .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
            }
            .accessibilityLabel("节拍器".localized)
            .accessibilityValue("\(metronome.tempo)")
            .accessibilityIdentifier("scoreMetronome")
            .popover(isPresented: $expanded) {
                MetronomePanel(metronome: metronome, tint: .blue)
                    .frame(width: 330, height: 480)
                    .presentationCompactAdaptation(.popover)
            }
            if !compact {
                Button { metronome.toggle() } label: {
                    Image(systemName: metronome.isRunning ? "stop.fill" : "play.fill")
                        .font(.caption2).frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .accessibilityLabel(metronome.isRunning ? "停止节拍器".localized : "开始节拍器".localized)
                .accessibilityIdentifier("scoreMetronomeToggle")
            }
        }
        .buttonStyle(.plain).foregroundStyle(.blue)
        .background { Capsule().fill(Color.blue.opacity(0.08)).frame(height: 30) }
    }
}

private struct ScoreBeatLight: View {
    @ObservedObject var metronome: Metronome
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !metronome.isRunning)) { _ in
            let position = metronome.isRunning ? metronome.beatPosition() : nil
            Circle().fill(Color.blue.opacity((position?.phase ?? 1) < 0.25 ? 1 : 0.2))
                .frame(width: 7, height: 7)
        }.accessibilityHidden(true)
    }
}

private extension FocusManager {
    var scoreIsPracticing: Bool { isActive && !isManuallyPaused && currentDistraction == nil && pendingSilenceStart == nil }
}

private struct ScorePracticeSurface: View {
    @EnvironmentObject private var focus: FocusManager
    let controller: ScoreReaderController
    var body: some View {
        let active = focus.scoreIsPracticing
        ScorePDFView(controller: controller, practicing: active)
            .padding(.horizontal, 6)
            .background(Color(ScorePDFView.background(practicing: active)))
            .animation(.easeInOut(duration: 0.25), value: active)
    }
}

private struct ScorePDFView: UIViewRepresentable {
    let controller: ScoreReaderController
    let practicing: Bool
    private static let practiceBackground = UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(red: 0.08, green: 0.18, blue: 0.13, alpha: 1)
                : UIColor(red: 0.86, green: 0.94, blue: 0.88, alpha: 1)
    }
    static func background(practicing: Bool) -> UIColor {
        practicing ? practiceBackground : .secondarySystemBackground
    }
    func makeUIView(context: Context) -> ScoreReaderViewport {
        let view = ScoreReaderViewport()
        controller.attach(view.pdfView, badgeHost: view)
        return view
    }
    func updateUIView(_ container: ScoreReaderViewport, context: Context) {
        let view = container.pdfView
        let color = Self.background(practicing: practicing)
        guard view.backgroundColor != color else { return }
        UIView.animate(withDuration: 0.25) { view.backgroundColor = color }
    }
    func makeCoordinator() -> ScoreReaderController { controller }
    static func dismantleUIView(_ view: ScoreReaderViewport, coordinator: ScoreReaderController) { coordinator.detach() }
}

private struct ScoreExportItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct ScoreShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        return controller
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) { }
}

/// Alerts with text fields and the share sheet take the keyboard focus;
/// give page-turn pedals their keys back once they close.
private struct PedalFocusRestorer: ViewModifier {
    let reader: ScoreReaderController
    let closedAlerts: [Bool]
    func body(content: Content) -> some View {
        content.onChange(of: closedAlerts) { _, presented in
            if !presented.contains(true) { reader.focusKeys() }
        }
    }
}

/// Feeds each page's practice tag and opens that page's details when tapped.
/// Practice in the session still running is added when the session ends.
private struct PageBadgeSupport: ViewModifier {
    @ObservedObject var reader: ScoreReaderController
    let score: LibraryScore
    @ObservedObject var focus: FocusManager
    @State private var summary: ScorePracticeSummary?
    private struct PageRef: Identifiable { let page: Int; var id: Int { page } }
    private struct Request: Equatable {
        var ready: Bool
        var key: ScorePracticeSummaryCache.Key
    }
    private var request: Request {
        .init(ready: reader.ready, key: .init(history: focus.scoreHistoryRevision, day: Calendar.current.startOfDay(for: Date())))
    }

    func body(content: Content) -> some View {
        content
            .task(id: request) {
                let request = request
                guard request.ready else { return }
                let result = await focus.scoreSummaryCache.summaries(key: request.key, sessions: focus.allSessions,
                                                                     visits: [], asOf: Date())
                guard !Task.isCancelled else { return }
                summary = result.first { $0.id == score.id }
                reader.setPageBadges(ScorePageBadgeInfo.make(details: summary?.pages ?? [:], pageCount: score.pageCount))
            }
            .sheet(item: Binding(get: { reader.badgePage.map(PageRef.init) },
                                 set: { reader.badgePage = $0?.page })) { ref in
                ScorePageHistoryView(page: ref.page, detail: summary?.pages[ref.page] ?? .init(),
                                     thumbnail: reader.document?.page(at: ref.page - 1)?
                                        .thumbnail(of: CGSize(width: 148, height: 192), for: .cropBox))
                    .presentationDetents([.medium, .large])
            }
    }

}

private struct ScoreFingeringCorrection: View {
    @ObservedObject var reader: ScoreReaderController
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("score.correctFingering".localized).font(.subheadline.weight(.medium))
                Spacer()
                Button(role: .destructive) { reader.deleteSelectedFingering() } label: { Image(systemName: "trash") }
                    .frame(width: 32, height: 44).accessibilityLabel("Delete".localized).accessibilityIdentifier("scoreFingeringDelete")
                Button { reader.selectedFingering = nil } label: { Image(systemName: "xmark") }
                    .accessibilityLabel("Close".localized).accessibilityIdentifier("scoreFingeringDismiss")
            }
            HStack(spacing: 8) {
                ForEach(1...5, id: \.self) { digit in
                    Button { reader.correctFingering(to: digit) } label: {
                        Text(reader.selectedFingering?.mark.circled == true ? ["①", "②", "③", "④", "⑤"][digit-1] : "\(digit)")
                            .font(.title2.weight(.medium)).frame(width: 44, height: 44)
                            .background(reader.selectedFingering?.mark.digit == digit ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    }.accessibilityIdentifier("scoreFingeringChoice-\(digit)")
                }
            }
            Text("score.fingeringMoveHint".localized).font(.caption).foregroundStyle(.secondary)
            ScoreFingeringCoverControls(enabled: Binding(get: { reader.selectedFingering?.mark.cover != nil },
                set: { reader.setSelectedFingeringCover($0 ? reader.fingeringCoverStyle : nil) }),
                style: Binding(get: { reader.selectedFingering?.mark.cover ?? reader.fingeringCoverStyle },
                               set: { reader.setSelectedFingeringCover($0) }))
        }
        .padding(12).frame(width: 292)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("scoreFingeringCorrection")
    }
}
