import Foundation
import CoreGraphics
import Accelerate

/// An offline, open-set trajectory classifier. No OS handwriting API or download
/// is required. Both coarse and detailed trajectories must agree, and a digit
/// must be substantially closer than letters/marks AND competing digits.
enum ScoreDigitRecognizer {
    private struct Thresholds: Decodable {
        let threshold: Float
        let negativeRatio: Float
        let digitRatio: Float
    }

    private struct Configuration: Decodable {
        let limits: [Thresholds]
    }

    private struct AppleLimit: Decodable {
        let enabled: Bool
        let distance: Float
        let negativeRatio: Float
        let competingDigitRatio: Float
    }
    private struct AppleConfiguration: Decodable { let limits: [AppleLimit] }
    private static let appleLimits: [AppleLimit]? = {
        guard let url = Bundle.main.url(forResource: "FingeringAppleSupport", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(AppleConfiguration.self, from: data),
              config.limits.count == 10,
              config.limits.allSatisfy({ !$0.enabled || ($0.distance > 0 && $0.distance < 1 &&
                  $0.negativeRatio > 0 && $0.negativeRatio <= 2 &&
                  $0.competingDigitRatio > 0 && $0.competingDigitRatio <= 2) }) else { return nil }
        return config.limits
    }()
    static var hasAppleCalibration: Bool { appleLimits != nil }

    /// Apple's handwriting API does not expose a confidence score. Reject a
    /// non-numeral or a disagreement; use independently calibrated shape support
    /// for newly recovered digits. An empty result can use the offline fallback.
    static func resolveAppleText(_ text: String?, paths: [[CGPoint]]) -> Int? {
        guard !Task.isCancelled else { return nil }
        let fallback = recognize(paths: paths)
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return fallback }
        guard let digit = ScoreFingeringBeautifier.digit(text), fallback == nil || fallback == digit else { return nil }
        if fallback == digit { return digit }
        guard let limits = appleLimits, limits[digit].enabled,
              let support = appleSupport(for: digit, paths: paths) else { return nil }
        let limit = limits[digit]
        guard support.distance < limit.distance, support.negativeRatio < limit.negativeRatio,
              support.competingDigitRatio < limit.competingDigitRatio else { return nil }
        return digit
    }

    private struct Model {
        let count: Int
        let labels: [UInt8]
        let vectors: [[Float]]
        let norms: [[Float]]
        let thresholds: [Thresholds]

        init?(bundle: Bundle) {
            guard let url = bundle.url(forResource: "FingeringDigits", withExtension: "bin"),
                  let config = bundle.url(forResource: "FingeringDigits", withExtension: "json"),
                  let data = try? Data(contentsOf: url), data.count >= 16,
                  String(data: data.prefix(4), encoding: .ascii) == "MFD1",
                  let configuration = try? JSONDecoder().decode(Configuration.self, from: Data(contentsOf: config)),
                  configuration.limits.count == 10,
                  configuration.limits.allSatisfy({ $0.threshold > 0 && $0.threshold < 1 &&
                      $0.negativeRatio > 0 && $0.negativeRatio < 1 && $0.digitRatio > 0 && $0.digitRatio < 1 }) else { return nil }
            let header = data.withUnsafeBytes { raw in
                [4, 8, 12].map { Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0, as: UInt32.self))) }
            }
            let count = header[0]
            guard (1...50_000).contains(count), header[1] == 16, header[2] == 64,
                  data.count == 16 + count + count * 80 * 4 else { return nil }
            let labels = Array(data[16..<(16+count)])
            guard labels.allSatisfy({ $0 <= 10 }), Set(labels).count == 11 else { return nil }
            let vectors = data.withUnsafeBytes { raw in
                (0..<(count*80)).map { index in
                    Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 16+count+index*4, as: UInt32.self)))
                }
            }
            guard vectors.allSatisfy(\.isFinite) else { return nil }
            let matrices: [[Float]] = [(0,16),(16,64)].map { offset, width in
                var matrix: [Float] = []
                matrix.reserveCapacity(count*width)
                for row in 0..<count {
                    matrix.append(contentsOf: vectors[(row*80+offset)..<(row*80+offset+width)])
                }
                return matrix
            }
            self.count = count; self.labels = labels; self.vectors = matrices; self.thresholds = configuration.limits
            self.norms = [16,64].enumerated().map { level, width in
                (0..<count).map { row in
                    matrices[level].withUnsafeBufferPointer { buffer in
                        var sum: Float = 0
                        vDSP_svesq(buffer.baseAddress! + row*width, 1, &sum, vDSP_Length(width))
                        return sum
                    }
                }
            }
        }

        func distances(_ feature: [Float], level: Int) -> [Float] {
            let width = feature.count
            var products = [Float](repeating: 0, count: count)
            vectors[level].withUnsafeBufferPointer { matrix in
                feature.withUnsafeBufferPointer { input in
                    vDSP_mmul(matrix.baseAddress!, 1, input.baseAddress!, 1, &products, 1,
                              vDSP_Length(count), 1, vDSP_Length(width))
                }
            }
            let norm = feature.reduce(Float(0)) { $0+$1*$1 }
            var nearest = [Float](repeating: .infinity, count: 11)
            for index in 0..<count {
                let distance = max(0, norm + norms[level][index] - 2*products[index]) / Float(width)
                let label = Int(labels[index])
                nearest[label] = min(nearest[label], distance)
            }
            return nearest
        }
    }

    // Lazy initialization occurs on the controller's serial utility task. A
    // missing/corrupt model fails closed: original ink is always preserved.
    private static let model = Model(bundle: .main)
    static var isAvailable: Bool { model != nil }

    struct AppleSupport: Sendable {
        let distance: Float
        let negativeRatio: Float
        let competingDigitRatio: Float
    }

    /// Apple supplies the proposed character. This independent check only asks
    /// whether its geometry supports that digit relative to letters and marks.
    /// It is deliberately separate from the stricter standalone recognizer.
    static func appleSupport(for digit: Int, paths: [[CGPoint]]) -> AppleSupport? {
        guard (0...9).contains(digit), !Task.isCancelled, let model,
              (1...4).contains(paths.count) else { return nil }
        let points = paths.flatMap { $0 }
        guard (2...4096).contains(points.count), points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        let xs = points.map(\.x), ys = points.map(\.y)
        let width = xs.max()!-xs.min()!, height = ys.max()!-ys.min()!
        guard height > 0.001, width < height*1.5,
              digit == 1 ? width < height*0.65 : width > height*0.22 else { return nil }
        if digit == 0 && width > height*0.75 { return nil }
        if paths.count == 1 {
            let length = zip(points,points.dropFirst()).reduce(0.0) { $0+hypot($1.1.x-$1.0.x,$1.1.y-$1.0.y) }
            let span = hypot(points.last!.x-points[0].x,points.last!.y-points[0].y)
            guard length > span*1.08 else { return nil }
        }
        if digit == 7 {
            // A 7 turns from its cap into its stem near the top. An angle mark
            // such as > turns halfway down. Check new Apple proposals before
            // allowing their weaker template match to replace non-numeral ink.
            let right = xs.max()!-width*0.05, top = ys.min()!+height*0.20
            guard points.contains(where: { $0.x >= right && $0.y <= top }) else { return nil }
        }
        guard let coarse = feature(points,count:8), let fine = feature(points,count:32) else { return nil }
        let levels = [model.distances(coarse,level:0),model.distances(fine,level:1)]
        return .init(distance: levels.map { $0[digit] }.max()!,
                     negativeRatio: levels.map { $0[digit]/max($0[10],1e-9) }.max()!,
                     competingDigitRatio: levels.map { scores in
                         scores[digit]/max((0..<10).filter { $0 != digit }.map { scores[$0] }.min()!,1e-9)
                     }.max()!)
    }

    /// Explicit fingering input is a closed vocabulary. Do not apply open-set
    /// rejection: a straight 1 is valid here. Apple supplies a digit when it can;
    /// otherwise use the existing local trajectory model restricted to 1...5.
    static func fingerDigit(paths: [[CGPoint]], appleText: String? = nil) -> Int? {
        guard !Task.isCancelled, let model, (1...4).contains(paths.count) else { return nil }
        let points = paths.flatMap { $0 }
        guard (2...4096).contains(points.count), points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
              let coarse = feature(points, count: 8), let fine = feature(points, count: 32) else { return nil }
        if let text = appleText, let digit = ScoreFingeringBeautifier.digit(text), (1...5).contains(digit) { return digit }
        let a = model.distances(coarse, level: 0), b = model.distances(fine, level: 1)
        return (1...5).min { a[$0] + b[$0] < a[$1] + b[$1] }
    }

    static func recognize(paths: [[CGPoint]]) -> Int? {
        guard !Task.isCancelled, let model,
              !paths.isEmpty, paths.count <= 4 else { return nil }
        let points = paths.flatMap { $0 }
        guard (2...4096).contains(points.count), points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        let xs = points.map(\.x), ys = points.map(\.y)
        let width = xs.max()! - xs.min()!, height = ys.max()! - ys.min()!
        guard height > 0.001, width < height*1.5 else { return nil }
        if paths.count == 1 {
            let length = zip(points, points.dropFirst()).reduce(0.0) { $0 + hypot($1.1.x-$1.0.x, $1.1.y-$1.0.y) }
            let endDistance = hypot(points.last!.x-points[0].x, points.last!.y-points[0].y)
            guard length > endDistance*1.08 else { return nil }
        }
        guard let coarse = feature(points, count: 8), let detailed = feature(points, count: 32) else { return nil }
        let a = model.distances(coarse, level: 0), b = model.distances(detailed, level: 1)
        guard !Task.isCancelled,
              let digit = (0..<10).min(by: { a[$0] < a[$1] }),
              digit == (0..<10).min(by: { b[$0] < b[$1] }) else { return nil }
        let minX = xs.min()!, minY = ys.min()!
        guard digit == 1 ? width < height*0.65 : width > height*0.22 else { return nil }
        if digit == 0 && width > height*0.75 { return nil } // round noteheads / O
        if digit == 5 {
            // Look for the cap and descending left stem of 5. A smooth S or
            // zigzag rest may match digit examples but lacks these two parts.
            let top = points.filter { $0.y < minY+height*0.08 }.map(\.x)
            let left = points.filter { $0.x < minX+width*0.23 && $0.y < minY+height*0.55 }.map(\.y)
            guard top.count > 1, left.count > 1,
                  top.max()!-top.min()! > width*0.5,
                  left.max()!-left.min()! > height*0.28 else { return nil }
        }
        if digit == 9 && points.last!.x >= minX+width*0.8 { return nil } // q / straight descender
        if digit == 1 {
            // A recognizable upper hook distinguishes 1 from a barline, l/I or
            // a comma magnified by normalization. Ambiguous straight 1 stays ink.
            let y = stride(from: 1, to: coarse.count, by: 2).map { coarse[$0] }
            let tip = y.indices.min(by: { y[$0] < y[$1] })!
            let height = y.max()! - y.min()!
            guard height > 0, tip > 0, tip < 4,
                  y[0]-y[tip] > height*0.12,
                  coarse[tip*2]-coarse[0] > height*0.06,
                  y[7] > y[tip]+height*0.8 else { return nil }
        }
        let limits = model.thresholds[digit]
        for scores in [a,b] {
            // First: is this confidently a digit rather than another kind of mark?
            guard scores[digit] < limits.threshold,
                  scores[digit] < scores[10]*limits.negativeRatio else { return nil }
            // Second: which digit? Abstain when two numbers are too similar.
            let alternative = (0..<10).filter { $0 != digit }.map { scores[$0] }.min()!
            guard scores[digit] < alternative*limits.digitRatio else { return nil }
        }
        return digit
    }

    private static func feature(_ points: [CGPoint], count: Int) -> [Float]? {
        let xs = points.map(\.x), ys = points.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return nil }
        let scale = max(maxX-minX,maxY-minY)
        guard scale > 0.000001 else { return nil }
        var normalized: [CGPoint] = [], lengths: [CGFloat] = []
        for p in points {
            let p = CGPoint(x: (p.x-(minX+maxX)/2)/scale, y: (p.y-(minY+maxY)/2)/scale)
            if let last = normalized.last {
                let step = hypot(p.x-last.x,p.y-last.y)
                if step <= 1e-10 { continue }
                lengths.append(lengths.last!+step)
            } else { lengths.append(0) }
            normalized.append(p)
        }
        guard let length = lengths.last, length > 0 else { return nil }
        var segment = 1, result: [Float] = []
        result.reserveCapacity(count*2)
        for index in 0..<count {
            let target = length*CGFloat(index)/CGFloat(count-1)
            while segment < lengths.count-1 && lengths[segment] < target { segment += 1 }
            let t = (target-lengths[segment-1])/(lengths[segment]-lengths[segment-1])
            let a = normalized[segment-1], b = normalized[segment]
            result += [Float(a.x+(b.x-a.x)*t),Float(a.y+(b.y-a.y)*t)]
        }
        return result
    }
}
