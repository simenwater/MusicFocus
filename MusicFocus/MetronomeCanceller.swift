import Foundation

/// What the metronome is playing. Written by Metronome, read by capture threads.
final class MetronomeSchedule {
    struct Snapshot: Equatable {
        /// Changes whenever the click loop is restarted (tempo, bar or route).
        let id: Int
        /// Host-clock seconds at which the first bar was scheduled to start.
        let startHostSeconds: Double
        /// Exact bar length: the looping buffer's frames / its sample rate.
        let barSeconds: Double
        let gain: Float
    }

    static let shared = MetronomeSchedule()
    private let lock = NSLock()
    private var value: Snapshot?

    var current: Snapshot? {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}

/// Where the metronome's bars start in one analyzer stream.
struct MetronomeAlignment: Equatable {
    var id: Int
    /// Stream frame at which some bar starts. Any constant error (output and
    /// input latency, sound travel) is harmless: it is learned into the template.
    var anchorFrame: Int64
    var periodFrames: Int
    var gain: Float
}

/// Removes the app's own click track from the microphone signal before
/// classification. Every bar the speaker plays exactly the same samples, so the
/// microphone receives the same waveform each bar (speaker colouring, room echo
/// and latency included). The canceller learns that one-bar waveform and
/// subtracts it, sample by sample.
///
/// It learns a short block only when it repeats the same block of the previous
/// bar almost exactly. Playing, singing and speech never repeat sample for
/// sample, so they are not learned (and cannot later be "subtracted" into
/// silence); the classifier's own verdicts are not needed.
final class MetronomeCanceller {
    static let maxAveragedBars = 8
    static let maxBarFrames = 1 << 21
    /// Bar-to-bar difference allowed (about -30 dB of the block) on top of the
    /// room's own noise. Quiet notes under a loud click must not pass as a repeat.
    static let repeatTolerance: Float = 0.001

    private let lock = NSLock()
    private let blockFrames: Int
    private var alignment: MetronomeAlignment?
    /// Bar template at gain 1.0.
    private var template: [Float] = []
    private var counts: [UInt8] = []
    /// Raw microphone samples of the previous bar, and whether each was heard.
    private var previous: [Float] = []
    private var heard: [Bool] = []
    /// Bar-to-bar difference of a block holding only room noise (per frame).
    private var differenceFloor: Float = 0
    /// Recent blocks: did they repeat the previous bar? nil = no previous bar yet.
    private var blockLog: [(start: Int64, end: Int64, repeated: Bool?)] = []
    private let logFrames: Int64
    /// First frame heard of the current loop; and how long its unknown first
    /// bar is presumed to be the metronome alone (long bars fall back sooner).
    private var loopStart: Int64?
    private let warmUpFrames: Int64

    private let rise: Float

    init(sampleRate: Double) {
        blockFrames = max(64, Int((0.02 * sampleRate).rounded()))
        rise = Float(pow(10, 0.1 * (Double(blockFrames) / sampleRate) / 10))
        logFrames = Int64(3 * sampleRate)
        warmUpFrames = Int64(3 * sampleRate)
    }

    /// Share of [start, end) that merely repeated the previous bar: nothing but
    /// the metronome (and steady room tone) was sounding. Before a whole bar has
    /// been heard there is nothing to compare: the first 3 s count as repeats
    /// (not practice); later unknown frames do not, leaving the decision to the
    /// policy. nil when the metronome is not playing or nothing is logged.
    func repeatShare(startFrame: Int64, endFrame: Int64) -> Double? {
        lock.lock(); defer { lock.unlock() }
        guard alignment != nil else { return nil }
        var repeated: Int64 = 0, total: Int64 = 0
        for block in blockLog where block.end > startFrame && block.start < endFrame {
            let frames = min(block.end, endFrame) - max(block.start, startFrame)
            total += frames
            let warmingUp = block.start - (loopStart ?? block.start) < warmUpFrames
            if block.repeated == true || (block.repeated == nil && warmingUp) { repeated += frames }
        }
        return total > 0 ? Double(repeated) / Double(total) : nil
    }

    var learnedFrames: Int {
        lock.lock(); defer { lock.unlock() }
        return counts.reduce(0) { $0 + ($1 >= 2 ? 1 : 0) }
    }

    /// Alignment of the live metronome in this stream, or nil when it is silent
    /// or its bar is not a whole number of microphone frames (other route rates).
    static func alignment(for snapshot: MetronomeSchedule.Snapshot?, sampleRate: Double,
                          bufferStartFrame: Int64, bufferHostSeconds: Double) -> MetronomeAlignment? {
        guard let snapshot, bufferHostSeconds > 0 else { return nil }
        let period = snapshot.barSeconds * sampleRate
        guard period >= 1, abs(period - period.rounded()) < 1e-6, period <= Double(maxBarFrames) else { return nil }
        let anchor = bufferStartFrame + Int64(((snapshot.startHostSeconds - bufferHostSeconds) * sampleRate).rounded())
        return MetronomeAlignment(id: snapshot.id, anchorFrame: anchor, periodFrames: Int(period.rounded()),
                                  gain: snapshot.gain)
    }

    /// Cancels in place. `startFrame` is the stream frame of `samples[0]`.
    func process(_ samples: UnsafeMutablePointer<Float>, count: Int, startFrame: Int64,
                 alignment newAlignment: MetronomeAlignment?) {
        lock.lock(); defer { lock.unlock() }
        guard let newAlignment, newAlignment.gain > 0 else {
            if alignment != nil { reset(nil) }
            return
        }
        if alignment?.id != newAlignment.id || alignment?.periodFrames != newAlignment.periodFrames {
            // A restarted loop starts at a new phase: relearn from scratch.
            reset(newAlignment)
        } else if alignment?.gain != newAlignment.gain {
            // Same loop at a new volume: the previous bar no longer matches.
            alignment?.gain = newAlignment.gain
            for index in heard.indices { heard[index] = false }
        }
        guard let alignment else { return }
        if loopStart == nil { loopStart = startFrame }
        let period = Int64(alignment.periodFrames)
        var offset = 0
        while offset < count {
            let bin = Int(((startFrame + Int64(offset) - alignment.anchorFrame) % period + period) % period)
            // Blocks never wrap around the bar end.
            let length = min(blockFrames, count - offset, alignment.periodFrames - bin)
            let repeated = processBlock(samples + offset, length: length, bin: bin, gain: alignment.gain)
            let blockStart = startFrame + Int64(offset)
            blockLog.append((blockStart, blockStart + Int64(length), repeated))
            offset += length
        }
        let oldest = startFrame + Int64(count) - logFrames
        if let first = blockLog.firstIndex(where: { $0.end > oldest }), first > 0 {
            blockLog.removeFirst(first)
        }
    }

    /// Returns whether the block repeated the previous bar (nil: no previous bar).
    private func processBlock(_ x: UnsafeMutablePointer<Float>, length: Int, bin: Int, gain: Float) -> Bool? {
        var energy: Float = 0, difference: Float = 0, residual: Float = 0
        var repeated = true
        for index in 0..<length {
            let value = x[index]
            energy += value * value
            if heard[bin + index] {
                let delta = value - previous[bin + index]
                difference += delta * delta
            } else {
                repeated = false
            }
            if counts[bin + index] >= 2 {
                let delta = value - template[bin + index] * gain
                residual += delta * delta
            }
        }
        if repeated { trackDifferenceFloor(difference / Float(length)) }
        let floor = differenceFloor * Float(length)
        let repeats = repeated && difference <= Self.repeatTolerance * energy + 3 * floor
        if repeats {
            // Echo path changed (phone moved): restart this block from two bars.
            let stale = counts[bin] >= 2 && residual > 0.25 * energy && residual > 4 * floor
            for index in 0..<length {
                let value = x[index] / gain
                let count = stale ? 0 : Int(counts[bin + index])
                if count == 0 {
                    template[bin + index] = (value + previous[bin + index] / gain) / 2
                    counts[bin + index] = 2
                } else if difference <= 3 * floor {
                    // Once learned, refine only at the measured room-noise floor.
                    // A fraction of a loud click's energy can otherwise admit quiet
                    // playing into the template and inject it after playing stops.
                    let weight = 1 / Float(min(count + 1, Self.maxAveragedBars))
                    template[bin + index] += (value - template[bin + index]) * weight
                    if count < 255 { counts[bin + index] = UInt8(count + 1) }
                }
            }
        }
        for index in 0..<length {
            previous[bin + index] = x[index]
            heard[bin + index] = true
            if counts[bin + index] >= 2 { x[index] -= template[bin + index] * gain }
        }
        return repeated ? repeats : nil
    }

    /// Minimum tracking: drops at once, rises at most ~0.1 dB/s, so minutes of
    /// continuous playing cannot pull the room's floor up to the music.
    private func trackDifferenceFloor(_ value: Float) {
        guard value > 0 else { return }
        if differenceFloor == 0 || value < differenceFloor {
            differenceFloor = value
        } else {
            differenceFloor *= rise
        }
    }

    private func reset(_ alignment: MetronomeAlignment?) {
        self.alignment = alignment
        let frames = alignment?.periodFrames ?? 0
        template = [Float](repeating: 0, count: frames)
        counts = [UInt8](repeating: 0, count: frames)
        previous = [Float](repeating: 0, count: frames)
        heard = [Bool](repeating: false, count: frames)
        differenceFloor = 0
        blockLog.removeAll()
        loopStart = nil
    }
}
