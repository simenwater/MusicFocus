import Foundation
import Accelerate
import CoreML

/// One pitch reading for a 64 ms frame centred at `time` (stream seconds).
struct PitchEstimate: Equatable {
    let time: Double
    /// Hz; meaningful only when `isVoiced`.
    let frequency: Double
    /// CREPE's peak bin activation, 0...1.
    let confidence: Double
    /// RMS level of the frame in dBFS.
    let level: Double

    static let confidenceThreshold = 0.5
    static let levelGate = -70.0
    var isVoiced: Bool { confidence >= Self.confidenceThreshold && level > Self.levelGate }
}

/// Monophonic pitch with CREPE tiny (MIT, ~1 MB). Single notes of strings, erhu,
/// winds and voice; chords give low confidence instead of a reliable note.
/// Not thread-safe: callers serialize use off the main thread.
final class PracticePitchEstimator {
    static let modelRate = 16_000.0
    static let frameLength = 1024
    /// Input-rate samples needed around a frame centre (frame plus resampling kernel).
    static func span(sampleRate: Double) -> Int {
        Int((Double(frameLength) / modelRate * sampleRate).rounded(.up)) + 2 * kernelHalfWidth + 2
    }
    private static let kernelHalfWidth = 24

    private let model: MLModel
    private let input: MLMultiArray
    private var frame = [Float](repeating: 0, count: frameLength)

    init() throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        model = try MLModel(contentsOf: Self.modelURL(), configuration: configuration)
        input = try MLMultiArray(shape: [1, NSNumber(value: Self.frameLength)], dataType: .float32)
    }

    private static func modelURL() throws -> URL {
        #if os(macOS)
        if let path = ProcessInfo.processInfo.environment["MUSICFOCUS_PITCH_MODEL"] {
            return URL(fileURLWithPath: path)
        }
        #endif
        guard let url = Bundle.main.url(forResource: "PracticePitchModel", withExtension: "mlmodelc") else {
            throw PracticeAnalysisError.pitchModelUnavailable
        }
        return url
    }

    /// `samples[0]` is at input position `firstIndex`; the frame is centred at
    /// input position `center` (may be fractional). Needs `span` samples around it.
    func estimate(_ samples: UnsafeBufferPointer<Float>, firstIndex: Double, center: Double,
                  sampleRate: Double, time: Double) throws -> PitchEstimate {
        resample(samples, firstIndex: firstIndex, center: center, sampleRate: sampleRate)
        var mean: Float = 0, meanSquare: Float = 0
        vDSP_meanv(frame, 1, &mean, vDSP_Length(Self.frameLength))
        vDSP_measqv(frame, 1, &meanSquare, vDSP_Length(Self.frameLength))
        let level = 10 * log10(max(1e-16, Double(meanSquare)))
        let deviation = sqrt(max(0, meanSquare - mean * mean))
        guard deviation > 1e-7 else { return PitchEstimate(time: time, frequency: 0, confidence: 0, level: level) }
        // CREPE's own normalization: zero mean, unit standard deviation per frame.
        let pointer = input.dataPointer.bindMemory(to: Float.self, capacity: Self.frameLength)
        for index in 0..<Self.frameLength { pointer[index] = (frame[index] - mean) / deviation }
        // Each prediction allocates autoreleased Core ML buffers; drain them per
        // frame, or long loops exhaust IOSurface memory.
        let decoded: (bin: Double, confidence: Double)? = try autoreleasepool {
            let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["input": input]))
            return output.featureValue(for: "Identity")?.multiArrayValue.map(Self.centroid)
        }
        guard let (bin, confidence) = decoded else { throw PracticeAnalysisError.invalidAudio }
        // Bin to cents above 10 Hz, as in the original implementation.
        let cents = 1997.3794084376191 + 20 * bin
        return PitchEstimate(time: time, frequency: 10 * pow(2, cents / 1200), confidence: confidence, level: level)
    }

    /// Weighted average of the 9 bins around the peak (CREPE's decoding).
    static func centroid(_ bins: MLMultiArray) -> (bin: Double, confidence: Double) {
        let count = bins.count
        var values = [Float](repeating: 0, count: count)
        if bins.dataType == .float32 {
            let pointer = bins.dataPointer.bindMemory(to: Float.self, capacity: count)
            for index in 0..<count { values[index] = pointer[index] }
        } else {
            for index in 0..<count { values[index] = bins[index].floatValue }
        }
        var peak: Float = 0
        var peakIndex: vDSP_Length = 0
        vDSP_maxvi(values, 1, &peak, &peakIndex, vDSP_Length(count))
        let lower = max(0, Int(peakIndex) - 4), upper = min(count - 1, Int(peakIndex) + 4)
        var sum: Double = 0, weighted: Double = 0
        for index in lower...upper {
            sum += Double(values[index])
            weighted += Double(index) * Double(values[index])
        }
        return (sum > 0 ? weighted / sum : Double(peakIndex), Double(peak))
    }

    /// Windowed-sinc resampling of exactly one frame, low-passed below 8 kHz.
    /// Stateless: every frame is placed by sample position, so nothing drifts.
    private func resample(_ samples: UnsafeBufferPointer<Float>, firstIndex: Double, center: Double, sampleRate: Double) {
        let step = sampleRate / Self.modelRate
        let cutoff = min(1, 7_600 / (sampleRate / 2))
        let half = Double(Self.kernelHalfWidth)
        let start = center - step * Double(Self.frameLength) / 2
        for k in 0..<Self.frameLength {
            let position = start + Double(k) * step - firstIndex
            let base = Int(position.rounded(.down))
            var value = 0.0
            for tap in (base - Self.kernelHalfWidth + 1)...(base + Self.kernelHalfWidth) {
                guard tap >= 0, tap < samples.count else { continue }
                let distance = position - Double(tap)
                let x = .pi * cutoff * distance
                let sinc = abs(x) < 1e-9 ? 1 : sin(x) / x
                let window = 0.5 + 0.5 * cos(.pi * distance / half)
                value += Double(samples[tap]) * cutoff * sinc * window
            }
            frame[k] = Float(value)
        }
    }
}

/// Streaming wrapper: keeps the recent input and estimates every `hop` seconds.
final class PracticePitchTracker {
    let sampleRate: Double
    let hopSeconds: Double
    private let estimator: PracticePitchEstimator
    private var samples: [Float] = []
    private var firstFrame: Int64 = 0
    private var nextCenter: Double?
    private let span: Int

    init(sampleRate: Double, hopSeconds: Double = 0.032, estimator: PracticePitchEstimator? = nil) throws {
        self.sampleRate = sampleRate
        self.hopSeconds = hopSeconds
        self.estimator = try estimator ?? PracticePitchEstimator()
        span = PracticePitchEstimator.span(sampleRate: sampleRate)
    }

    /// `startFrame`: stream frame of `chunk[0]`. A gap restarts the history.
    func append(_ chunk: UnsafeBufferPointer<Float>, startFrame: Int64) throws -> [PitchEstimate] {
        if samples.isEmpty || startFrame != firstFrame + Int64(samples.count) {
            samples.removeAll(keepingCapacity: true)
            firstFrame = startFrame
            nextCenter = nil
        }
        samples.append(contentsOf: chunk)
        let half = Double(span) / 2
        if nextCenter == nil { nextCenter = Double(firstFrame) + half }
        var results: [PitchEstimate] = []
        while let center = nextCenter, center + half <= Double(firstFrame + Int64(samples.count)) {
            let estimate = try samples.withUnsafeBufferPointer {
                try estimator.estimate($0, firstIndex: Double(firstFrame), center: center,
                                       sampleRate: sampleRate, time: center / sampleRate)
            }
            results.append(estimate)
            nextCenter = center + hopSeconds * sampleRate
        }
        // Keep only what the next frame still needs.
        if let center = nextCenter {
            let keepFrom = Int64((center - half).rounded(.down)) - firstFrame
            if keepFrom > 0 {
                let drop = min(Int(keepFrom), samples.count)
                samples.removeFirst(drop)
                firstFrame += Int64(drop)
            }
        }
        return results
    }
}
