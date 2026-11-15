import AVFoundation
import SoundAnalysis

enum PracticeAnalysisError: LocalizedError {
    case invalidAudio, noResults, completionTimeout, stalledInput, speechModelUnavailable, vocalModelUnavailable
    case pitchModelUnavailable

    var errorDescription: String? {
        switch self {
        case .speechModelUnavailable: return "人声识别模型不可用，请重新安装应用后重试。".localized
        case .vocalModelUnavailable: return "歌声识别模型不可用，请重新安装应用后重试。".localized
        case .pitchModelUnavailable: return "音准模型不可用，请重新安装应用后重试。".localized
        case .invalidAudio: return "无法读取音频输入，请检查麦克风或音频文件。".localized
        case .noResults: return "音频太短或没有有效检测结果，请使用至少 3 秒的录音。".localized
        case .completionTimeout: return "声音检测未及时完成，请重试。".localized
        case .stalledInput: return "麦克风输入已中断，请重新开始检测。".localized
        }
    }
}

/// Bounded gain for the classifier only. The policy always receives original
/// dBFS. Per-sample envelopes make live/file results independent of tap size.
struct PracticeInputLeveler {
    private let powerSmoothing: Float
    private let gainSmoothing: Float
    private var power: Float = 0.0001
    private var gain: Float = 1

    init(sampleRate: Double) {
        powerSmoothing = Float(exp(-1 / (sampleRate * 0.5)))
        gainSmoothing = Float(exp(-1 / (sampleRate * 0.1)))
    }

    mutating func process(_ sample: Float) -> Float {
        guard sample.isFinite else { return 0 }
        power = powerSmoothing * power + (1 - powerSmoothing) * sample * sample
        // Aim for -25 dBFS, boost by at most 36 dB, and never clip a loud onset.
        let target = min(63.0957, max(1, 0.056234 / sqrt(max(power, 1e-12))))
        gain = gainSmoothing * gain + (1 - gainSmoothing) * target
        gain = min(gain, 0.95 / max(abs(sample), 1e-12))
        return sample * gain
    }
}

/// Prefix energy preserves exact sample boundaries when a classifier window
/// only overlaps part of a capture buffer. A block average leaks neighbouring
/// notes into silence (and silence into weak notes).
struct PracticeEnergyChunk {
    let startFrame: Int64
    private let prefix: [Double]
    var endFrame: Int64 { startFrame + Int64(prefix.count - 1) }

    init(samples: UnsafeBufferPointer<Float>, startFrame: Int64) {
        self.startFrame = startFrame
        var sums = [Double]()
        sums.reserveCapacity(samples.count + 1)
        sums.append(0)
        var sum = 0.0
        for sample in samples {
            let value = sample.isFinite ? Double(sample) : 0
            sum += value * value
            sums.append(sum)
        }
        prefix = sums
    }

    func energy(from start: Int64, to end: Int64) -> (sum: Double, frames: Int64) {
        let lower = max(startFrame, start)
        let upper = min(endFrame, end)
        guard upper > lower else { return (0, 0) }
        return (max(0, prefix[Int(upper - startFrame)] - prefix[Int(lower - startFrame)]), upper - lower)
    }
}

/// Owns one classifier and one policy per recording. Feed/finish/cancel must be
/// serialized by the caller. Observer callbacks protect their shared state.
final class PracticeSoundAnalyzer: NSObject, SNResultsObserving {
    static let windowDuration: Double = 1
    static let overlapFactor: Double = 0.5

    private let acousticAnalyzer: PracticeAcousticAnalyzer
    private let analyzer: SNAudioStreamAnalyzer
    private let lock = NSLock()
    private let completion = DispatchSemaphore(value: 0)
    private var policy: PracticeDetectionPolicy
    private var levels: [PracticeEnergyChunk] = []
    private var position: AVAudioFramePosition = 0
    private var leveler: PracticeInputLeveler
    private var failure: Error?
    private let sampleRate: Double
    private let onResult: (PracticeDetectionUpdate) -> Void
    private let onError: (Error) -> Void
    private let canceller: MetronomeCanceller
    private let metronome: MetronomeSource
    /// Live only: the cancelled microphone signal for the optional pitch display.
    var onCancelledAudio: ((UnsafeBufferPointer<Float>, AVAudioFramePosition) -> Void)?

    /// Live audio follows the app's metronome; file tests can supply a fixed one.
    enum MetronomeSource {
        case none
        case live(MetronomeSchedule)
        case fixed(MetronomeAlignment)
    }

    init(sampleRate: Double, configuration: PracticeDetectionConfiguration,
         metronome: MetronomeSource = .none,
         onResult: @escaping (PracticeDetectionUpdate) -> Void,
         onError: @escaping (Error) -> Void = { _ in }) throws {
        guard sampleRate.isFinite, sampleRate > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                        sampleRate: sampleRate, channels: 1, interleaved: false)
        else { throw PracticeAnalysisError.invalidAudio }
        self.sampleRate = sampleRate
        self.metronome = metronome
        canceller = MetronomeCanceller(sampleRate: sampleRate)
        leveler = PracticeInputLeveler(sampleRate: sampleRate)
        acousticAnalyzer = try PracticeAcousticAnalyzer(inputFormat: format)
        analyzer = SNAudioStreamAnalyzer(format: format)
        policy = PracticeDetectionPolicy(configuration: configuration)
        self.onResult = onResult
        self.onError = onError
        super.init()
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        request.windowDuration = CMTime(seconds: Self.windowDuration, preferredTimescale: 48_000)
        request.overlapFactor = Self.overlapFactor
        try analyzer.add(request, withObserver: self)
    }

    func configure(_ configuration: PracticeDetectionConfiguration) {
        lock.lock()
        policy.configuration = configuration
        lock.unlock()
    }

    /// Copy borrowed tap/file storage before returning to its owner. Mix stereo,
    /// falling back to the strongest channel only if phase cancellation occurs.
    static func copyMono(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0, buffer.format.commonFormat == .pcmFormatFloat32,
              let input = buffer.floatChannelData,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: buffer.format.sampleRate,
                                         channels: 1, interleaved: false),
              let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength),
              let output = copy.floatChannelData?[0] else { return nil }
        let stride = buffer.format.isInterleaved ? channels : 1
        var selectedChannel = 0
        var highestEnergy = -Double.infinity
        for channel in 0..<channels {
            let data = buffer.format.isInterleaved ? input[0].advanced(by: channel) : input[channel]
            var energy = 0.0
            for frame in 0..<frames {
                let value = Double(data[frame * stride])
                if value.isFinite { energy += value * value }
            }
            if energy > highestEnergy {
                selectedChannel = channel
                highestEnergy = energy
            }
        }
        var mixedEnergy = 0.0
        for frame in 0..<frames {
            var sum: Float = 0
            for channel in 0..<channels {
                let data = buffer.format.isInterleaved ? input[0].advanced(by: channel) : input[channel]
                let value = data[frame * stride]
                sum += value.isFinite ? value : 0
            }
            output[frame] = sum / Float(channels)
            mixedEnergy += Double(output[frame]) * Double(output[frame])
        }
        if mixedEnergy < highestEnergy * 0.1 {
            let data = buffer.format.isInterleaved ? input[0].advanced(by: selectedChannel) : input[selectedChannel]
            for frame in 0..<frames {
                let value = data[frame * stride]
                output[frame] = value.isFinite ? value : 0
            }
        }
        copy.frameLength = buffer.frameLength
        return copy
    }

    /// `hostSeconds`: host-clock time of the first frame, for the live metronome.
    func append(_ mono: AVAudioPCMBuffer, hostSeconds: Double? = nil) throws {
        guard mono.format.sampleRate == sampleRate, mono.format.channelCount == 1,
              mono.frameLength > 0, let data = mono.floatChannelData?[0] else {
            throw PracticeAnalysisError.invalidAudio
        }
        // Remove our own clicks before levels, features and classification.
        let alignment: MetronomeAlignment?
        switch metronome {
        case .none: alignment = nil
        case .fixed(let fixed): alignment = fixed
        case .live(let schedule):
            alignment = MetronomeCanceller.alignment(for: schedule.current, sampleRate: sampleRate,
                                                      bufferStartFrame: position,
                                                      bufferHostSeconds: hostSeconds ?? 0)
        }
        canceller.process(data, count: Int(mono.frameLength), startFrame: position, alignment: alignment)
        onCancelledAudio?(UnsafeBufferPointer(start: data, count: Int(mono.frameLength)), position)
        let level = PracticeEnergyChunk(samples: UnsafeBufferPointer(start: data, count: Int(mono.frameLength)),
                                        startFrame: position)
        lock.lock()
        levels.append(level)
        let error = failure
        lock.unlock()
        if let error { throw error }
        guard let leveled = AVAudioPCMBuffer(pcmFormat: mono.format, frameCapacity: mono.frameLength),
              let output = leveled.floatChannelData?[0] else {
            throw PracticeAnalysisError.invalidAudio
        }
        leveled.frameLength = mono.frameLength
        for frame in 0..<Int(mono.frameLength) { output[frame] = leveler.process(data[frame]) }
        try acousticAnalyzer.append(leveled)
        analyzer.analyze(leveled, atAudioFramePosition: position)
        position += AVAudioFramePosition(mono.frameLength)
    }

    func finish() throws {
        analyzer.completeAnalysis()
        guard completion.wait(timeout: .now() + 30) == .success else {
            throw PracticeAnalysisError.completionTimeout
        }
        lock.lock()
        let error = failure
        lock.unlock()
        if let error { throw error }
    }

    func cancel() {
        analyzer.removeAllRequests()
    }

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult else { return }
        let start = result.timeRange.start.seconds
        let end = CMTimeRangeGetEnd(result.timeRange).seconds
        var acoustics: PracticeAcousticFeatures
        do {
            guard let available = try acousticAnalyzer.features(start: start, end: end) else { return }
            acoustics = available
            acoustics.metronomeRepeatShare = canceller.repeatShare(
                startFrame: Int64((start * sampleRate).rounded()),
                endFrame: Int64((end * sampleRate).rounded())) ?? 0
        } catch {
            self.request(request, didFailWithError: error)
            return
        }
        let scores = PracticeSoundScores(classifications: Dictionary(
            result.classifications.map { ($0.identifier, $0.confidence) },
            uniquingKeysWith: max))
        lock.lock()
        let startFrame = Int64((start * sampleRate).rounded())
        let endFrame = Int64((end * sampleRate).rounded())
        var energy = 0.0
        var coveredFrames: Int64 = 0
        for level in levels {
            let overlap = level.energy(from: startFrame, to: endFrame)
            energy += overlap.sum
            coveredFrames += overlap.frames
        }
        // Don't apply a confidence from one window to the volume of another.
        let update: PracticeDetectionUpdate?
        if Double(coveredFrames) >= Double(endFrame - startFrame) * 0.95, coveredFrames > 0 {
            let db = Float(10 * log10(max(1e-16, energy / Double(coveredFrames))))
            update = policy.consume(scores: scores, decibels: db, endTime: end, acoustics: acoustics)
        } else {
            update = nil
        }
        levels.removeAll { $0.endFrame < endFrame - Int64(Self.windowDuration * sampleRate) }
        lock.unlock()
        if let update { onResult(update) }
    }

    func request(_ request: SNRequest, didFailWithError error: Error) {
        lock.lock()
        failure = error
        lock.unlock()
        onError(error)
        completion.signal()
    }

    func requestDidComplete(_ request: SNRequest) {
        completion.signal()
    }
}

/// Bounded live queue: audio callbacks only copy samples. Slow classification
/// cannot accumulate minutes of stale audio or keep a stopped session alive.
final class LivePracticeDetector {
    private let queue = DispatchQueue(label: "MusicFocus.practiceDetection", qos: .userInitiated)
    private let slots = DispatchSemaphore(value: 8)
    private let cancellationLock = NSLock()
    private var cancelled = false
    private var analyzer: PracticeSoundAnalyzer
    private var configuration: PracticeDetectionConfiguration
    private var expectedPosition: AVAudioFramePosition?
    #if DEBUG && targetEnvironment(simulator)
    private let fixtureWriter = PracticeMicrophoneFixtureWriter()
    #endif
    private let onResult: (PracticeDetectionUpdate) -> Void
    private let onReset: () -> Void
    private let onError: (Error) -> Void
    private let onAudio: ((UnsafeBufferPointer<Float>, AVAudioFramePosition) -> Void)?

    init(sampleRate: Double, configuration: PracticeDetectionConfiguration,
         onResult: @escaping (PracticeDetectionUpdate) -> Void,
         onReset: @escaping () -> Void,
         onError: @escaping (Error) -> Void,
         onAudio: ((UnsafeBufferPointer<Float>, AVAudioFramePosition) -> Void)? = nil) throws {
        self.configuration = configuration
        self.onResult = onResult
        self.onReset = onReset
        self.onError = onError
        self.onAudio = onAudio
        analyzer = try PracticeSoundAnalyzer(sampleRate: sampleRate, configuration: configuration,
                                            metronome: .live(.shared), onResult: onResult, onError: onError)
        analyzer.onCancelledAudio = onAudio
    }

    private var isCancelled: Bool {
        cancellationLock.lock()
        defer { cancellationLock.unlock() }
        return cancelled
    }

    /// `hostSeconds`: host-clock time of the buffer's first frame (0 if unknown).
    func enqueue(_ buffer: AVAudioPCMBuffer, at position: AVAudioFramePosition, hostSeconds: Double = 0) {
        guard !isCancelled, slots.wait(timeout: .now()) == .success else { return }
        guard let copy = PracticeSoundAnalyzer.copyMono(buffer) else {
            slots.signal()
            onError(PracticeAnalysisError.invalidAudio)
            return
        }
        queue.async { [self] in
            defer { slots.signal() }
            guard !isCancelled else { return }
            do {
                if let expectedPosition, expectedPosition != position {
                    analyzer.cancel()
                    analyzer = try PracticeSoundAnalyzer(
                        sampleRate: copy.format.sampleRate, configuration: configuration,
                        metronome: .live(.shared), onResult: onResult, onError: onError)
                    analyzer.onCancelledAudio = onAudio
                    onReset()
                }
                expectedPosition = position + AVAudioFramePosition(copy.frameLength)
                #if DEBUG && targetEnvironment(simulator)
                fixtureWriter.append(copy)
                #endif
                try analyzer.append(copy, hostSeconds: hostSeconds)
            } catch {
                onError(error)
            }
        }
    }

    func configure(_ configuration: PracticeDetectionConfiguration) {
        queue.async { [self] in
            self.configuration = configuration
            analyzer.configure(configuration)
        }
    }

    func cancel() {
        cancellationLock.lock()
        cancelled = true
        cancellationLock.unlock()
        queue.async { [self] in
            analyzer.cancel()
            #if DEBUG && targetEnvironment(simulator)
            fixtureWriter.stop()
            #endif
        }
    }
}

struct PracticeFileReport {
    var windowCount = 0
    var fileDuration: Double = 0
    var observedDuration: Double = 0
    var musicEvidenceDuration: Double = 0
    var practiceDuration: Double = 0
    var confidenceSum: Double = 0
    var firstPracticeTime: Double?
    var detectedPractice: Bool { firstPracticeTime != nil }
    var meanConfidence: Float { windowCount > 0 ? Float(confidenceSum / Double(windowCount)) : 0 }
}

enum PracticeFileEvaluator {
    /// Fresh classifier/policy for every file; no access to the live monitor.
    /// Read incrementally, with the same windows, levels and policy as live audio.
    static func evaluate(url: URL, configuration: PracticeDetectionConfiguration,
                         metronome: MetronomeAlignment? = nil,
                         onResult: ((PracticeDetectionUpdate) -> Void)? = nil) throws -> PracticeFileReport {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let reportLock = NSLock()
        var report = PracticeFileReport()
        report.fileDuration = Double(file.length) / file.processingFormat.sampleRate
        var previouslyPracticing = false
        let detector = try PracticeSoundAnalyzer(
            sampleRate: file.processingFormat.sampleRate, configuration: configuration,
            metronome: metronome.map { .fixed($0) } ?? .none) { update in
                reportLock.lock()
                report.windowCount += 1
                report.observedDuration += update.evaluatedDuration
                report.confidenceSum += max(update.scores.music, update.scores.instrument)
                if update.evidence == .music { report.musicEvidenceDuration += update.evaluatedDuration }
                // Count the interval after confirmation, including the interval
                // leading up to an exit, as the live focus timer does.
                if previouslyPracticing { report.practiceDuration += update.evaluatedDuration }
                if update.isPracticing {
                    if report.firstPracticeTime == nil { report.firstPracticeTime = update.endTime }
                }
                previouslyPracticing = update.isPracticing
                reportLock.unlock()
                onResult?(update)
            }
        defer { detector.cancel() }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) else {
            throw PracticeAnalysisError.invalidAudio
        }
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: 4096)
            guard let mono = PracticeSoundAnalyzer.copyMono(buffer) else {
                throw PracticeAnalysisError.invalidAudio
            }
            try detector.append(mono)
        }
        try detector.finish()
        reportLock.lock()
        let completedReport = report
        reportLock.unlock()
        guard completedReport.windowCount >= 4 else { throw PracticeAnalysisError.noResults }
        return completedReport
    }
}
