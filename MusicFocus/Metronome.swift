import AVFoundation
import Combine
import QuartzCore
import UIKit

/// Built-in metronome, so students never leave the app (and stop detection)
/// to open another one. Its clicks are removed from the microphone signal
/// before classification (MetronomeCanceller, fed by MetronomeSchedule), and
/// PracticeDetectionPolicy knows when it is audible (`metronomeActive`).
/// A meter with its conventional accents. Each click is one note of the lower
/// number, so BPM counts eighth notes in x/8. Subdivisions split that base beat.
struct TimeSignature: Hashable, Identifiable {
    enum Accent { case strong, medium, weak }

    let beats: Int
    let unit: Int
    /// Beat groups; the first click of each group is accented. Odd meters
    /// (5, 7) can be grouped several ways, e.g. 7/8 as 2+2+3 or 3+2+2.
    let groups: [Int]

    static let none = TimeSignature(beats: 1, unit: 4)
    static let options: [TimeSignature] = [
        .none, .init(beats: 2, unit: 4), .init(beats: 3, unit: 4), .init(beats: 4, unit: 4),
        .init(beats: 5, unit: 4), .init(beats: 3, unit: 8), .init(beats: 5, unit: 8), .init(beats: 6, unit: 8),
        .init(beats: 7, unit: 8), .init(beats: 9, unit: 8), .init(beats: 12, unit: 8)
    ]

    /// Choosable groupings; the first is the default. Empty: only one way.
    static func groupings(beats: Int) -> [[Int]] {
        switch beats {
        case 5: return [[3, 2], [2, 3]]
        case 7: return [[2, 2, 3], [3, 2, 2], [2, 3, 2]]
        default: return []
        }
    }

    /// Conventional groups: 4/4 as 2+2 (beat 3 medium), x/8 compound meters in
    /// threes (6/8: strong weak weak medium weak weak), odd meters as given.
    init(beats: Int, unit: Int, groups: [Int]? = nil) {
        self.beats = beats
        self.unit = unit
        if let groups, groups.reduce(0, +) == beats, groups.allSatisfy({ $0 > 0 }) {
            self.groups = groups
        } else if let first = Self.groupings(beats: beats).first {
            self.groups = first
        } else if unit == 8 && beats > 3 && beats % 3 == 0 {
            self.groups = Array(repeating: 3, count: beats / 3)
        } else if beats == 4 && unit == 4 {
            self.groups = [2, 2]
        } else {
            self.groups = [beats]
        }
    }

    var id: String { storageValue }
    var meter: String { "\(beats)/\(unit)" }
    var hasGroupingChoice: Bool { !Self.groupings(beats: beats).isEmpty }
    var groupingLabel: String { groups.map(String.init).joined(separator: "+") }
    var storageValue: String { hasGroupingChoice ? "\(meter):\(groupingLabel)" : meter }

    /// Same meter with another grouping (for the grouping picker).
    func regrouped(_ groups: [Int]) -> TimeSignature { .init(beats: beats, unit: unit, groups: groups) }
    func sameMeter(as other: TimeSignature) -> Bool { beats == other.beats && unit == other.unit }

    init?(storageValue: String) {
        let halves = storageValue.split(separator: ":")
        let parts = halves.first?.split(separator: "/").compactMap { Int($0) } ?? []
        guard parts.count == 2, halves.count <= 2,
              Self.options.contains(where: { $0.beats == parts[0] && $0.unit == parts[1] }) else { return nil }
        guard halves.count == 2 else { self.init(beats: parts[0], unit: parts[1]); return }
        let groups = halves[1].split(separator: "+").compactMap { Int($0) }
        guard Self.groupings(beats: parts[0]).contains(groups) else { return nil }
        self.init(beats: parts[0], unit: parts[1], groups: groups)
    }

    /// Strong downbeat, medium at the start of every later group, weak elsewhere.
    var accents: [Accent] {
        guard beats > 1 else { return [.weak] }
        var starts = Set<Int>()
        var position = 0
        for group in groups.dropLast() {
            position += group
            starts.insert(position)
        }
        return (0..<beats).map { beat in
            beat == 0 ? .strong : (starts.contains(beat) ? .medium : .weak)
        }
    }
}

enum MetronomeSound: String, CaseIterable, Identifiable {
    case click
    case electronic
    var id: String { rawValue }
}

/// Equal divisions of one BPM beat, independent of the meter's beat unit.
enum MetronomeSubdivision: Int, CaseIterable, Identifiable {
    case beat = 1, duplet = 2, triplet = 3, quadruplet = 4
    var id: Int { rawValue }
}

final class Metronome: ObservableObject {
    static let shared = Metronome()
    static let tempoRange = 30...240
    /// Ticks still reverberate and the classifier window is one second long.
    static let detectionTail: TimeInterval = 1.5

    @Published var tempo: Int {
        didSet {
            let clamped = min(Self.tempoRange.upperBound, max(Self.tempoRange.lowerBound, tempo))
            if clamped != tempo { tempo = clamped; return }
            guard tempo != oldValue else { return }
            defaults.set(tempo, forKey: Keys.tempo)
            rescheduleIfRunning()
        }
    }
    @Published var timeSignature: TimeSignature {
        didSet {
            guard timeSignature != oldValue else { return }
            defaults.set(timeSignature.storageValue, forKey: Keys.timeSignature)
            rescheduleIfRunning()
        }
    }
    @Published var sound: MetronomeSound {
        didSet {
            guard sound != oldValue else { return }
            defaults.set(sound.rawValue, forKey: Keys.sound)
            // A new loop ID also makes the microphone canceller relearn this sound.
            rescheduleIfRunning()
        }
    }
    @Published var subdivision: MetronomeSubdivision {
        didSet {
            guard subdivision != oldValue else { return }
            defaults.set(subdivision.rawValue, forKey: Keys.subdivision)
            rescheduleIfRunning()
        }
    }
    @Published var volume: Double {
        didSet {
            let clamped = min(1, max(0.1, volume))
            if clamped != volume { volume = clamped; return }
            defaults.set(volume, forKey: Keys.volume)
            applyVolume()
        }
    }
    /// Remote control only (live lesson presenter): keeps time and shows the
    /// beat, but the clicks sound on the other device.
    @Published var silenced = false {
        didSet { if silenced != oldValue { applyVolume() } }
    }
    private var outputVolume: Float { silenced ? 0 : Float(volume) }

    @Published private(set) var isRunning = false

    /// Tells detection whether ticks can be in the microphone signal. Turns on
    /// before the first tick and off only after `detectionTail`.
    var onAudibleChanged: ((Bool) -> Void)?
    private(set) var isAudible = false

    private enum Keys {
        static let tempo = "metronomeTempo"
        static let timeSignature = "metronomeTimeSignature"
        /// Earlier builds stored only a count of beats with one accent.
        static let legacyBeats = "metronomeBeatsPerBar"
        static let volume = "metronomeVolume"
        static let sound = "metronomeSound"
        static let subdivision = "metronomeSubdivision"
    }
    private let defaults: UserDefaults
    private let audioQueue = DispatchQueue(label: "MusicFocus.metronome", qos: .userInitiated)
    // Engine objects are used only on audioQueue.
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    /// Built at the session's (= microphone's) rate, so a bar is a whole number
    /// of microphone frames and the canceller can align it sample for sample.
    private var format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private let schedule: MetronomeSchedule
    private var loopID = 0
    private var ownsSession = false
    private var generation = 0
    private var audibleOff: DispatchWorkItem?
    private var tapTimes: [CFTimeInterval] = []
    // Main thread: media time of beat 0 and the beat length, for the UI pulse.
    private var timeline: (start: CFTimeInterval, interval: TimeInterval, beats: Int)?

    init(defaults: UserDefaults = .standard, schedule: MetronomeSchedule = .shared) {
        self.defaults = defaults
        self.schedule = schedule
        let savedTempo = defaults.integer(forKey: Keys.tempo)
        tempo = Self.tempoRange.contains(savedTempo) ? savedTempo : 80
        if let saved = defaults.string(forKey: Keys.timeSignature).flatMap(TimeSignature.init(storageValue:)) {
            timeSignature = saved
        } else {
            switch defaults.integer(forKey: Keys.legacyBeats) {
            case 1: timeSignature = .none
            case 2: timeSignature = .init(beats: 2, unit: 4)
            case 3: timeSignature = .init(beats: 3, unit: 4)
            case 6: timeSignature = .init(beats: 6, unit: 8)
            default: timeSignature = .init(beats: 4, unit: 4)
            }
        }
        sound = defaults.string(forKey: Keys.sound).flatMap(MetronomeSound.init(rawValue:)) ?? .click
        subdivision = MetronomeSubdivision(rawValue: defaults.integer(forKey: Keys.subdivision)) ?? .beat
        let savedVolume = defaults.object(forKey: Keys.volume) as? Double ?? 1.0
        volume = min(1, max(0.1, savedVolume))
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        NotificationCenter.default.addObserver(
            self, selector: #selector(engineConfigurationChanged),
            name: .AVAudioEngineConfigurationChange, object: engine)
        NotificationCenter.default.addObserver(
            self, selector: #selector(sessionInterrupted),
            name: AVAudioSession.interruptionNotification, object: nil)
        // Without an audio background mode the app is suspended mid-click.
        NotificationCenter.default.addObserver(
            self, selector: #selector(enteredBackground),
            name: UIApplication.didEnterBackgroundNotification, object: nil)
    }

    func toggle() { isRunning ? stop() : start() }

    func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !isRunning else { return }
        isRunning = true
        setAudible(true)
        generation += 1
        let token = generation
        PracticeAudioCapture.acquireSharedSession { [weak self] ok in
            guard let self else { return }
            self.audioQueue.async {
                if ok { self.ownsSession = true }
                DispatchQueue.main.async {
                    guard ok, self.isRunning, self.generation == token else {
                        if !ok { self.stop() } else { self.releaseSessionIfNeeded() }
                        return
                    }
                    self.scheduleLoop()
                }
            }
        }
    }

    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard isRunning else { return }
        isRunning = false
        generation += 1
        timeline = nil
        audioQueue.async { [self] in
            player.stop()
            engine.stop()
            schedule.current = nil
        }
        releaseSessionIfNeeded()
        setAudible(false)
    }

    func adjustTempo(by delta: Int) { tempo += delta }

    private func applyVolume() {
        let value = outputVolume
        audioQueue.async { [self] in
            player.volume = value
            // The canceller scales its learned click to the new volume (none when silenced).
            if let current = schedule.current {
                schedule.current = .init(id: current.id, startHostSeconds: current.startHostSeconds,
                                         barSeconds: current.barSeconds, gain: value)
            }
        }
    }

    /// Tap tempo: average of the last few intervals, ignoring long gaps.
    func tap() {
        let now = CACurrentMediaTime()
        if let last = tapTimes.last, now - last > 2 { tapTimes.removeAll() }
        tapTimes.append(now)
        tapTimes = Array(tapTimes.suffix(5))
        guard tapTimes.count >= 2 else { return }
        let intervals = zip(tapTimes.dropFirst(), tapTimes).map { $0 - $1 }
        let average = intervals.reduce(0, +) / Double(intervals.count)
        tempo = Int((60 / average).rounded())
    }

    /// Current beat (0-based) and how far into it we are, for the visual pulse.
    func beatPosition(at time: CFTimeInterval = CACurrentMediaTime()) -> (beat: Int, phase: Double)? {
        guard let timeline, time >= timeline.start else { return nil }
        let elapsed = (time - timeline.start) / timeline.interval
        let beat = Int(elapsed.rounded(.down))
        return (beat % timeline.beats, elapsed - Double(beat))
    }

    // MARK: - Audio

    private func rescheduleIfRunning() {
        guard isRunning, timeline != nil else { return }
        scheduleLoop()
    }

    /// One looping bar buffer is sample-accurate and needs no timer.
    private func scheduleLoop() {
        dispatchPrecondition(condition: .onQueue(.main))
        let tempo = tempo, accents = timeSignature.accents, volume = outputVolume, sound = sound, token = generation
        let subdivision = subdivision
        let beats = accents.count
        let interval = 60 / Double(tempo)
        let lead: TimeInterval = 0.06
        let latency = AVAudioSession.sharedInstance().outputLatency
        timeline = (CACurrentMediaTime() + lead + latency, interval, beats)
        audioQueue.async { [self] in
            player.stop()
            schedule.current = nil
            let rate = AVAudioSession.sharedInstance().sampleRate
            if rate > 0, rate != format.sampleRate,
               let matching = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1) {
                engine.stop()
                format = matching
                engine.connect(player, to: engine.mainMixerNode, format: format)
            }
            guard let buffer = Self.makeBar(format: format, interval: interval, accents: accents,
                                           sound: sound, subdivision: subdivision) else { return }
            player.volume = volume
            do {
                if !engine.isRunning { try engine.start() }
            } catch {
                print("节拍器启动失败: \(error.localizedDescription)")
                DispatchQueue.main.async { if self.generation == token { self.stop() } }
                return
            }
            player.scheduleBuffer(buffer, at: nil, options: .loops)
            let start = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: lead)
            player.play(at: AVAudioTime(hostTime: start))
            loopID += 1
            schedule.current = .init(id: loopID, startHostSeconds: AVAudioTime.seconds(forHostTime: start),
                                     barSeconds: Double(buffer.frameLength) / format.sampleRate, gain: volume)
        }
    }

    static func makeBar(format: AVAudioFormat, interval: TimeInterval,
                        accents: [TimeSignature.Accent], sound: MetronomeSound = .click,
                        subdivision: MetronomeSubdivision = .beat) -> AVAudioPCMBuffer? {
        let beats = accents.count
        let frames = (interval * format.sampleRate).rounded()
        guard frames.isFinite, frames >= Double(subdivision.rawValue), beats > 0,
              frames * Double(beats) < Double(UInt32.max) else { return nil }
        let beatFrames = AVAudioFrameCount(frames)
        guard beatFrames > 0, let buffer = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: beatFrames * AVAudioFrameCount(beats)),
            let samples = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = buffer.frameCapacity
        for index in 0..<Int(buffer.frameLength) { samples[index] = 0 }
        let accent = tickSamples(sampleRate: format.sampleRate, accent: true, sound: sound)
        let normal = tickSamples(sampleRate: format.sampleRate, accent: false, sound: sound)
        // The same samples repeat each bar so the microphone can learn and remove them.
        for (beat, level) in accents.enumerated() {
            for part in 0..<subdivision.rawValue {
                let tick = part == 0 && level == .strong ? accent : normal
                let mainGain: Float = beats == 1 || level == .strong ? 1.0 : (level == .medium ? 0.92 : 0.85)
                let gain: Float = part == 0 ? mainGain : 0.55
                // Round each position within the original beat, never each interval:
                // triplets stay even to one sample without changing the bar length.
                let start = Int((Double(beatFrames) * Double(part) / Double(subdivision.rawValue)).rounded())
                let end = Int((Double(beatFrames) * Double(part + 1) / Double(subdivision.rawValue)).rounded())
                let count = min(tick.count, end - start)
                let fadeFrames = min(count, max(2, Int(format.sampleRate * 0.004)))
                let offset = beat * Int(beatFrames) + start
                for index in 0..<count {
                    // At 240 BPM, four subdivisions leave 62.5 ms per click.
                    // Fade a shortened tail instead of overlapping or clipping.
                    let fade: Float = count < tick.count
                        ? min(1, Float(count - 1 - index) / Float(max(1, fadeFrames - 1))) : 1
                    samples[offset + index] = tick[index] * gain * fade
                }
            }
        }
        return buffer
    }

    /// A bright, short click with more audible body. Increasing the duration at
    /// useful level (rather than multiplying an already near-full-scale peak)
    /// improves audibility without digital clipping. A short tail fade avoids a
    /// discontinuity at the end; the frequency distinction keeps the downbeat clear.
    static func tickSamples(sampleRate: Double, accent: Bool, sound: MetronomeSound = .click) -> [Float] {
        guard sampleRate.isFinite, (8_000...192_000).contains(sampleRate) else { return [] }
        if sound == .click { return mechanicalSamples(sampleRate: sampleRate, accent: accent) }
        let frequency = accent ? 2600.0 : 2100.0
        let count = Int(0.080 * sampleRate)
        return (0..<count).map { index in
            let time = Double(index) / sampleRate
            let attack = min(1, time / 0.0005)
            let body = exp(-max(0, time - 0.008) / 0.032)
            let release = min(1, Double(count - 1 - index) / (0.005 * sampleRate))
            return Float(0.95 * sin(2 * .pi * frequency * time) * attack * body * release)
        }
    }

    /// One real clockwork-metronome strike, trimmed and levelled from a CC0
    /// field recording. Load once off the UI thread; no file I/O during beats.
    /// Source, licence and processing are in MetronomeMechanicalSource.json.
    private static let mechanicalRecording: (rate: Double, samples: [Float])? = {
        guard let url = Bundle.main.url(forResource: "MetronomeMechanical", withExtension: "wav"),
              let file = try? AVAudioFile(forReading: url),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                             frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil,
              let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return nil }
        return (file.processingFormat.sampleRate, Array(UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength))))
    }()

    private static func mechanicalSamples(sampleRate: Double, accent: Bool) -> [Float] {
        guard let recording = mechanicalRecording else {
            // Retain a usable click if an external/incomplete build omits its asset.
            return tickSamples(sampleRate: sampleRate, accent: accent, sound: .electronic)
        }
        let count = Int((Double(recording.samples.count) * sampleRate / recording.rate).rounded())
        return (0..<count).map { index in
            let position = Double(index) * recording.rate / sampleRate
            let left = min(Int(position), recording.samples.count - 1)
            let right = min(left + 1, recording.samples.count - 1)
            let fraction = Float(position - Double(left))
            // Accents use the bar's gain, preserving the real strike's timbre.
            return recording.samples[left] * (1 - fraction) + recording.samples[right] * fraction
        }
    }

    private func releaseSessionIfNeeded() {
        audioQueue.async { [self] in
            guard ownsSession else { return }
            ownsSession = false
            PracticeAudioCapture.releaseSharedSession()
        }
    }

    private func setAudible(_ audible: Bool) {
        audibleOff?.cancel()
        audibleOff = nil
        if audible {
            guard !isAudible else { return }
            isAudible = true
            onAudibleChanged?(true)
        } else {
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.isRunning, self.isAudible else { return }
                self.isAudible = false
                self.onAudibleChanged?(false)
            }
            audibleOff = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.detectionTail, execute: work)
        }
    }

    /// Starting/stopping microphone capture can reconfigure the output route.
    @objc private func engineConfigurationChanged(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isRunning else { return }
            self.audioQueue.async { self.engine.stop() }
            self.scheduleLoop()
        }
    }

    @objc private func enteredBackground() {
        DispatchQueue.main.async { [weak self] in self?.stop() }
    }

    @objc private func sessionInterrupted(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
        DispatchQueue.main.async { [weak self] in self?.stop() }
    }
}
