#if DEBUG || MUSICFOCUS_HOMR
import Foundation
import CoreGraphics

/// Some contemporary scores write a meter as a large numeral plus a note icon
/// above the staff. That icon is a duration unit, not a sounded note.
enum ScoreRecognitionGraphicMeters {
    struct Reading: Codable { var index: Int; var count: Int; var unit: Double; var x: Double; var candidates: [String] }
    static func read(_ symbols: [ScoreRecognitionSymbol], raster: ScoreRecognitionRaster,
                     region: ScoreRecognitionRegion, diagnostics: Bool = false) throws -> [Reading] {
        guard let staff = region.staffs.first else { return [] }
        let u = staff.unit
        var found: [Reading] = []
        for (index,symbol) in symbols.enumerated() where symbol.midi != nil && symbol.position == "upper" {
            var ordinary = symbol; ordinary.rhythm = ordinary.rhythm.replacingOccurrences(of:"G",with:"")
            guard ordinary.duration>0,ordinary.duration<=1 else{continue}
            let point = region.sourcePoint(symbol.point)
            guard point.y < staff.y(at:point.x) - u*4 else { continue }
            var strings: [String] = []
            for width in [1.9,3.1] {
                let rect = CGRect(x:point.x-u*(width+0.2),y:point.y-u*4.5,width:u*width,height:u*6)
                strings += try ScoreRecognitionEndings.text(raster:raster,rect:rect,minimumHeight:u*2)
            }
            if diagnostics { print("METER OCR",index,symbol.rhythm,point,staff.y(at:point.x),u,strings) }
            for text in strings {
                let trimmed = text.trimmingCharacters(in:.whitespacesAndNewlines)
                if let n = Int(trimmed), (2...12).contains(n) {
                    found.append(.init(index:index,count:n,unit:ordinary.duration,x:point.x,candidates:strings));break
                }
            }
        }
        // The decoder occasionally attaches a detached meter icon to the next
        // chord and puts its attention inside the staff. A pitch outlier alone
        // is not enough: require a bar entrance, treble clef, contradictory
        // notehead coordinates, no ink at that pitch, and a large printed meter.
        let groups = ScoreRecognitionOpticalRhythm.groups(symbols)
        var barEntrance = true, treble = false
        for indices in groups {
            for i in indices where symbols[i].position == "upper" && symbols[i].rhythm.hasPrefix("clef_") {
                treble = symbols[i].rhythm == "clef_G2"
            }
            if indices.contains(where: { symbols[$0].rhythm.contains("barline") || symbols[$0].rhythm.hasPrefix("repeat") }) { barEntrance = true; continue }
            let alreadyRemoved = Set(found.map(\.index))
            guard indices.contains(where: { symbols[$0].duration > 0 && !alreadyRemoved.contains($0) }) else { continue }
            defer { barEntrance = false }
            let notes = indices.filter { !alreadyRemoved.contains($0) && symbols[$0].position == "upper" && symbols[$0].midi != nil && symbols[$0].duration > 0 }.sorted { symbols[$0].midi! > symbols[$1].midi! }
            guard barEntrance, treble, notes.count >= 2 else { continue }
            let i = notes[0], s = symbols[i], p = region.sourcePoint(s.point)
            guard !found.contains(where: { $0.index == i }), s.midi! - symbols[notes[1]].midi! >= 19,
                  s.duration <= 0.5, let letter = s.pitch.first, let step = "CDEFGAB".firstIndex(of: letter),
                  let octave = Int(s.pitch.dropFirst()) else { continue }
            let diatonic = octave * 7 + "CDEFGAB".distance(from: "CDEFGAB".startIndex, to: step)
            let headY = staff.y(at: p.x) - Double(diatonic - 34) * u / 2
            guard headY < staff.y(at: p.x) - u * 2.5, abs(p.y - headY) > u * 2 else { continue }
            var ink = 0, samples = 0
            for dy in stride(from: -u * 0.3, through: u * 0.3, by: 1) {
                for dx in stride(from: -u * 0.6, through: u * 0.6, by: 1) {
                    samples += 1; if raster.sample(x: p.x + dx, y: headY + dy) < 180 { ink += 1 }
                }
            }
            guard Double(ink) / Double(max(1, samples)) < 0.3 else { continue }
            let rect = CGRect(x: p.x - u * 5.5, y: staff.y(at: p.x) - u * 10, width: u * 2, height: u * 7)
            let strings = try ScoreRecognitionEndings.text(raster: raster, rect: rect, minimumHeight: u * 2)
            if let count = strings.compactMap({ Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }).first(where: { [6,9,12].contains($0) }) {
                found.append(.init(index: i, count: count, unit: s.duration, x: p.x, candidates: strings))
            }
        }
        return found
    }
    static func removingIcons(_ symbols: [ScoreRecognitionSymbol], readings: [Reading]) -> [ScoreRecognitionSymbol] {
        guard !readings.isEmpty else { return symbols }
        let removed=Set(readings.map(\.index))
        var groups:[[ScoreRecognitionSymbol]]=[], group:[ScoreRecognitionSymbol]=[], join=false
        for (index,symbol) in symbols.enumerated() {
            if symbol.rhythm == "chord" { join=true;continue }
            if !join { if !group.isEmpty {groups.append(group)};group=[] }
            if !removed.contains(index) {group.append(symbol)}
            join=false
        }
        if !group.isEmpty {groups.append(group)}
        return groups.flatMap { group in group.enumerated().flatMap { i,s in i == 0 ? [s] : [.init(rhythm:"chord"),s] } }
    }
}
#endif
