#if DEBUG || MUSICFOCUS_HOMR
import Foundation

/// Reuse detected staves and the original page's vertical connections. No extra
/// model, resizing, or forced fixed staff count. Ambiguous layouts can be chosen
/// manually; this stage says nothing about the accuracy of decoded notes.
enum ScoreRecognitionSystems {
    struct Boundary: Codable {var upper: Int; var lower: Int; var bridgeColumns: [Int]}
    static func printedLineSupport(_ staff: ScoreRecognitionStaff, raster: ScoreRecognitionRaster) -> Double {
        var hits = 0, total = 0
        for sample in staff.samples {
            let x = Int(sample.x), tolerance = max(1,Int(sample.unit*0.15))
            guard (0..<raster.width).contains(x) else { continue }
            for line in -2...2 {
                let y = Int(sample.y+Double(line)*sample.unit)
                total += 1
                if (-tolerance...tolerance).contains(where: { dy in
                    (0..<raster.height).contains(y+dy) && raster.pixels[(y+dy)*raster.width+x] < 190
                }) { hits += 1 }
            }
        }
        return total > 0 ? Double(hits)/Double(total) : 0
    }
    /// Only reconsider isolated, low-contrast staves on a page with several
    /// clearly printed staves. Protect small cue staves and visible opening clefs.
    static func possibleShowThrough(_ staffs: [ScoreRecognitionStaff], raster: ScoreRecognitionRaster,
                                    clefBounds: [CGRect]) throws -> Set<Int> {
        guard staffs.count >= 5 else { return [] }
        let support = staffs.map { printedLineSupport($0, raster: raster) }
        let strong = staffs.indices.filter { support[$0] >= 0.75 }
        guard strong.count >= 4 else { return [] }
        let units = strong.map { staffs[$0].unit }.sorted()
        let normalUnit = units[units.count / 2]
        var faint = Set(staffs.indices.filter { support[$0] <= 0.50 && staffs[$0].unit >= normalUnit * 0.82 })
        guard !faint.isEmpty else { return [] }
        for boundary in try boundaries(staffs: staffs, raster: raster) where !boundary.bridgeColumns.isEmpty {
            faint.remove(boundary.upper)
            faint.remove(boundary.lower)
        }
        return faint.filter { index in
            let staff = staffs[index], u = staff.unit
            // A tall treble clef can extend into an adjacent faint track.
            // Use the complete glyph and exclude short key-signature fragments
            // in the same segmentation channel.
            let hasFrontClef = clefBounds.contains { box in
                guard box.midX < Double(raster.width) / 3, box.height >= u * 1.65,
                      box.width >= u * 0.45 else { return false }
                let offset = abs(box.midY - staff.y(at:box.midX))
                return offset <= u * 1.5 && !staffs.contains { abs(box.midY - $0.y(at:box.midX)) < offset }
            }
            return !hasFrontClef
        }
    }

    /// A second segmentation can veto an isolated staff only if the other
    /// staves match in order, height and distance between the printed lines.
    static func confirmsShowThrough(original: [ScoreRecognitionStaff], retry: [ScoreRecognitionStaff],
                                    candidates: Set<Int>, raster: ScoreRecognitionRaster) throws -> Bool {
        guard !candidates.isEmpty, retry.count < original.count else { return false }
        var next = 0
        for (index, old) in original.enumerated() {
            if next < retry.count {
                let new = retry[next]
                if abs(new.center - old.center) < old.unit * 1.6,
                   abs(new.unit - old.unit) < old.unit * 0.25 {
                    next += 1
                    continue
                }
            }
            if !candidates.contains(index) { return false }
        }
        guard next == retry.count else { return false }
        // A weaker single staff may be a genuine solo or cue in a mixed
        // score. Only accept the recovery on a page of connected systems.
        return try groups(staffs: retry, raster: raster).allSatisfy { $0.count >= 2 }
    }

    static func boundaries(staffs: [ScoreRecognitionStaff], raster: ScoreRecognitionRaster) throws -> [Boundary] {
        guard staffs.count > 1 else { return [] }
        // A photographed page edge can cross every system. Reject only outer
        // columns whose narrow neighborhood continues through almost the whole
        // page, including the spaces between systems.
        let typicalUnit = staffs.map(\.unit).sorted()[staffs.count/2]
        var borders = Set<Int>()
        for x in Int(Double(raster.width)*0.92)..<Int(Double(raster.width)*0.97) {
            let ys = Array(stride(from: 0, to: raster.height, by: 8))
            let dark = ys.filter { y in
                (-Int(typicalUnit)...Int(typicalUnit)).contains { dx in
                    x+dx >= 0 && x+dx < raster.width && raster.pixels[y*raster.width+x+dx] < 190
                }
            }.count
            if Double(dark)/Double(ys.count) > 0.8 { borders.insert(x) }
        }
        var output: [Boundary] = []
        for i in 1..<staffs.count {
            try Task.checkCancellation()
            let a = staffs[i-1], b = staffs[i], u = min(a.unit,b.unit)
            var hits: [Int] = []
            let x0 = Int(Double(raster.width)*0.08), x1 = Int(Double(raster.width)*0.97)
            for x in x0..<x1 where !borders.contains(x) {
                let top = Int(a.y(at: Double(x))+a.unit*2), bottom = Int(b.y(at: Double(x))-b.unit*2)
                guard top >= 0, bottom < raster.height, bottom-top > Int(u) else { continue }
                var count = 0, gap = 0, longestGap = 0
                for y in top...bottom {
                    if (-2...2).contains(where: { dx in raster.pixels[y*raster.width+x+dx] < 190 }) {
                        count += 1; gap = 0
                    } else { gap += 1; longestGap = max(longestGap,gap) }
                }
                if Double(count)/Double(bottom-top+1) > 0.87 && Double(longestGap) < u*0.65 {
                    if let last = hits.last, x-last < Int(u) { continue }
                    hits.append(x)
                }
            }
            output.append(.init(upper:i-1,lower:i,bridgeColumns:hits))
        }
        return output
    }
    static func groups(staffs: [ScoreRecognitionStaff], raster: ScoreRecognitionRaster) throws -> [[Int]] {
        guard !staffs.isEmpty else { throw ScoreAuditionError.invalid }
        let boundaries = try boundaries(staffs: staffs, raster: raster)
        var result = [[0]]
        for b in boundaries {
            if !b.bridgeColumns.isEmpty { result[result.count-1].append(b.lower) }
            else { result.append([b.lower]) }
        }
        // A faint staff from the reverse side of a photographed sheet may be
        // found by segmentation but has neither connections nor printed lines.
        // Do not silently add that ghost as a solo system or discard its music.
        guard result.filter({$0.count==1}).allSatisfy({printedLineSupport(staffs[$0[0]],raster:raster)>=0.35}) else {
            throw ScoreRecognitionFailure("部分谱线过淡或有透印，自动分组不够明确。请使用更清晰的谱页，或手动选择版式。", "Faint or show-through staff lines make automatic grouping uncertain. Try a clearer page or choose the layout manually.")
        }
        guard result.allSatisfy({ $0.count <= 8 }) else {
            throw ScoreRecognitionFailure("谱表分组不够明确，请手动选择版式。", "The staff grouping is ambiguous. Please choose the layout manually.")
        }
        return result
    }
}
#endif
