import AVFoundation
import Accelerate
import CoreML

/// Adds independent speech evidence and a narrow electrical-rumble check to the
/// same audio window as SoundAnalysis. Append is serialized by capture/file
/// analysis; observer reads are protected. All inference stays off the UI thread.
final class PracticeAcousticAnalyzer {
    private let model: MLModel
    private let vocalAnalyzer: PracticeVocalAnalyzer
    private let converter: AVAudioConverter
    private let format: AVAudioFormat
    private let inputFormat: AVAudioFormat
    private let inferenceLock = NSLock()
    private let lock = NSLock()
    private var samples: [Float] = []
    private var firstSample = 0
    private let fftSetup: FFTSetup
    private static let rate = 16_000.0
    private static let fftSize = 16_384

    init(inputFormat: AVAudioFormat) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                        sampleRate: Self.rate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: format),
              let setup = vDSP_create_fftsetup(14, FFTRadix(kFFTRadix2)) else {
            throw PracticeAnalysisError.invalidAudio
        }
        self.inputFormat = inputFormat
        self.format = format
        self.converter = converter
        // No priming silence added ahead of the audio timeline.
        converter.primeMethod = .none
        fftSetup = setup
        do {
            let configuration = MLModelConfiguration()
            // This small model is faster on CPU and avoids competing with UI GPU work.
            configuration.computeUnits = .cpuOnly
            model = try MLModel(contentsOf: Self.modelURL(), configuration: configuration)
            vocalAnalyzer = try PracticeVocalAnalyzer()
        } catch {
            vDSP_destroy_fftsetup(setup)
            throw error
        }
    }

    private static func modelURL() throws -> URL {
        #if os(macOS)
        // CLI evaluation loads the very same bundled model, compiled by run.sh.
        if let path = ProcessInfo.processInfo.environment["MUSICFOCUS_SPEECH_MODEL"] {
            return URL(fileURLWithPath: path)
        }
        #endif
        guard let url = Bundle.main.url(forResource: "PracticeSpeechClassifier", withExtension: "mlmodelc") else {
            throw PracticeAnalysisError.speechModelUnavailable
        }
        return url
    }

    func append(_ buffer: AVAudioPCMBuffer) throws {
        guard buffer.format == inputFormat, let data = buffer.floatChannelData?[0] else {
            throw PracticeAnalysisError.invalidAudio
        }
        let incoming = Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
        lock.lock()
        samples.append(contentsOf: incoming)
        // Keep original sample positions. Streaming resamplers retain samples;
        // treating their output count as input time shifts the VAD window.
        let excess = max(0, samples.count - Int(inputFormat.sampleRate * 5))
        if excess > 0 {
            samples.removeFirst(excess)
            firstSample += excess
        }
        lock.unlock()
    }

    func features(start: Double, end: Double) throws -> PracticeAcousticFeatures? {
        let wantedStart = Int((start * inputFormat.sampleRate).rounded())
        let wantedEnd = Int((end * inputFormat.sampleRate).rounded())
        lock.lock()
        let lower = wantedStart - firstSample
        let upper = wantedEnd - firstSample
        guard lower >= 0, upper > lower, upper <= samples.count else {
            lock.unlock()
            return nil
        }
        let source = Array(samples[lower..<upper])
        lock.unlock()
        inferenceLock.lock()
        defer { inferenceLock.unlock() }
        guard let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(source.count)),
              let output = AVAudioPCMBuffer(pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(ceil((end - start) * Self.rate)) + 1024) else {
            throw PracticeAnalysisError.invalidAudio
        }
        input.frameLength = AVAudioFrameCount(source.count)
        source.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: source.count) }
        // Resample this complete, already available window and drain the
        // converter. This adds no future audio and cannot drift over a session.
        converter.reset()
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, state in
            if supplied { state.pointee = .endOfStream; return nil }
            supplied = true
            state.pointee = .haveData
            return input
        }
        if let conversionError { throw conversionError }
        guard status != .error, output.frameLength > 0, let data = output.floatChannelData?[0] else {
            throw PracticeAnalysisError.invalidAudio
        }
        let count = min(Int(output.frameLength), Int(((end - start) * Self.rate).rounded()))
        let window = Array(UnsafeBufferPointer(start: data, count: count))
        var result = spectrum(window)
        let vocal = try vocalAnalyzer.scores(window)
        result.vocalProbability = vocal.singing
        result.vocalSpeechProbability = vocal.speech
        result.vocalMusicProbability = vocal.music
        result.vocalInferenceMS = vocal.milliseconds
        let speech = try speechProbability(in: window)
        result.speechProbability = speech.mean
        result.speechPeakProbability = speech.peak
        result.resampledThroughTime = start + Double(count) / Self.rate
        result.analyzedDBFS = 10 * log10(max(1e-16, window.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(window.count)))
        return result
    }

    private func speechProbability(in window: [Float]) throws -> (mean: Double, peak: Double) {
        // Each classification gets an independent VAD context. A long musical
        // or quiet lead-in must not bias the next speech window. This consumes
        // only samples already used by SoundAnalysis, never an added wait.
        let input = try MLMultiArray(shape: [1, 576], dataType: .float32)
        var hidden = try MLMultiArray(shape: [1, 128], dataType: .float32)
        var cell = try MLMultiArray(shape: [1, 128], dataType: .float32)
        hidden.dataPointer.initializeMemory(as: Float.self, repeating: 0, count: 128)
        cell.dataPointer.initializeMemory(as: Float.self, repeating: 0, count: 128)
        var context = [Float](repeating: 0, count: 64)
        var sum = 0.0
        var peak = 0.0
        var count = 0
        for offset in stride(from: 0, through: window.count - 512, by: 512) {
            let value = try autoreleasepool {
                let data = input.dataPointer.assumingMemoryBound(to: Float.self)
                for i in 0..<64 { data[i] = context[i] }
                for i in 0..<512 { data[i + 64] = window[offset + i] }
                for i in 0..<64 { context[i] = data[512 + i] }
                let result = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: [
                    "audio_input": input, "hidden_state": hidden, "cell_state": cell
                ]))
                guard let probability = result.featureValue(for: "vad_output")?.multiArrayValue,
                      let h = result.featureValue(for: "new_hidden_state")?.multiArrayValue,
                      let c = result.featureValue(for: "new_cell_state")?.multiArrayValue else {
                    throw PracticeAnalysisError.speechModelUnavailable
                }
                hidden = h
                cell = c
                let value = probability[0].doubleValue
                guard value.isFinite else { throw PracticeAnalysisError.invalidAudio }
                return min(1, max(0, value))
            }
            sum += value
            peak = max(peak, value)
            count += 1
        }
        return (count > 0 ? sum / Double(count) : 0, peak)
    }

    private func spectrum(_ window: [Float]) -> PracticeAcousticFeatures {
        let count = min(Self.fftSize, window.count)
        var real = [Float](repeating: 0, count: Self.fftSize)
        var imaginary = real
        for i in 0..<count {
            let hann = 0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(max(1, count - 1)))
            real[i] = window[i] * Float(hann)
        }
        real.withUnsafeMutableBufferPointer { r in
            imaginary.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                vDSP_fft_zip(fftSetup, &split, 1, 14, FFTDirection(FFT_FORWARD))
            }
        }
        var total = 0.0
        var hum = 0.0
        var harmonicHum = 0.0
        var peak = 0.0
        var logSum = 0.0
        var bins = 0
        for i in 1..<(Self.fftSize / 2) {
            let frequency = Double(i) * Self.rate / Double(Self.fftSize)
            guard frequency >= 30 else { continue }
            let power = Double(real[i]) * Double(real[i]) + Double(imaginary[i]) * Double(imaginary[i])
            total += power
            peak = max(peak, power)
            logSum += log(max(1e-20, power))
            bins += 1
            // Both common power-line frequencies and their first harmonics.
            if [50.0, 60, 100, 120].contains(where: { abs(frequency - $0) <= 1.5 }) { hum += power }
            if [100.0, 120].contains(where: { abs(frequency - $0) <= 1.5 }) { harmonicHum += power }
        }
        guard total > 1e-12, bins > 0 else { return .init() }
        return PracticeAcousticFeatures(mainsHumRatio: hum / total, mainsHarmonicRatio: harmonicHum / total,
            spectralFlatness: exp(logSum / Double(bins)) / (total / Double(bins)),
            strongestBinShare: peak / total)
    }

    deinit { vDSP_destroy_fftsetup(fftSetup) }
}
