import SwiftUI
import AVFAudio

/// Shared session actions. Only the small time label redraws once per second.
struct PracticeSessionControls: View {
    enum Style { case compact, banner, full }
    enum Density { case standard, condensed, minimal }
    var style: Style = .compact
    var density: Density = .standard
    var score: LibraryScore? = nil
    var visiblePage: Int? = nil
    var onDismiss: () -> Void = {}
    @EnvironmentObject private var focus: FocusManager
    @State private var settings = false
    @State private var receipt: FocusSession?
    @State private var pageAtFinish: Int?
    @State private var password = ""
    @State private var asksPassword = false
    @State private var passwordIncorrect = false
    @State private var pendingAction: Action = .finish
    private enum Action { case pause, finish }

    var body: some View {
        VStack(spacing: 0) {
            if style != .banner || focus.isActive {
                HStack(spacing: density == .minimal ? 0 : (density == .condensed ? 4 : 10)) {
                    if style == .banner {
                        Label("practice.activeSession".localized, systemImage: "waveform")
                            .font(.subheadline.weight(.medium))
                        Spacer(minLength: 4)
                    }
                    Button {
                        if !focus.isActive { focus.startSession() }
                        else if focus.isManuallyPaused { focus.resumePractice() }
                        else { request(.pause) }
                    } label: {
                        PracticeControlLabel(large: style == .full, density: density)
                            .frame(maxWidth: style == .full ? .infinity : nil)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("practicePrimaryAction")
                    .accessibilityLabel((!focus.isActive ? "score.startPractice" :
                        (focus.isManuallyPaused ? "practice.resume" : "practice.pause")).localized)

                    if focus.isActive {
                        Button { request(.finish) } label: {
                            Group {
                                if style == .compact { Image(systemName: "stop.fill") }
                                else { Label("score.stopPractice".localized, systemImage: "stop.fill") }
                            }
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 12).frame(minWidth: 44, minHeight: 44)
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("score.stopPractice".localized)
                        .accessibilityIdentifier("practiceEnd")
                    }
                    if style == .compact {
                        Button { settings = true } label: {
                            Image(systemName: "slider.horizontal.3")
                                .frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("practice.options".localized)
                        .accessibilityIdentifier("practiceOptions")
                        .popover(isPresented: $settings) {
                            PracticeOptionsPanel()
                                .padding(20).frame(width: 300)
                                .presentationCompactAdaptation(.popover)
                        }
                    }
                }
                .padding(style == .banner ? 12 : 0)
                .background {
                    if style == .banner {
                        RoundedRectangle(cornerRadius: 16).fill(Color.blue.opacity(0.07))
                    }
                }
            }
        }
        .sheet(item: $receipt, onDismiss: onDismiss) { session in
            PracticeSessionReceipt(session: session, scoreID: score?.id ?? session.scoreIntervals?.last?.context.scoreID,
                                   page: score == nil ? session.scoreIntervals?.last?.context.pages.first : pageAtFinish)
        }
        .alert("Password Required".localized, isPresented: $asksPassword) {
            SecureField("Enter Password".localized, text: $password)
            Button("Confirm".localized) {
                if focus.verifyPassword(password) { perform(pendingAction) }
                else { passwordIncorrect = true }
                password = ""
            }
            Button("Cancel".localized, role: .cancel) { password = "" }
        }
        .alert("score.passwordIncorrect".localized, isPresented: $passwordIncorrect) {
            Button("OK".localized, role: .cancel) { }
        }
        .onChange(of: settings) { _, value in if !value { onDismiss() } }
        .onChange(of: asksPassword) { _, value in if !value { onDismiss() } }
    }

    private func request(_ action: Action) {
        if focus.isPasswordProtected {
            pendingAction = action
            asksPassword = true
        } else { perform(action) }
    }

    private func perform(_ action: Action) {
        switch action {
        case .pause: focus.pausePractice()
        case .finish:
            guard let id = focus.currentSession?.id else { return }
            let content = score.map { PracticeContent(pieceName: $0.title, improvements: "", notes: "") }
            pageAtFinish = visiblePage
            focus.endSession(practiceContent: content)
            receipt = focus.allSessions.first { $0.id == id }
        }
    }
}

private struct PracticeControlLabel: View {
    var large = false
    var density: PracticeSessionControls.Density = .standard
    @EnvironmentObject private var focus: FocusManager
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            Group {
                if density == .minimal {
                    VStack(spacing: 2) {
                        Image(systemName: !focus.isActive || focus.isManuallyPaused ? "play.fill" : "pause.fill")
                            .font(.caption2)
                        Text(focus.isActive ? compactTime(focus.getFullSessionStats(at: timeline.date).totalFocusTime)
                             : "Practice Tab".localized)
                            .font(.caption2).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                            .accessibilityIdentifier("practiceLiveTime")
                    }
                    .frame(width: 44, height: 44)
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: !focus.isActive || focus.isManuallyPaused ? "play.fill" : "pause.fill")
                            .font(.caption)
                        if focus.isActive {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(TimeFormatter.formatTimeInterval(focus.getFullSessionStats(at: timeline.date).totalFocusTime))
                                    .monospacedDigit().font(.subheadline.weight(.semibold))
                                    .lineLimit(1).accessibilityIdentifier("practiceLiveTime")
                                if density == .standard {
                                    Text(statusKey.localized).font(.caption2).lineLimit(1)
                                }
                            }
                        } else {
                            Text((density == .standard ? "score.startPractice" : "Practice Tab").localized)
                                .font(.subheadline.weight(.semibold)).lineLimit(1)
                        }
                    }
                    .padding(.horizontal, large ? 20 : 12).frame(minHeight: large ? 52 : 44)
                }
            }
            .frame(maxWidth: large ? .infinity : nil)
            .foregroundStyle(!focus.isActive ? Color.white : (isPlaying ? .green : .primary))
            .background(!focus.isActive ? Color.blue : (isPlaying ? Color.green.opacity(0.1) : Color.primary.opacity(0.06)),
                        in: RoundedRectangle(cornerRadius: 12))
        }
    }
    private var isPlaying: Bool {
        focus.isActive && !focus.isManuallyPaused && focus.currentDistraction == nil && focus.pendingSilenceStart == nil
    }
    private func compactTime(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        if seconds >= 3600 {
            return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
        }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
    private var statusKey: String {
        if focus.isManuallyPaused { return "practice.paused" }
        if AVAudioApplication.shared.recordPermission == .denied { return "practice.microphoneRequired" }
        return focus.currentDistraction != nil || focus.pendingSilenceStart != nil ? "score.waitingSound" : "score.detectingPractice"
    }
}

private struct PracticeOptionsPanel: View {
    @EnvironmentObject private var focus: FocusManager
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("practice.options".localized).font(.headline)
            PracticeModePicker()
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("practice.mergePauses".localized)
                    Spacer()
                    Text("duration.seconds".localizedFormat(Int(focus.silenceConfirmationDelay))).monospacedDigit()
                }
                Slider(value: Binding(get: { focus.silenceConfirmationDelay },
                                      set: { focus.selectSilenceConfirmationDelay($0) }), in: SilenceConfirmationSettings.delayRange, step: 1)
                    .disabled(focus.isActive)
                    .accessibilityLabel("practice.mergePauses".localized)
                    .accessibilityValue("duration.seconds".localizedFormat(Int(focus.silenceConfirmationDelay)))
                    .accessibilityIdentifier("practiceSilenceDelaySlider")
                Text("practice.silenceNotCounted".localized).font(.caption).foregroundStyle(.secondary)
            }
            if focus.isActive { PracticeAudioStatusView(monitor: focus.audioMonitor) }
        }
    }
}

/// The session is already saved before this optional note form appears.
struct PracticeSessionReceipt: View {
    let session: FocusSession
    var scoreID: UUID?
    var page: Int?
    @State private var markPage = false
    @EnvironmentObject private var focus: FocusManager
    @EnvironmentObject private var library: ScoreLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var pieceName = ""
    @State private var notes = ""
    @State private var saving = false
    @State private var saveFailed = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("practice.sessionSaved".localized, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    LabeledContent("practice.detectedTime".localized,
                                   value: TimeFormatter.formatTimeInterval(session.totalFocusTime))
                    LabeledContent("practice.uncountedTime".localized,
                                   value: TimeFormatter.formatTimeInterval(session.distractionTime))
                }
                Section("practice.practicedToday".localized) {
                    if let intervals = session.scoreIntervals, !intervals.isEmpty {
                        ForEach(scoreContexts, id: \.id) { context in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(context.title)
                                Text(ScorePageLabel.text(context.pages)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        TextField("Enter practice piece".localized, text: $pieceName)
                            .accessibilityIdentifier("practiceReceiptPiece")
                    }
                }
                Section {
                    if let page, library.scores.contains(where: { $0.id == scoreID && page >= 1 && page <= $0.pageCount }) {
                        Toggle("practice.markPage".localizedFormat(page), isOn: $markPage)
                            .accessibilityIdentifier("practiceMarkPage")
                    }
                    TextEditor(text: $notes).frame(minHeight: 90)
                        .accessibilityLabel("practice.nextNote".localized)
                        .accessibilityIdentifier("practiceNextNote")
                        .onChange(of: notes) { _, value in if value.count > 500 { notes = String(value.prefix(500)) } }
                } header: { Text("practice.nextNote".localized) }
                  footer: { Text("practice.noteOptional".localized) }
            }
            .navigationTitle("practice.receiptTitle".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("practice.skipNote".localized) { dismiss() }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save".localized) { save() }.disabled(saving)
                        .accessibilityIdentifier("practiceReceiptSave")
                }
            }
            .interactiveDismissDisabled(saving)
            .onAppear {
                pieceName = session.practiceContent?.pieceName ?? ""
                if pieceName.isEmpty { pieceName = scoreContexts.map(\.title).joined(separator: " / ") }
                notes = session.practiceContent?.notes ?? ""
            }
            .alert("score.error".localized, isPresented: $saveFailed) {
                Button("OK".localized, role: .cancel) { }
            } message: { Text("practice.noteSaveFailed".localized) }
        }
        .presentationDetents([.large])
    }

    private struct ScoreContext: Identifiable { var id: UUID; var title: String; var pages: [Int] }
    private var scoreContexts: [ScoreContext] {
        var contexts: [ScoreContext] = []
        for interval in session.scoreIntervals ?? [] {
            if let index = contexts.firstIndex(where: { $0.id == interval.context.scoreID }) {
                contexts[index].pages = Array(Set(contexts[index].pages + interval.context.pages)).sorted()
            } else {
                contexts.append(.init(id: interval.context.scoreID, title: interval.context.title,
                                      pages: interval.context.pages))
            }
        }
        return contexts
    }
    private func save() {
        saving = true
        Task {
            if let scoreID, let score = library.scores.first(where: { $0.id == scoreID }),
               markPage || !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let reminder = notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? (score.nextPracticeNote ?? "") : notes
                guard await library.setNextPracticePlan(scoreID, note: reminder,
                                                        page: markPage ? page : score.nextPracticePage) else {
                    saveFailed = true; saving = false; return
                }
            }
            guard focus.updatePracticeContent(sessionID: session.id, pieceName: pieceName, notes: notes) else {
                saveFailed = true; saving = false; return
            }
            saving = false
            dismiss()
        }
    }
}
