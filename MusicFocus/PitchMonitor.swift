import Foundation
import Combine

// MARK: - Settings

enum PitchNotation: String, CaseIterable, Identifiable {
    case name, jianpu, staff
    var id: String { rawValue }
}

enum Clef { case treble, alto, bass }

/// Staff clef. Automatic switches between treble and bass like a grand staff.
/// Pitches are shown as sounded (no transposition).
enum PitchClef: String, CaseIterable, Identifiable {
    case automatic, treble, bass, alto
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: return "自动（高低音切换）"
        case .treble: return "高音谱号"
        case .bass: return "低音谱号"
        case .alto: return "中音谱号（中提琴）"
        }
    }

    /// Automatic: below A3 (two ledger lines) moves to bass, from E4 back to
    /// treble; notes in between keep the current clef so it does not flicker.
    static func automaticClef(current: Clef, midi: Int) -> Clef {
        if current != .bass && midi <= 57 { return .bass }
        if current == .bass && midi >= 64 { return .treble }
        return current == .alto ? .treble : current
    }
}

/// Key for jianpu (1 = tonic) and for spelling sharps or flats.
enum MusicKey: String, CaseIterable, Identifiable {
    case C, G, D, A, E, F, Bb, Eb
    var id: String { rawValue }
    var tonic: Int { ["C": 0, "G": 7, "D": 2, "A": 9, "E": 4, "F": 5, "Bb": 10, "Eb": 3][rawValue]! }
    var usesFlats: Bool { self == .F || self == .Bb || self == .Eb }
    var label: String { rawValue.replacingOccurrences(of: "b", with: "♭") }
}

final class PitchSettings: ObservableObject {
    static let shared = PitchSettings()
    static let referencePresets: [Double] = [440, 442, 443]
    static let referenceRange: ClosedRange<Double> = 435...446

    @Published var isEnabled: Bool { didSet { defaults.set(isEnabled, forKey: "pitchDisplayEnabled") } }
    @Published var notation: PitchNotation { didSet { defaults.set(notation.rawValue, forKey: "pitchNotation") } }
    @Published var clef: PitchClef { didSet { defaults.set(clef.rawValue, forKey: "pitchClef") } }
    @Published var key: MusicKey { didSet { defaults.set(key.rawValue, forKey: "pitchKey") } }
    @Published var referenceA: Double {
        didSet {
            let clamped = min(Self.referenceRange.upperBound, max(Self.referenceRange.lowerBound, referenceA.rounded()))
            if clamped != referenceA { referenceA = clamped; return }
            defaults.set(referenceA, forKey: "pitchReferenceA")
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: "pitchDisplayEnabled")
        notation = defaults.string(forKey: "pitchNotation").flatMap(PitchNotation.init(rawValue:)) ?? .name
        clef = defaults.string(forKey: "pitchClef").flatMap(PitchClef.init(rawValue:)) ?? .automatic
        key = defaults.string(forKey: "pitchKey").flatMap(MusicKey.init(rawValue:)) ?? .C
        let saved = defaults.double(forKey: "pitchReferenceA")
        referenceA = Self.referenceRange.contains(saved) ? saved.rounded() : 440
    }
}

// MARK: - Notation (pure)

struct SpelledNote: Equatable {
    /// 0 = C ... 6 = B
    let letter: Int
    /// -1 flat, 0 natural, +1 sharp
    let accidental: Int
    let octave: Int

    static let letters = ["C", "D", "E", "F", "G", "A", "B"]

    /// Black keys as sharps, or as flats in flat keys.
    init(midi: Int, key: MusicKey) {
        let pitchClass = ((midi % 12) + 12) % 12
        let naturals = [0: 0, 2: 1, 4: 2, 5: 3, 7: 4, 9: 5, 11: 6]
        if let letter = naturals[pitchClass] {
            self.letter = letter; accidental = 0
        } else if key.usesFlats {
            letter = naturals[pitchClass + 1]!; accidental = -1
        } else {
            letter = naturals[pitchClass - 1]!; accidental = 1
        }
        octave = Int((Double(midi) / 12).rounded(.down)) - 1
    }

    var name: String {
        Self.letters[letter] + (accidental > 0 ? "♯" : accidental < 0 ? "♭" : "") + "\(octave)"
    }

    /// Staff steps above the bottom line of the clef (each step = line or space).
    func staffStep(clef: Clef) -> Int {
        let bottom: Int
        switch clef {
        case .treble: bottom = 4 * 7 + 2   // E4
        case .alto: bottom = 3 * 7 + 3     // F3
        case .bass: bottom = 2 * 7 + 4     // G2
        }
        return octave * 7 + letter - bottom
    }
}

/// Jianpu degree relative to the key's tonic in octave 4 (1=D: D4 is "1").
struct JianpuNote: Equatable {
    let degree: String
    /// Dots above (positive) or below (negative).
    let octaveDots: Int

    init(midi: Int, key: MusicKey) {
        let tonic = 60 + key.tonic
        let interval = midi - tonic
        let octaves = Int((Double(interval) / 12).rounded(.down))
        let step = interval - octaves * 12
        degree = ["1", "♯1", "2", "♭3", "3", "4", "♯4", "5", "♯5", "6", "♭7", "7"][step]
        octaveDots = octaves
    }
}

// MARK: - Live reading

struct PitchReading: Equatable {
    /// Nearest equal-tempered note (MIDI) at the chosen reference.
    let midi: Int
    /// Deviation from that note, -50...+50.
    let cents: Double
    let frequency: Double
}

/// Turns raw frame estimates into a calm display: a note changes only after it
/// has held for 150 ms (300 ms for a jump of exactly one octave, CREPE's typical
/// slip at note onsets); history keeps 5 s for the pitch curve. Main thread only.
final class PitchMonitor: ObservableObject {
    static let shared = PitchMonitor()
    static let historySeconds = 5.0

    @Published private(set) var reading: PitchReading?
    @Published private(set) var history: [(time: Double, pitch: Double?)] = []
    @Published private(set) var errorMessage: String?
    /// Clef used when the setting is automatic; follows the shown note.
    @Published private(set) var automaticClef: Clef = .treble

    private var recent: [Double] = []
    private var candidate: (midi: Int, since: Double)?
    private var lastVoiced = -Double.infinity
    private let settings: PitchSettings

    init(settings: PitchSettings = .shared) {
        self.settings = settings
    }

    func reset() {
        reading = nil
        automaticClef = .treble
        history = []
        recent = []
        candidate = nil
        lastVoiced = -.infinity
    }

    func fail(_ message: String) { errorMessage = message }

    func consume(_ estimates: [PitchEstimate]) {
        guard !estimates.isEmpty else { return }
        if let first = estimates.first, let last = history.last, first.time < last.time { reset() }
        for estimate in estimates {
            let pitch = estimate.isVoiced ? 69 + 12 * log2(estimate.frequency / settings.referenceA) : nil
            history.append((estimate.time, pitch))
            update(time: estimate.time, pitch: pitch)
        }
        if let newest = history.last?.time, let cut = history.firstIndex(where: { $0.time >= newest - Self.historySeconds }), cut > 0 {
            history.removeFirst(cut)
        }
    }

    private func update(time: Double, pitch: Double?) {
        guard let pitch else {
            recent.removeAll()
            if time - lastVoiced > 0.5 { reading = nil; candidate = nil }
            return
        }
        lastVoiced = time
        recent.append(pitch)
        if recent.count > 5 { recent.removeFirst() }
        let median = recent.sorted()[recent.count / 2]
        let nearest = Int(median.rounded())
        if candidate?.midi != nearest { candidate = (nearest, time) }
        guard let candidate else { return }
        if let shown = reading?.midi, shown != candidate.midi {
            let hold = abs(candidate.midi - shown) == 12 ? 0.3 : 0.15
            guard time - candidate.since >= hold else { return }
        }
        // The frequency label must describe the same smoothed pitch as the
        // note and cents, rather than the latest potentially noisy raw frame.
        let frequency = settings.referenceA * pow(2, (median - 69) / 12)
        reading = PitchReading(midi: candidate.midi, cents: (median - Double(candidate.midi)) * 100, frequency: frequency)
        let clef = PitchClef.automaticClef(current: automaticClef, midi: candidate.midi)
        if clef != automaticClef { automaticClef = clef }
    }
}

// MARK: - Audio feed

/// Receives the microphone signal (metronome already removed) from detection
/// and estimates pitch on its own queue, only while the display is on. Never
/// blocks or alters practice detection; frames are dropped if it falls behind.
final class PracticePitchFeed {
    static let shared = PracticePitchFeed()

    private let queue = DispatchQueue(label: "MusicFocus.pitch", qos: .userInitiated)
    private let lock = NSLock()
    private var enabled = false
    private var backlog = 0
    // Used only on `queue`.
    private var estimator: PracticePitchEstimator?
    private var tracker: PracticePitchTracker?
    private var modelFailed = false

    var isEnabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return enabled }
        set { lock.lock(); enabled = newValue; lock.unlock() }
    }

    func submit(_ samples: UnsafeBufferPointer<Float>, startFrame: Int64, sampleRate: Double) {
        lock.lock()
        guard enabled, backlog < 6 else { lock.unlock(); return }
        backlog += 1
        lock.unlock()
        let copy = Array(samples)
        queue.async { [self] in
            defer { lock.lock(); backlog -= 1; lock.unlock() }
            guard !modelFailed else { return }
            do {
                if estimator == nil { estimator = try PracticePitchEstimator() }
                if tracker?.sampleRate != sampleRate {
                    tracker = try PracticePitchTracker(sampleRate: sampleRate, estimator: estimator)
                }
                let estimates = try copy.withUnsafeBufferPointer { try tracker!.append($0, startFrame: startFrame) }
                guard !estimates.isEmpty else { return }
                DispatchQueue.main.async { PitchMonitor.shared.consume(estimates) }
            } catch {
                modelFailed = true
                DispatchQueue.main.async { PitchMonitor.shared.fail(error.localizedDescription) }
            }
        }
    }
}
