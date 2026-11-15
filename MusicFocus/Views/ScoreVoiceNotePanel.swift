import SwiftUI

struct ScoreVoiceNotePanel: View {
    @ObservedObject var reader: ScoreReaderController
    @ObservedObject var audio: ScoreVoiceAudio
    let note: ScoreVoiceNote
    @State private var title = ""
    @State private var seeking = false
    @State private var seekPosition = 0.0

    private var total: TimeInterval { audio.duration > 0 && !audio.recording ? audio.duration : note.duration }
    private var saved: Bool { reader.voiceNotes.contains { $0.id == note.id } }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "speaker.wave.2.fill").foregroundStyle(Color(uiColor: note.color.uiColor))
                Text(note.title.isEmpty ? "score.voice".localized : note.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 0)
                Button { reader.voiceEditorExpanded.toggle() } label: {
                    Image(systemName: "ellipsis").frame(width: 44, height: 44)
                }.accessibilityLabel("score.voiceEdit".localized).accessibilityIdentifier("scoreVoiceEdit")
                Button { Task { await audio.stop(); reader.selectedVoiceNote = nil; reader.focusKeys() } } label: {
                    Image(systemName: "xmark").frame(width: 44, height: 44)
                }.accessibilityLabel("Close".localized).accessibilityIdentifier("scoreVoiceClose")
            }
            if audio.preparing { ProgressView("score.voicePreparing".localized) }
            if audio.recording {
                HStack {
                    Circle().fill(.red).frame(width: 10, height: 10)
                    Text(time(audio.position)).monospacedDigit()
                    ProgressView(value: Double(audio.level)).tint(.red)
                    Button("score.voiceFinish".localized, systemImage: "stop.fill") { Task { await audio.stop() } }
                        .frame(minHeight: 44).accessibilityIdentifier("scoreVoiceStop")
                }
            } else if note.duration > 0 {
                HStack(spacing: 8) {
                    Button {
                        Task {
                            if audio.playing { await audio.pause() }
                            else if let url = reader.voiceURL(note) { await audio.play(url) }
                        }
                    } label: {
                        Image(systemName: audio.playing ? "pause.fill" : "play.fill").frame(width: 44, height: 44)
                    }
                    .disabled(audio.preparing)
                    .accessibilityLabel((audio.playing ? "score.voicePause" : "score.voicePlay").localized)
                    .accessibilityIdentifier("scoreVoicePlay")
                    Slider(value: Binding(get: { seeking ? seekPosition : min(total, audio.position) }, set: { seekPosition = $0 }),
                           in: 0...max(0.01, total)) { editing in
                        seeking = editing
                        if !editing { audio.seek(seekPosition) }
                    }
                    .accessibilityLabel("score.voiceProgress".localized).accessibilityIdentifier("scoreVoiceProgress")
                    Text(time(seeking ? seekPosition : audio.position) + " / " + time(total))
                        .font(.caption.monospacedDigit())
                }
            }
            if reader.voiceEditorExpanded || !saved {
                HStack {
                    TextField("score.voiceTitle".localized, text: $title).textFieldStyle(.roundedBorder)
                        .onSubmit { rename() }.accessibilityIdentifier("scoreVoiceTitle")
                    Button("Save".localized) { rename() }.frame(minHeight: 44)
                        .accessibilityIdentifier("scoreVoiceSaveTitle")
                }.disabled(audio.isBusy)
                HStack(spacing: 0) {
                    ForEach(reader.inkColorPresets.indices, id: \.self) { index in
                        let color = reader.inkColorPresets[index]
                        Button {
                            var updated = note; updated.color = color
                            reader.voiceColor = color
                            if saved { reader.saveVoiceNote(updated) }
                            reader.selectedVoiceNote = updated
                        } label: { ScoreInkSwatch(color: color, selected: note.color == color) }
                        .accessibilityLabel(ScoreInkPalette.label(for: color))
                        .accessibilityIdentifier("scoreVoiceColor-\(index)")
                    }
                }.disabled(audio.isBusy)
                HStack {
                    Button(note.duration > 0 ? "score.voiceRecordAgain".localized : "score.voiceRecord".localized, systemImage: "mic.fill") {
                        Task {
                            var take = note; take.audioID = UUID(); take.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
                            do {
                                let url = try await reader.newVoiceURL(take)
                                await audio.record(to: url) { duration in
                                    take.duration = duration
                                    reader.saveVoiceNote(take); reader.selectedVoiceNote = take
                                    reader.voiceEditorExpanded = false
                                }
                            } catch { audio.error = error.localizedDescription }
                        }
                    }.frame(minHeight: 44).accessibilityIdentifier("scoreVoiceRecord")
                    Spacer()
                    if saved {
                        Menu {
                            Button("score.voiceMove".localized, systemImage: "arrow.up.and.down.and.arrow.left.and.right") { reader.beginMovingVoice(note.id) }
                            if let url = reader.voiceURL(note) {
                                ShareLink(item: url) { Label("score.voiceExportAudio".localized, systemImage: "square.and.arrow.up") }
                            }
                            Button("Delete".localized, systemImage: "trash", role: .destructive) { reader.deleteVoiceNote(note.id) }
                                .accessibilityIdentifier("scoreVoiceDelete")
                        } label: { Image(systemName: "slider.horizontal.3").frame(width: 44, height: 44) }
                        .accessibilityLabel("score.voiceActions".localized).accessibilityIdentifier("scoreVoiceActions")
                    }
                }.disabled(audio.isBusy)
            }
            if let error = audio.error { Text(error).font(.caption).foregroundStyle(.red).accessibilityIdentifier("scoreVoiceError") }
            Text(audio.isBusy ? "score.voicePausedHint".localized : "score.voiceLocalHint".localized)
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.bottom, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.quaternary))
        .onAppear { title = note.title; audio.prepare(duration: note.duration) }
    }
    private func rename() {
        var updated = note; updated.title = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        if saved { reader.saveVoiceNote(updated) }
        reader.selectedVoiceNote = updated
    }
    private func time(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds.isFinite ? seconds : 0))
        return String(format: "%d:%02d", value/60, value%60)
    }
}
