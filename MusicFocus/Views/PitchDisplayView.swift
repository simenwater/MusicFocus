import SwiftUI
import CoreText

/// Optional pitch display on the practice page: note (name, jianpu or staff),
/// a ±50 cent needle and the last five seconds of pitch.
struct PitchCard: View {
    @ObservedObject var settings: PitchSettings = .shared
    @ObservedObject var monitor: PitchMonitor = .shared
    var tint: Color
    var isPracticing: Bool
    @State private var showingSettings = false

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "tuningfork")
                    .font(.title3)
                Text("音准显示".localized)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.body)
                }
                .accessibilityLabel("音准设置".localized)
                .accessibilityIdentifier("pitchSettings")
                Toggle("音准显示".localized, isOn: $settings.isEnabled)
                    .labelsHidden()
                    .tint(tint)
                    .accessibilityIdentifier("pitchToggle")
            }
            if settings.isEnabled {
                if !isPracticing {
                    Text("开始练琴后显示音准。适合二胡、提琴、长笛、声乐等单音；不适用于和弦或多人合奏。".localized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let error = monitor.errorMessage {
                    Text(error).font(.caption).foregroundColor(.red)
                } else {
                    PitchReadout(settings: settings, monitor: monitor, tint: tint)
                }
            }
        }
        .foregroundColor(tint)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(tint.opacity(0.08))
        .cornerRadius(12)
        .onChange(of: settings.isEnabled) { _, enabled in
            PracticePitchFeed.shared.isEnabled = enabled
            monitor.reset()
        }
        .sheet(isPresented: $showingSettings) {
            PitchSettingsSheet(settings: settings, tint: tint)
                .presentationDetents([.medium, .large])
        }
    }
}

private struct PitchReadout: View {
    @ObservedObject var settings: PitchSettings
    @ObservedObject var monitor: PitchMonitor
    var tint: Color

    private var staffClef: Clef {
        switch settings.clef {
        case .automatic: return monitor.automaticClef
        case .treble: return .treble
        case .bass: return .bass
        case .alto: return .alto
        }
    }

    private var footerLabel: String {
        switch settings.notation {
        case .jianpu: return "1=\(settings.key.label)"
        case .staff: return settings.clef.title.localized
        case .name: return ""
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            Group {
                if let reading = monitor.reading {
                    switch settings.notation {
                    case .name:
                        Text(SpelledNote(midi: reading.midi, key: settings.key).name)
                            .font(.system(size: 48, weight: .semibold, design: .rounded))
                    case .jianpu:
                        JianpuView(note: JianpuNote(midi: reading.midi, key: settings.key), tint: tint)
                    case .staff:
                        StaffNoteView(note: SpelledNote(midi: reading.midi, key: settings.key),
                                      clef: staffClef, tint: tint)
                    }
                } else {
                    VStack(spacing: 4) {
                        Text("—").font(.system(size: 48, weight: .light))
                        Text("等待单音…".localized).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(height: 110)
            .accessibilityIdentifier("pitchNote")

            CentsNeedle(cents: monitor.reading?.cents, tint: tint)

            PitchCurve(history: monitor.history, center: monitor.reading.map { Double($0.midi) }, tint: tint)
                .frame(height: 70)

            HStack {
                Text(footerLabel)
                Spacer()
                Text("A4 = \(Int(settings.referenceA)) Hz")
                if let reading = monitor.reading {
                    Text(String(format: "· %.1f Hz", reading.frequency))
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
    }
}

/// Green within ±10 cents, yellow within ±25, red beyond.
private struct CentsNeedle: View {
    let cents: Double?
    var tint: Color

    private var color: Color {
        guard let cents else { return .secondary }
        return abs(cents) <= 10 ? .green : (abs(cents) <= 25 ? .orange : .red)
    }

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15)).frame(height: 8)
                    Capsule().fill(Color.green.opacity(0.35))
                        .frame(width: width * 0.2, height: 8)
                        .offset(x: width * 0.4)
                    Rectangle().fill(Color.secondary.opacity(0.6)).frame(width: 1, height: 18).offset(x: width / 2)
                    if let cents {
                        let x = width * CGFloat((max(-50, min(50, cents)) + 50) / 100)
                        Capsule().fill(color).frame(width: 6, height: 26).offset(x: x - 3)
                            .animation(.easeOut(duration: 0.1), value: cents)
                    }
                }
                .frame(height: 26)
            }
            .frame(height: 26)
            HStack {
                Text("偏低".localized)
                Spacer()
                Text(cents.map { "%@ 音分".localizedFormat(String(format: "%+.0f", $0)) } ?? " ")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(color)
                    .monospacedDigit()
                Spacer()
                Text("偏高".localized)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Last five seconds; the grid is one line per semitone around the current note.
private struct PitchCurve: View {
    let history: [(time: Double, pitch: Double?)]
    let center: Double?
    var tint: Color

    var body: some View {
        Canvas { context, size in
            guard let newest = history.last?.time else { return }
            let middle = center ?? history.reversed().compactMap(\.pitch).first ?? 69
            let span = 2.5
            func y(_ pitch: Double) -> CGFloat { size.height / 2 - CGFloat((pitch - middle) / span) * size.height / 2 }
            func x(_ time: Double) -> CGFloat { size.width * CGFloat(1 - (newest - time) / PitchMonitor.historySeconds) }
            for offset in -2...2 {
                var line = Path()
                let level = y(middle.rounded() + Double(offset))
                line.move(to: CGPoint(x: 0, y: level))
                line.addLine(to: CGPoint(x: size.width, y: level))
                context.stroke(line, with: .color(Color.secondary.opacity(offset == 0 ? 0.45 : 0.15)), lineWidth: offset == 0 ? 1 : 0.5)
            }
            // Unvoiced frames, gaps and notes off the grid break the line.
            var path = Path()
            var previous: Double?
            for point in history {
                guard let pitch = point.pitch, abs(pitch - middle) < span + 0.5 else { previous = nil; continue }
                let target = CGPoint(x: x(point.time), y: y(pitch))
                if let last = previous, point.time - last < 0.1 { path.addLine(to: target) } else { path.move(to: target) }
                previous = point.time
            }
            context.stroke(path, with: .color(tint), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}

private struct JianpuView: View {
    let note: JianpuNote
    var tint: Color

    var body: some View {
        VStack(spacing: 4) {
            dots(max(0, note.octaveDots))
            Text(note.degree)
                .font(.system(size: 52, weight: .semibold, design: .rounded))
            dots(max(0, -note.octaveDots))
        }
    }

    private func dots(_ count: Int) -> some View {
        HStack(spacing: 4) {
            ForEach(0..<count, id: \.self) { _ in Circle().frame(width: 7, height: 7) }
        }
        .frame(height: 8)
    }
}

/// One note on a five-line staff, drawn with the Bravura (SMuFL) font. In SMuFL
/// the em is four staff spaces and each glyph's baseline is its reference line
/// (treble clef on G, bass clef on F, alto clef and noteheads on their centre),
/// so glyphs are placed by baseline, not by their bounding boxes.
private struct StaffNoteView: View {
    let note: SpelledNote
    let clef: Clef
    var tint: Color

    var body: some View {
        Canvas { context, size in
            let gap: CGFloat = 11
            let bottom = size.height / 2 + gap * 2
            let left: CGFloat = 16, right = size.width - 16
            let lineColor = Color.secondary.opacity(0.75)
            for line in 0..<5 {
                var path = Path()
                let y = bottom - CGFloat(line) * gap
                path.move(to: CGPoint(x: left, y: y))
                path.addLine(to: CGPoint(x: right, y: y))
                context.stroke(path, with: .color(lineColor), lineWidth: 1)
            }
            let (clefGlyph, clefLine): (String, CGFloat) = {
                switch clef {
                case .treble: return ("\u{E050}", 1)   // G line
                case .bass: return ("\u{E062}", 3)     // F line
                case .alto: return ("\u{E05C}", 2)     // middle line
                }
            }()
            SMuFL.draw(clefGlyph, in: context, gap: gap, x: left + 6, baseline: bottom - clefLine * gap, color: .primary)

            let step = note.staffStep(clef: clef)
            let x = size.width / 2 + 16
            let y = bottom - CGFloat(step) * gap / 2
            // Whole note: pitch only, no rhythm (as in ear-training and theory texts).
            let headWidth = gap * 1.69
            var ledgers: [Int] = []
            if step <= -2 { ledgers = Array(stride(from: -2, through: step, by: -2)) }
            if step >= 10 { ledgers = Array(stride(from: 10, through: step, by: 2)) }
            for ledger in ledgers {
                var path = Path()
                let ly = bottom - CGFloat(ledger) * gap / 2
                path.move(to: CGPoint(x: x - headWidth * 0.75, y: ly))
                path.addLine(to: CGPoint(x: x + headWidth * 0.75, y: ly))
                context.stroke(path, with: .color(lineColor), lineWidth: 1.2)
            }
            SMuFL.draw("\u{E0A2}", in: context, gap: gap, x: x - headWidth / 2, baseline: y, color: tint)
            if note.accidental != 0 {
                SMuFL.draw(note.accidental > 0 ? "\u{E262}" : "\u{E260}", in: context, gap: gap,
                           x: x - headWidth / 2 - gap * 1.3, baseline: y, color: tint)
            }
        }
        .frame(maxWidth: 260)
        .accessibilityLabel(note.name)
    }
}

/// Bundled Bravura, registered once for this process.
enum SMuFL {
    static let fontName: String? = {
        guard let url = Bundle.main.url(forResource: "Bravura", withExtension: "otf"),
              let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              let descriptor = descriptors.first else { return nil }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        return CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String
    }()

    /// Draws `glyph` with its baseline at `baseline` (font size = 4 staff spaces).
    static func draw(_ glyph: String, in context: GraphicsContext, gap: CGFloat, x: CGFloat,
                     baseline: CGFloat, color: Color) {
        guard let name = fontName else { return }
        let font = CTFontCreateWithName(name as CFString, gap * 4, nil)
        let resolved = UIColor(color).cgColor
        let attributed = NSAttributedString(string: glyph, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): resolved
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        context.withCGContext { cg in
            cg.saveGState()
            // Canvas is y-down; flip text so it is upright with its baseline at `baseline`.
            cg.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            cg.textPosition = CGPoint(x: x, y: baseline)
            CTLineDraw(line, cg)
            cg.restoreGState()
        }
    }
}

struct PitchSettingsSheet: View {
    @ObservedObject var settings: PitchSettings
    var tint: Color
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("显示方式".localized) {
                    Picker("显示方式".localized, selection: $settings.notation) {
                        Text("音名".localized).tag(PitchNotation.name)
                        Text("简谱".localized).tag(PitchNotation.jianpu)
                        Text("五线谱".localized).tag(PitchNotation.staff)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("pitchNotationPicker")
                }
                Section {
                    Picker("谱号".localized, selection: $settings.clef) {
                        ForEach(PitchClef.allCases) { Text($0.title.localized).tag($0) }
                    }
                    Picker("调".localized, selection: $settings.key) {
                        ForEach(MusicKey.allCases) { Text("1=\($0.label)").tag($0) }
                    }
                } footer: {
                    Text("谱号选自动时，低到 A3 换成低音谱号，高到 E4 换回高音谱号。调决定简谱的 1 和升降号写法。显示的是实际发出的音，不做移调。".localized)
                }
                Section {
                    HStack(spacing: 8) {
                        ForEach(PitchSettings.referencePresets, id: \.self) { value in
                            let selected = settings.referenceA == value
                            Button {
                                settings.referenceA = value
                            } label: {
                                Text("\(Int(value))")
                                    .frame(maxWidth: .infinity, minHeight: 34)
                                    .background(selected ? tint : tint.opacity(0.1))
                                    .foregroundColor(selected ? .white : tint)
                                    .cornerRadius(8)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Stepper(value: $settings.referenceA, in: PitchSettings.referenceRange, step: 1) {
                        Text("A4 = \(Int(settings.referenceA)) Hz").monospacedDigit()
                    }
                } header: {
                    Text("标准音".localized)
                } footer: {
                    Text("只影响偏高偏低的计算，不影响练琴计时。".localized)
                }
            }
            .navigationTitle("音准设置".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成".localized) { dismiss() }
                }
            }
        }
    }
}
