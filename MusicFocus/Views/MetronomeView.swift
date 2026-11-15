import SwiftUI

/// Compact metronome row on the practice page; tap it for the full controls.
struct MetronomeBar: View {
    @ObservedObject var metronome: Metronome = .shared
    var tint: Color
    @State private var showingPanel = false

    var body: some View {
        HStack(spacing: 12) {
            Button {
                showingPanel = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "metronome")
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("节拍器".localized)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        Text("\(metronome.tempo) BPM · \(metronome.timeSignature.detailedLabel)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Spacer(minLength: 4)
                    BeatDots(metronome: metronome, tint: tint, size: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("metronomeOpenPanel")

            Button {
                metronome.toggle()
            } label: {
                Image(systemName: metronome.isRunning ? "stop.fill" : "play.fill")
                    .font(.body.weight(.semibold))
                    .foregroundColor(.white)
                    .frame(width: 40, height: 40)
                    .background(metronome.isRunning ? Color.red : tint)
                    .clipShape(Circle())
            }
            .accessibilityLabel(metronome.isRunning ? "停止节拍器".localized : "开始节拍器".localized)
            .accessibilityIdentifier("metronomeToggle")
        }
        .foregroundColor(tint)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(tint.opacity(0.08))
        .cornerRadius(12)
        .sheet(isPresented: $showingPanel) {
            MetronomePanel(metronome: metronome, tint: tint)
                .presentationDetents([.medium, .large])
        }
    }
}

struct MetronomePanel: View {
    @ObservedObject var metronome: Metronome
    var tint: Color
    @Environment(\.dismiss) private var dismiss
    // Dragging restarts the click loop on every value; apply on release.
    @State private var draggedTempo: Double?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    BeatDots(metronome: metronome, tint: tint, size: 14)

                    HStack(spacing: 18) {
                        tempoStep("minus", delta: -1, label: "减慢".localized)
                        VStack(spacing: 0) {
                            Text("\(draggedTempo.map { Int($0.rounded()) } ?? metronome.tempo)")
                                .font(.system(size: 56, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundColor(tint)
                                .accessibilityIdentifier("metronomeTempoValue")
                            Text("BPM")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if metronome.timeSignature.unit == 8 {
                                let tempo = draggedTempo.map { Int($0.rounded()) } ?? metronome.tempo
                                Text("metronome.eighthBeatHint".localizedFormat(Int((Double(tempo) / 3).rounded())))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 2)
                            }
                        }
                        .frame(minWidth: 130)
                        tempoStep("plus", delta: 1, label: "加快".localized)
                    }

                    Slider(value: Binding(
                        get: { draggedTempo ?? Double(metronome.tempo) },
                        set: { draggedTempo = $0 }),
                           in: Double(Metronome.tempoRange.lowerBound)...Double(Metronome.tempoRange.upperBound),
                           step: 1) { editing in
                        if !editing, let value = draggedTempo {
                            metronome.tempo = Int(value.rounded())
                            draggedTempo = nil
                        }
                    }
                    .tint(tint)
                    .accessibilityIdentifier("metronomeTempoSlider")

                    HStack(spacing: 12) {
                        Button {
                            metronome.adjustTempo(by: -5)
                        } label: { Text("−5").frame(maxWidth: .infinity, minHeight: 32) }
                            .accessibilityIdentifier("metronomeTempoMinus5")
                        Button {
                            metronome.tap()
                        } label: {
                            Text("点击测速".localized)
                                .lineLimit(1).minimumScaleFactor(0.75)
                                .frame(maxWidth: .infinity, minHeight: 32)
                        }
                            .accessibilityIdentifier("metronomeTapTempo")
                        Button {
                            metronome.adjustTempo(by: 5)
                        } label: { Text("+5").frame(maxWidth: .infinity, minHeight: 32) }
                            .accessibilityIdentifier("metronomeTempoPlus5")
                    }
                    .buttonStyle(.bordered)
                    .tint(tint)

                    subdivisionPicker

                    VStack(alignment: .leading, spacing: 8) {
                        Text("音色".localized)
                            .font(.subheadline).foregroundStyle(.secondary)
                        Picker("音色".localized, selection: $metronome.sound) {
                            Text("机械嗒嗒".localized).tag(MetronomeSound.click)
                            Text("电子提示音".localized).tag(MetronomeSound.electronic)
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("metronomeSoundPicker")
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("拍号".localized)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                            ForEach(TimeSignature.options) { signature in
                                let selected = signature.sameMeter(as: metronome.timeSignature)
                                Button {
                                    if !selected { metronome.timeSignature = signature }
                                } label: {
                                    Text(signature.label)
                                        .font(.body.weight(selected ? .semibold : .regular))
                                        .monospacedDigit()
                                        .frame(maxWidth: .infinity, minHeight: 40)
                                        .background(selected ? tint : tint.opacity(0.1))
                                        .foregroundColor(selected ? .white : tint)
                                        .cornerRadius(10)
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(selected ? .isSelected : [])
                                .accessibilityIdentifier("timeSignature-\(signature.meter)")
                            }
                        }
                        if metronome.timeSignature.hasGroupingChoice {
                            HStack(spacing: 8) {
                                Text("分组".localized)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                ForEach(TimeSignature.groupings(beats: metronome.timeSignature.beats), id: \.self) { groups in
                                    let option = metronome.timeSignature.regrouped(groups)
                                    let selected = option == metronome.timeSignature
                                    Button {
                                        metronome.timeSignature = option
                                    } label: {
                                        Text(option.groupingLabel)
                                            .font(.subheadline.weight(selected ? .semibold : .regular))
                                            .monospacedDigit()
                                            .frame(maxWidth: .infinity, minHeight: 34)
                                            .background(selected ? tint : tint.opacity(0.1))
                                            .foregroundColor(selected ? .white : tint)
                                            .cornerRadius(8)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityAddTraits(selected ? .isSelected : [])
                                    .accessibilityIdentifier("grouping-\(option.groupingLabel)")
                                }
                            }
                        }
                        Text("重音按拍号自动设置：大圆点为强拍，中圆点为次强拍。".localized)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("音量".localized)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        HStack {
                            Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                            Slider(value: $metronome.volume, in: 0.1...1).tint(tint)
                                .accessibilityLabel("音量".localized)
                                .accessibilityValue(metronome.volume.formatted(.percent.precision(.fractionLength(0))))
                                .accessibilityIdentifier("metronomeVolumeSlider")
                            Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                        }
                        Text("节拍器音量也受设备音量控制，可用音量键调整。".localized)
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Text("节拍器的声音会被自动过滤，不计入练琴时间。打开或调速后约一小节内在学习声音，这段不计时。".localized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding()
            }
            .accessibilityIdentifier("metronomePanelScroll")
            .safeAreaInset(edge: .bottom, spacing: 0) {
                playbackControl
            }
            .navigationTitle("节拍器".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成".localized) { dismiss() }
                        .accessibilityIdentifier("metronomeDone")
                }
            }
        }
        .foregroundStyle(Color.primary)
    }

    private var playbackControl: some View {
        Button {
            metronome.toggle()
        } label: {
            Label(metronome.isRunning ? "停止节拍器".localized : "开始节拍器".localized,
                  systemImage: metronome.isRunning ? "stop.fill" : "play.fill")
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(metronome.isRunning ? Color.red : tint)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("metronomePanelToggle")
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
    }

    private var subdivisionPicker: some View {
        HStack(spacing: 8) {
            ForEach(MetronomeSubdivision.allCases) { option in
                let selected = metronome.subdivision == option
                Button {
                    metronome.subdivision = option
                } label: {
                    SubdivisionNotation(subdivision: option, unit: metronome.timeSignature.unit,
                                        color: selected ? .white : tint)
                        .frame(width: 54, height: 42)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(selected ? tint : tint.opacity(0.08))
                        .foregroundStyle(selected ? .white : tint)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(option.label(unit: metronome.timeSignature.unit))
                .accessibilityValue("metronome.subdivision.count".localizedFormat(option.rawValue))
                .accessibilityAddTraits(.isButton)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("metronomeSubdivision-\(option.rawValue)")
            }
        }
    }

    private func tempoStep(_ symbol: String, delta: Int, label: String) -> some View {
        Button {
            metronome.adjustTempo(by: delta)
        } label: {
            Image(systemName: symbol)
                .font(.title2.weight(.semibold))
                .frame(width: 52, height: 52)
                .background(tint.opacity(0.12))
                .foregroundColor(tint)
                .clipShape(Circle())
        }
        .buttonRepeatBehavior(.enabled)
        .accessibilityLabel(label)
    }
}

extension MetronomeSubdivision {
    func label(unit: Int) -> String {
        switch self {
        case .beat: return "metronome.subdivision.beat".localized
        case .duplet: return (unit == 8 ? "metronome.subdivision.twoSixteenths" : "metronome.subdivision.eighths").localized
        case .triplet: return "metronome.subdivision.triplets".localized
        case .quadruplet: return (unit == 8 ? "metronome.subdivision.thirtySeconds" : "metronome.subdivision.sixteenths").localized
        }
    }
}

/// Vector notation stays crisp without relying on a music font being installed.
private struct SubdivisionNotation: View {
    let subdivision: MetronomeSubdivision
    let unit: Int
    let color: Color

    var body: some View {
        Canvas { context, size in
            let count = subdivision.rawValue
            let top: CGFloat = subdivision == .triplet ? 16 : 10
            let headY = size.height - 6
            let span: CGFloat = count == 1 ? 0 : (count == 2 ? 24 : 42)
            let first = (size.width - span) / 2
            let beamCount = (count == 1 ? 0 : (count == 4 ? 2 : 1)) + (unit == 8 ? 1 : 0)
            for index in 0..<count {
                let x = first + (count == 1 ? 0 : span * CGFloat(index) / CGFloat(count - 1))
                let head = Path(ellipseIn: CGRect(x: x - 4.5, y: headY - 3, width: 9, height: 6))
                context.fill(head, with: .color(color))
                var stem = Path()
                stem.move(to: CGPoint(x: x + 4, y: headY))
                stem.addLine(to: CGPoint(x: x + 4, y: top))
                context.stroke(stem, with: .color(color), lineWidth: 1.6)
            }
            if count > 1 {
                for beam in 0..<beamCount {
                    context.fill(Path(CGRect(x: first + 3.2, y: top + CGFloat(beam) * 5,
                                             width: span + 1.6, height: 3)), with: .color(color))
                }
            } else if beamCount > 0 {
                var flag = Path()
                flag.move(to: CGPoint(x: first + 4, y: top))
                flag.addCurve(to: CGPoint(x: first + 9, y: top + 15),
                              control1: CGPoint(x: first + 16, y: top + 6),
                              control2: CGPoint(x: first + 14, y: top + 10))
                context.stroke(flag, with: .color(color), lineWidth: 2)
            }
            if subdivision == .triplet {
                context.draw(Text("3").font(.system(size: 11, weight: .bold)).foregroundColor(color),
                             at: CGPoint(x: size.width / 2, y: 6))
            }
        }
        .accessibilityHidden(true)
    }
}

extension TimeSignature {
    var label: String { beats == 1 ? "无重音".localized : meter }
    /// "7/8 · 2+2+3" where the grouping is a choice.
    var detailedLabel: String { hasGroupingChoice ? "\(label) · \(groupingLabel)" : label }
}

/// One dot per beat; the current beat lights up. Strong beats are largest,
/// medium beats (4/4 beat 3, start of each group in 6/8) are in between.
struct BeatDots: View {
    @ObservedObject var metronome: Metronome
    var tint: Color
    var size: CGFloat

    var body: some View {
        let accents = metronome.timeSignature.accents
        // Keep 12/8 within the compact row.
        let dot = accents.count > 6 ? size * 0.75 : size
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !metronome.isRunning)) { context in
            let position = metronome.isRunning ? metronome.beatPosition() : nil
            HStack(spacing: dot * 0.6) {
                ForEach(Array(accents.enumerated()), id: \.offset) { beat, accent in
                    let lit = position?.beat == beat && (position?.phase ?? 1) < 0.35
                    let scale: CGFloat = accent == .strong ? 1.3 : (accent == .medium ? 1.1 : 0.85)
                    Circle()
                        .fill(lit ? tint : tint.opacity(0.2))
                        .frame(width: dot * scale, height: dot * scale)
                }
            }
            .frame(height: dot * 1.3)
            .accessibilityHidden(true)
        }
    }
}
