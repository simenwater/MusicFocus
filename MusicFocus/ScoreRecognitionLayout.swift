#if DEBUG || MUSICFOCUS_HOMR
import Foundation
import CoreGraphics

struct ScoreRecognitionFailure: LocalizedError {
    var message: String
    var errorDescription: String? { message }
    init(_ zh: String, _ en: String) { message = ScoreAuditionText.value(zh, en) }
}

/// Independent raster of the original PDF. CGPDFPage draws page content only;
/// annotation dictionaries and MusicFocus's editable overlay are never rendered here.
struct ScoreRecognitionRaster {
    let width: Int
    let height: Int
    let pixels: [UInt8]
    let pixelToPDF: CGAffineTransform
    static func read(_ url: URL, page number: Int, ignoreColoredMarks: Bool = false) throws -> Self {
        guard let doc = CGPDFDocument(url as CFURL), let page = doc.page(at: number) else { throw ScoreAuditionError.invalid }
        let box = page.getBoxRect(.cropBox)
        let rotated = abs(page.rotationAngle) % 180 == 90
        let ratio = rotated ? box.width / box.height : box.height / box.width
        guard ratio.isFinite, (0.3...3).contains(ratio) else { throw ScoreRecognitionFailure("这一页的长宽比例暂不支持。", "This page aspect ratio is not supported yet.") }
        let width = 1920, height = Int((1920 * ratio).rounded())
        var pixels = [UInt8](repeating: 255, count: width * height)
        let displayWidth = rotated ? box.height : box.width
        let displayHeight = rotated ? box.width : box.height
        // CGPDFPage's drawing transform centers small pages without enlarging
        // them. Apply the raster scale explicitly, after crop/rotation mapping.
        let transform = page.getDrawingTransform(.cropBox, rect: CGRect(x: 0, y: 0, width: displayWidth, height: displayHeight), rotate: 0, preserveAspectRatio: true)
            .concatenating(CGAffineTransform(scaleX: CGFloat(width) / displayWidth, y: CGFloat(height) / displayHeight))
        if ignoreColoredMarks {
            // Only the temporary recognition image changes. Black notation stays;
            // saturated ink is suppressed. Covered/missing print cannot be recovered.
            var rgba = [UInt8](repeating: 255, count: width * height * 4)
            try rgba.withUnsafeMutableBytes { raw in
                guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { throw ScoreAuditionError.invalid }
                context.concatenate(transform); context.drawPDFPage(page)
            }
            for i in pixels.indices {
                let r = Int(rgba[i * 4]), g = Int(rgba[i * 4 + 1]), b = Int(rgba[i * 4 + 2])
                let high = max(r, g, b), low = min(r, g, b)
                pixels[i] = high - low >= 50 && high >= 100 ? UInt8(high) : UInt8((r * 299 + g * 587 + b * 114) / 1000)
            }
        } else {
        try pixels.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { throw ScoreAuditionError.invalid }
            context.concatenate(transform); context.drawPDFPage(page)
        }
        }
        let topToBottom = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(height))
        return .init(width: width, height: height, pixels: pixels, pixelToPDF: topToBottom.concatenating(transform.inverted()))
    }
    func sample(x: Double, y: Double) -> Float {
        guard x >= 0, y >= 0, x < Double(width - 1), y < Double(height - 1) else { return 255 }
        let ix = Int(x), iy = Int(y), dx = Float(x - Double(ix)), dy = Float(y - Double(iy)), i = iy * width + ix
        return (Float(pixels[i]) * (1 - dx) + Float(pixels[i + 1]) * dx) * (1 - dy)
            + (Float(pixels[i + width]) * (1 - dx) + Float(pixels[i + width + 1]) * dx) * dy
    }

    /// Close one-pixel printing gaps on the full-resolution recognition copy.
    /// Source PDF content and annotation appearances are never changed.
    func closingSmallGaps(radius: Int) -> Self {
        guard (1...2).contains(radius), width > radius*2, height > radius*2 else { return self }
        func pass(_ input: [UInt8], horizontal: Bool, minimum: Bool) -> [UInt8] {
            var output = input
            for y in radius..<(height-radius) { for x in radius..<(width-radius) {
                let index = y*width+x
                var value = input[index]
                for offset in -radius...radius {
                    let sample = input[index + (horizontal ? offset : offset*width)]
                    value = minimum ? min(value,sample) : max(value,sample)
                }
                output[index] = value
            } }
            return output
        }
        let dilated = pass(pass(pixels,horizontal:true,minimum:true),horizontal:false,minimum:true)
        let closed = pass(pass(dilated,horizontal:true,minimum:false),horizontal:false,minimum:false)
        return .init(width:width,height:height,pixels:closed,pixelToPDF:pixelToPDF)
    }
}

struct ScoreRecognitionStaff {
    struct Sample { var x: Double; var y: Double; var unit: Double }
    var samples: [Sample]
    var center: Double { samples.map(\.y).reduce(0, +) / Double(samples.count) }
    var unit: Double { samples.map(\.unit).reduce(0, +) / Double(samples.count) }
    func y(at x: Double) -> Double {
        let sorted = samples
        guard let first = sorted.first, let last = sorted.last else { return 0 }
        if x <= first.x { return first.y }; if x >= last.x { return last.y }
        for i in 1..<sorted.count where sorted[i].x >= x {
            let a = sorted[i - 1], b = sorted[i], t = (x - a.x) / (b.x - a.x)
            return a.y + (b.y - a.y) * t
        }
        return center
    }
}

struct ScoreRecognitionRegion {
    let staffs: [ScoreRecognitionStaff]
    let rect: CGRect
    let scale: Double
    let offsetY: Double
    var isGrandStaff: Bool { staffs.count == 2 }
    /// Undo the local flattening of gently bent scanned staff lines.
    func sourcePoint(_ point: CGPoint) -> CGPoint {
        let x = rect.minX + point.x / scale
        let y = rect.minY + (point.y - offsetY) / scale
        let first = staffs[0], last = staffs[staffs.count - 1]
        let t = first.center == last.center ? 0 : min(1, max(0, (y - first.center) / (last.center - first.center)))
        let shift = (first.y(at: x) - first.center) * (1 - t) + (last.y(at: x) - last.center) * t
        return CGPoint(x: x, y: y + shift)
    }
    func tensorPixels(_ raster: ScoreRecognitionRaster) -> [Float] {
        var output = [Float](repeating: (1 - 0.7931) / 0.1738, count: 256 * 1280)
        let contentWidth = min(1280, Int(rect.width * scale)), contentHeight = min(256, Int(rect.height * scale))
        let first = staffs[0], last = staffs[staffs.count - 1]
        let firstCenter = first.center, lastCenter = last.center
        for x in 0..<contentWidth {
            let sx = rect.minX + (Double(x) + 0.5) / scale
            let firstShift = first.y(at: sx) - firstCenter, lastShift = last.y(at: sx) - lastCenter
            for y in 0..<contentHeight {
                let cy = y + Int(offsetY)
                guard (0..<256).contains(cy) else { continue }
                let sy = rect.minY + (Double(cy) + 0.5 - offsetY) / scale
                let t = firstCenter == lastCenter ? 0 : min(1, max(0, (sy - firstCenter) / (lastCenter - firstCenter)))
                let value = raster.sample(x: sx, y: sy + firstShift * (1 - t) + lastShift * t)
                output[cy * 1280 + x] = (value / 255 - 0.7931) / 0.1738
            }
        }
        return output
    }
}

enum ScoreRecognitionLayout: Int, CaseIterable, Identifiable, Sendable {
    case automatic = 0, grandStaff = 2, singleStaff = 1, organ = 3, fourStaves = 4
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .automatic: return ScoreAuditionText.value("自动分组（可混合谱表）", "Automatic · mixed staff systems")
        case .fourStaves: return ScoreAuditionText.value("四行谱", "Four staves")
        case .grandStaff: return ScoreAuditionText.value("双行谱（钢琴／手风琴）", "Two staves · piano / accordion")
        case .singleStaff: return ScoreAuditionText.value("单行谱", "Single staff")
        case .organ: return ScoreAuditionText.value("三行谱（双手＋踏板）", "Three staves · hands + pedal")
        }
    }
    static func staffs(mask: [UInt8], width: Int, height: Int) throws -> [ScoreRecognitionStaff] {
        guard mask.count == width * height else { throw ScoreAuditionError.invalid }
        var tracks: [ScoreRecognitionStaff] = []
        for x in stride(from: Int(Double(width) * 0.15), to: Int(Double(width) * 0.9), by: 100) {
            try Task.checkCancellation()
            var runs: [[Int]] = []
            for y in 0..<height {
                var count = 0
                for xx in (x - 45)..<(x + 45) { count += Int(mask[y * width + xx]) }
                if count > 31 {
                    if let last = runs.last?.last, y - last <= 2 { runs[runs.count - 1].append(y) }
                    else { runs.append([y]) }
                }
            }
            let lines = runs.map { Double($0.reduce(0, +)) / Double($0.count) }
            var i = 0
            while i + 4 < lines.count {
                let a = Array(lines[i...i + 4]), gaps = (1...4).map { a[$0] - a[$0 - 1] }
                let unit = gaps.reduce(0, +) / 4, center = a.reduce(0, +) / 5
                if unit > 5, unit < 40, gaps.allSatisfy({ abs($0 - unit) < unit * 0.22 }) {
                    let observation = ScoreRecognitionStaff.Sample(x: Double(x), y: center, unit: unit)
                    if let index = tracks.firstIndex(where: { abs($0.center - center) < unit * 2.5 }) { tracks[index].samples.append(observation) }
                    else { tracks.append(.init(samples: [observation])) }
                    i += 5
                } else { i += 1 }
            }
        }
        let result = removeSparseBeamTracks(tracks.filter { $0.samples.count >= 3 }).sorted { $0.center < $1.center }
        guard !result.isEmpty, result.count <= 40 else { throw ScoreRecognitionFailure("没有找到清楚的五线谱，请选正文页；简谱、封面和手写谱暂不支持。", "No clear staff lines found. Choose a printed music page; numbered notation, covers and handwritten scores are not supported yet.") }
        return result
    }
    /// Dense beams can form a few false five-line observations. Reject only
    /// sparse, much smaller tracks when full-width staves establish the scale.
    /// A consistently observed small/cue staff remains a real staff.
    static func removeSparseBeamTracks(_ tracks: [ScoreRecognitionStaff]) -> [ScoreRecognitionStaff] {
        let support = tracks.map { $0.samples.count }.max() ?? 0
        let reliable = tracks.filter { $0.samples.count >= max(6, support * 2 / 3) }.map(\.unit).sorted()
        guard reliable.count >= 4 else { return tracks }
        let typical = reliable[reliable.count / 2]
        return tracks.filter { !($0.samples.count * 3 <= support && $0.unit < typical * 0.6) }
    }
    func regions(staffs: [ScoreRecognitionStaff], mask: [UInt8], width: Int, height: Int, raster: ScoreRecognitionRaster? = nil) throws -> [[ScoreRecognitionRegion]] {
        let systems: [[Int]]
        if self == .automatic {
            guard let raster else { throw ScoreAuditionError.invalid }
            systems = try ScoreRecognitionSystems.groups(staffs: staffs, raster: raster)
        } else {
            guard staffs.count % rawValue == 0 else { throw ScoreRecognitionFailure("检测到的谱表数量与所选版式不符，请尝试自动分组或手动选择每组谱表数量。", "The staff count does not match this layout. Try automatic grouping or choose the number of staves per system.") }
            systems = stride(from: 0, to: staffs.count, by: rawValue).map { Array($0..<($0 + rawValue)) }
        }
        var result: [[ScoreRecognitionRegion]] = []
        for system in systems {
            let groups = stride(from: 0, to: system.count, by: 2).map { Array(system[$0..<min($0 + 2, system.count)]) }
            var row: [ScoreRecognitionRegion] = []
            for indices in groups {
                let selected = indices.map { staffs[$0] }, first = selected[0], last = selected[selected.count - 1]
                let unit = selected.map(\.unit).reduce(0, +) / Double(selected.count)
                var left = width, right = 0
                for x in 0..<width {
                    var hits = 0
                    for staff in selected {
                        let cy = Int(staff.y(at: Double(x))), lo = max(0, cy - Int(unit * 2.4)), hi = min(height - 1, cy + Int(unit * 2.4))
                        if lo <= hi { for y in lo...hi { hits += Int(mask[y * width + x]) } }
                    }
                    if hits >= selected.count * 4 { left = min(left, x); right = max(right, x) }
                }
                guard right - left > width / 3 else { throw ScoreRecognitionFailure("谱行不完整，请尝试更清楚的 PDF。", "The staff appears incomplete. Try a clearer PDF.") }
                let topNeighbor = indices[0] > 0 ? staffs[indices[0] - 1].center + staffs[indices[0] - 1].unit * 2 : 0
                let next = indices.last! + 1
                let bottomNeighbor = next < staffs.count ? staffs[next].center - staffs[next].unit * 2 : Double(height)
                // HOMR measures the mean spacing across all lines, including the
                // inter-staff gap in a grand staff. Using one staff's spacing
                // crops too tightly and changes the model's notation scale.
                let regionUnit = selected.count == 2
                    ? (last.center + last.unit * 2 - first.center + first.unit * 2) / 9
                    : unit
                let x0 = max(0, Double(left) - regionUnit * 2), x1 = min(Double(width), Double(right) + regionUnit * 2)
                let y0 = max(topNeighbor, first.center - first.unit * 2 - regionUnit * 4)
                let y1 = min(bottomNeighbor, last.center + last.unit * 2 + regionUnit * 4)
                guard y1 > y0 else { throw ScoreAuditionError.invalid }
                let rect = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
                let scale = min(1280 / rect.width, 256 / rect.height)
                row.append(.init(staffs: selected, rect: rect, scale: scale, offsetY: floor((256 - rect.height * scale) / 2)))
            }
            result.append(row)
        }
        return result
    }
}
#endif
