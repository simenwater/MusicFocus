import Foundation
import Accelerate
import CoreML

/// Independent vocal evidence from YAMNet, using only the existing audio window.
/// The caller serializes inference off the main thread.
final class PracticeVocalAnalyzer {
    struct Scores {
        let singing: Double
        let speech: Double
        let music: Double
        let milliseconds: Double
    }

    private let model: MLModel
    private let fft: FFTSetup
    private let hann: [Float]
    private let filters: [[Float]]

    init() throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        model = try MLModel(contentsOf: Self.modelURL(), configuration: configuration)
        guard let setup = vDSP_create_fftsetup(9, FFTRadix(kFFTRadix2)) else {
            throw PracticeAnalysisError.invalidAudio
        }
        fft = setup
        // TensorFlow's periodic Hann, magnitude spectrum (not power), and
        // triangular mel filters. Parameters match the original YAMNet frontend.
        hann = (0..<400).map { Float(0.5 - 0.5 * cos(2 * .pi * Double($0) / 400)) }
        let lower = 1127 * log(1 + 125.0 / 700)
        let upper = 1127 * log(1 + 7500.0 / 700)
        let edges = (0..<66).map { lower + Double($0) * (upper - lower) / 65 }
        filters = (0..<64).map { band in
            (0..<257).map { bin in
                guard bin > 0 else { return Float(0) }
                let mel = 1127 * log(1 + Double(bin) * 16000 / 512 / 700)
                return Float(max(0, min((mel - edges[band]) / (edges[band + 1] - edges[band]),
                                       (edges[band + 2] - mel) / (edges[band + 2] - edges[band + 1]))))
            }
        }
    }

    private static func modelURL() throws -> URL {
        #if os(macOS)
        if let path = ProcessInfo.processInfo.environment["MUSICFOCUS_VOCAL_MODEL"] {
            return URL(fileURLWithPath: path)
        }
        #endif
        guard let url = Bundle.main.url(forResource: "PracticeVocalClassifier", withExtension: "mlmodelc") else {
            throw PracticeAnalysisError.vocalModelUnavailable
        }
        return url
    }

    func features(_ window: [Float]) throws -> [Float] {
        guard window.count >= 15600, window.allSatisfy(\.isFinite) else {
            throw PracticeAnalysisError.invalidAudio
        }
        // 96 frames of 400 samples, hop 160: 0.975 seconds, centered inside
        // the already available one-second / 16 kHz window. No padding ahead.
        let start = (window.count - 15600) / 2
        var result: [Float] = []
        result.reserveCapacity(6144)
        var real = [Float](repeating: 0, count: 512)
        var imaginary = real
        var magnitude = [Float](repeating: 0, count: 257)
        for frame in 0..<96 {
            for i in 0..<512 {
                real[i] = i < 400 ? window[start + frame * 160 + i] * hann[i] : 0
                imaginary[i] = 0
            }
            real.withUnsafeMutableBufferPointer { r in
                imaginary.withUnsafeMutableBufferPointer { i in
                    var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                    vDSP_fft_zip(fft, &split, 1, 9, FFTDirection(FFT_FORWARD))
                }
            }
            for i in 0..<257 { magnitude[i] = sqrt(real[i] * real[i] + imaginary[i] * imaginary[i]) }
            for filter in filters {
                var dot: Float = 0
                vDSP_dotpr(magnitude, 1, filter, 1, &dot, 257)
                result.append(log(dot + 0.001))
            }
        }
        return result
    }

    func scores(_ window: [Float]) throws -> Scores {
        let start = ProcessInfo.processInfo.systemUptime
        let values = try features(window)
        let input = try MLMultiArray(shape: [1, 96, 64], dataType: .float16)
        let pointer = input.dataPointer.assumingMemoryBound(to: Float16.self)
        for i in values.indices { pointer[i] = Float16(values[i]) }
        let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["features": input]))
        guard let scores = output.featureValue(for: "Identity")?.multiArrayValue, scores.count == 521 else {
            throw PracticeAnalysisError.vocalModelUnavailable
        }
        func maximum(_ indices: [Int]) throws -> Double {
            let values = indices.map { scores[$0].doubleValue }
            guard values.allSatisfy(\.isFinite) else { throw PracticeAnalysisError.invalidAudio }
            return min(1, max(0, values.max() ?? 0))
        }
        // Independent AudioSet confidences, never summed. Exclude rapping and
        // chanting from singing. Include choir, yodel, child singing, humming,
        // vocal music and a cappella. Speech also includes shouts/laughter/crying.
        return try Scores(singing: maximum([24, 25, 26, 29, 32, 249, 250]),
                          speech: maximum(Array(0...23)), music: maximum([132]),
                          milliseconds: (ProcessInfo.processInfo.systemUptime - start) * 1000)
    }

    deinit { vDSP_destroy_fftsetup(fft) }
}
