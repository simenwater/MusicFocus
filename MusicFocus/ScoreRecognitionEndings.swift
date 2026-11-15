#if DEBUG || MUSICFOCUS_HOMR
import Foundation
import Vision

/// Confirm ending labels against long bracket rules in the original PDF layer.
/// Fingering digits alone never create a repeat. The model may miss brackets
/// continued onto another system, so keep start/stop events independent.
enum ScoreRecognitionEndings {
    struct Bracket: Codable { var left: Double; var right: Double; var y: Double; var starts: Bool; var ends: Bool; var number: Int?; var candidates: [String]? = nil }
    static func brackets(raster: ScoreRecognitionRaster, region: ScoreRecognitionRegion, includeUnconfirmed: Bool = false) throws -> [Bracket] {
        guard let staff = region.staffs.first else { return [] }
        let unit = staff.unit, lo = max(0, Int(region.rect.minX)), hi = min(raster.width - 1, Int(region.rect.maxX))
        guard hi > lo else { return [] }
        func dark(_ x: Double, _ y: Double) -> Bool {
            (-4...4).contains { raster.sample(x: x, y: y + Double($0)) < 220 }
        }
        var found: [Bracket] = []
        for offset in stride(from: max(region.rect.minY - staff.center - unit * 3, -14 * unit), through: -3 * unit, by: 1.0) {
            try Task.checkCancellation()
            var start: Int?, last = lo, hits = 0
            func finish() {
                guard let start, Double(last - start) >= unit * 8, Double(hits) / Double(max(1, last - start)) > 0.8 else { return }
                let x0 = Double(start), x1 = Double(last)
                if found.contains(where: { abs($0.y - offset) < unit * 0.5 && min($0.right,x1) - max($0.left,x0) > unit * 4 }) { return }
                func hook(_ x: Double) -> Bool {
                    let n = max(3, Int(unit * 1.3))
                    let hits = (3...n).filter { dy in
                        (-2...2).contains { dx in dark(x + Double(dx), staff.y(at: x) + offset + Double(dy)) }
                    }.count
                    return Double(hits) / Double(max(1,n - 2)) > 0.7
                }
                found.append(.init(left: x0, right: x1, y: offset, starts: hook(x0), ends: hook(x1), number: nil))
            }
            for x in lo...hi {
                if dark(Double(x), staff.y(at: Double(x)) + offset) {
                    if start == nil { start = x; hits = 0 }
                    last = x; hits += 1
                } else if start != nil, Double(x - last) > max(3,unit * 0.3) { finish(); start = nil }
            }
            finish()
        }
        // Trace each rule through the mild skew/curve of a scanned page.
        // The seed projection above deliberately tolerates a few raster pixels.
        func ink(_ x: Int, _ y: Int) -> Bool {
            x >= 0 && x < raster.width && y >= 0 && y < raster.height && raster.pixels[y * raster.width + x] < 220
        }
        var traced: [Bracket] = []
        for candidate in found {
            let sx = Int(candidate.left) + 10, sy = Int(staff.y(at: Double(sx)) + candidate.y)
            guard let delta = [0,-1,1,-2,2,-3,3,-4,4,-5,5].first(where: { ink(sx, sy + $0) }) else { continue }
            func walk(_ direction: Int) -> (Int,Int) {
                var x = sx, y = sy + delta, end = (x,y), gap = 0
                while x + direction >= lo && x + direction <= hi {
                    x += direction
                    if let dy = [0,-1,1,-2,2].first(where: { ink(x, y + $0) }) {
                        y += dy; end = (x,y); gap = 0
                    } else { gap += 1; if gap > 4 { break } }
                }
                return end
            }
            let l = walk(-1), r = walk(1)
            guard Double(r.0 - l.0) >= unit * 8 else { continue }
            if traced.contains(where: { abs($0.left - Double(l.0)) < unit && abs($0.right - Double(r.0)) < unit && abs($0.y - Double(l.1)) < unit }) { continue }
            func hook(_ point: (Int,Int)) -> Bool {
                let n = max(4,Int(unit * 1.3))
                return Double((3...n).filter { dy in (-3...3).contains { dx in ink(point.0 + dx, point.1 + dy) } }.count) / Double(n-2) > 0.65
            }
            traced.append(.init(left: Double(l.0), right: Double(r.0), y: Double(l.1), starts: hook(l), ends: hook(r), number: nil))
        }
        found = traced
        for i in found.indices where found[i].starts {
            let b = found[i]
            let rect = CGRect(x: b.left + unit * 0.25, y: b.y + unit * 0.35, width: unit * 4, height: unit * 2.5)
            let strings = try text(raster: raster, rect: rect)
            found[i].candidates = strings
            for value in strings {
                let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: "")
                // Serif 1 is also reported as capital I by Vision; the verified
                // bracket and paired repeat keep this separate from fingering text.
                if let number = Int(normalized) ?? (["I", "l", "|"].contains(normalized) ? 1 : nil), (1...8).contains(number) { found[i].number = number; break }
            }
        }
        return found.filter { includeUnconfirmed || $0.number != nil || (!$0.starts && $0.ends && $0.right - $0.left > (staff.samples.last!.x - staff.samples.first!.x) * 0.75) }
    }
    static func text(raster: ScoreRecognitionRaster, rect: CGRect, minimumHeight: Double = 0) throws -> [String] {
        let r = rect.integral.intersection(CGRect(x: 0,y: 0,width: raster.width,height: raster.height))
        guard r.width > 3, r.height > 3 else { return [] }
        let w = Int(r.width), h = Int(r.height), x = Int(r.minX), y = Int(r.minY)
        var pixels = [UInt8](repeating: 255, count: w * h)
        for j in 0..<h { pixels.replaceSubrange(j*w..<(j+1)*w, with: raster.pixels[(y+j)*raster.width+x..<(y+j)*raster.width+x+w]) }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData), let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [], provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return [] }
        var input = image, imageScale = 1.0
        // Single printed digits need generous white margins for Vision's text
        // detector. This is a temporary image, never a change to the score.
        if w < 160, h < 160, let c = CGContext(data: nil, width: w*4+64, height: h*4+64, bitsPerComponent: 8,
            bytesPerRow: w*4+64, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) {
            c.setFillColor(gray: 1, alpha: 1); c.fill(CGRect(x: 0,y: 0,width: w*4+64,height: h*4+64))
            c.interpolationQuality = .high; c.draw(image, in: CGRect(x: 32,y: 32,width: w*4,height: h*4))
            input = c.makeImage() ?? image
            if input.width != image.width { imageScale = 4 }
        }
        var strings: [String] = []
        for level: VNRequestTextRecognitionLevel in w < 160 ? [.accurate, .fast] : [.accurate] {
            let request = VNRecognizeTextRequest(); request.recognitionLevel = level; request.usesLanguageCorrection = false
            request.recognitionLanguages = ["en-US"]; request.minimumTextHeight = 0.03
            try VNImageRequestHandler(cgImage: input).perform([request])
            strings += (request.results ?? []).filter { $0.boundingBox.height * Double(input.height) / imageScale >= minimumHeight }
                .flatMap { $0.topCandidates(3).filter { $0.confidence > 0.35 }.map(\.string) }
        }
        return strings
    }
    static func beginsSection(raster: ScoreRecognitionRaster, region: ScoreRecognitionRegion, symbols: [ScoreRecognitionSymbol]) throws -> Bool {
        let prefix = symbols.prefix { $0.duration == 0 }
        guard prefix.contains(where: { $0.rhythm.hasPrefix("timeSignature") }),
              prefix.contains(where: { $0.rhythm.hasPrefix("clef_") }) else { return false }
        let staff = region.staffs[0], u = staff.unit
        let words = try text(raster: raster, rect: CGRect(x: region.rect.minX, y: max(0,staff.center - 14*u), width: region.rect.width * 0.55, height: 11*u))
            .flatMap { $0.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init) }
        return !Set(words).isDisjoint(with: ["largo","lento","adagio","andante","andantino","moderato","allegretto","allegro","vivace","presto","prestissimo","maestoso","grave"])
    }
    static func marks(raster: ScoreRecognitionRaster, region: ScoreRecognitionRegion, sequence: ScoreRecognitionTimeline.Result, detected: [Bracket]? = nil) throws -> [ScoreRecognitionRepeats.Mark] {
        let brackets = try detected ?? brackets(raster: raster, region: region), unit = region.staffs[0].unit
        let positions = sequence.notes.filter { $0.decoration == nil }.map { (measure: $0.measure, x: region.sourcePoint($0.point).x) }
        var result: [ScoreRecognitionRepeats.Mark] = []
        for b in brackets {
            if let number = b.number, let measure = positions.filter({ $0.x >= b.left - unit }).min(by: { $0.x < $1.x })?.measure {
                result.append(.init(after: measure - 1, kind: "voltaStart", numbers: [number]))
            }
            if b.ends, let measure = positions.filter({ $0.x <= b.right + unit }).max(by: { $0.x < $1.x })?.measure {
                result.append(.init(after: measure, kind: "voltaStop"))
            }
            // Open-ended second brackets still terminate at their printed right edge.
            if !b.ends, b.number == 2, let measure = positions.filter({ $0.x <= b.right + unit }).max(by: { $0.x < $1.x })?.measure {
                result.append(.init(after: measure, kind: "voltaDiscontinue"))
            }
        }
        return result
    }
}
#endif
