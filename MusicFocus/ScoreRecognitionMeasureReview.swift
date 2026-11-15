#if DEBUG && MUSICFOCUS_HOMR
import Foundation
import CoreGraphics

/// Second-pass rhythm checks use one printed measure at a time. Keep the original
/// symbols (including coordinates, pitches, slurs and repeats) as the authority.
enum ScoreRecognitionMeasureReview {
    typealias Symbol = ScoreRecognitionSymbol
    typealias Sequence = ScoreRecognitionTimeline.Result
    struct Observation: Codable {
        var measure: Int
        var reads = 0
        var change = "none"
        var seconds = 0.0
    }
    private struct Delay {
        var held: Double
        var entry: Double
        var sustained: [ScoreRecognizedNote]
        var anchors: [ScoreRecognizedNote]
    }
    private static func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.0001 }

    static func spans(_ source: [Symbol]) -> [Range<Int>] {
        var out: [Range<Int>] = [], start = 0
        func append(_ end: Int) {
            if start < end, source[start..<end].contains(where: { $0.duration > 0 }) { out.append(start..<end) }
        }
        for i in source.indices where source[i].rhythm.contains("barline") || source[i].rhythm.hasPrefix("repeat") {
            append(i); start = i + 1
        }
        append(source.count)
        return out
    }

    private static func delayedEntry(_ notes: [ScoreRecognizedNote], length: Double, expected: Double, tokens: ArraySlice<Symbol>) -> Delay? {
        let gap = length - expected, entry = expected - gap
        guard entry >= 0.5, entry <= 2, gap > entry, near(2 * entry, (2 * entry).rounded()),
              tokens.allSatisfy({ !$0.rhythm.hasPrefix("rest_") || $0.duration > 0 }),
              tokens.filter({ $0.rhythm.hasPrefix("rest_") }).map(\.duration).reduce(0,+) < gap - 0.0001,
              !notes.contains(where: { $0.decoration != nil || ($0.beat >= entry - 0.0001 && $0.beat < expected - 0.0001) }) else { return nil }
        let first = notes.filter { near($0.beat,0) }, next = notes.filter { near($0.beat,expected) }
        guard first.contains(where: { near($0.duration,expected) }),
              !notes.contains(where: { $0.beat < expected - 0.0001 && $0.beat + $0.duration > expected + 0.0001 }) else { return nil }
        for anchor in first where near(anchor.duration,entry) {
            guard let nextAnchor = next.first(where: { $0.staff == anchor.staff && $0.voice == anchor.voice && $0.midi == anchor.midi && near($0.duration,entry) }) else { continue }
            for long in first where long.staff != anchor.staff && near(long.duration,gap) {
                if let second = next.first(where: { $0.staff == long.staff && $0.voice == long.voice && near($0.duration,gap) }) {
                    return Delay(held:expected, entry:entry, sustained:[long,second], anchors:[anchor,nextAnchor])
                }
            }
        }
        return nil
    }

    private static func croppedRead(_ source: ScoreRecognitionRaster, region: ScoreRecognitionRegion, left: Double, right: Double,
                                    factor: Double, models: ScoreRecognitionModels) throws -> [Symbol] {
        var rect = region.rect
        rect.origin.x += left / region.scale
        rect.size.width = (right - left) / region.scale
        let scale = region.scale * factor
        let offset = floor((256 - rect.height * scale) / 2)
        let crop = ScoreRecognitionRegion(staffs:region.staffs, rect:rect, scale:scale, offsetY:offset)
        return try models.recognize(crop.tensorPixels(source)).map { raw in
            var s = raw
            s.point = CGPoint(x:left + s.point.x / factor, y:region.offsetY + (s.point.y - offset) / factor)
            return s
        }
    }

    // Durations and staff at the two printed noteheads must survive two crops;
    // the cropped decoder may not see the key signature or the opening clefs.
    private static func confirms(_ delay: Delay, in symbols: [Symbol]) -> Bool {
        let groups = ScoreRecognitionOpticalRhythm.groups(symbols)
        var previous = -1
        for (long, anchor) in zip(delay.sustained, delay.anchors) {
            guard let group = groups.indices.first(where: { index in
                guard index > previous else { return false }
                let chord = groups[index].map { symbols[$0] }
                // A held note may have diffuse horizontal attention. Its simultaneous,
                // shorter note on the opposite staff pins the chord to the printed column.
                return chord.contains { s in
                    s.midi == anchor.midi && (s.position.hasPrefix("lower") ? 2 : 1) == anchor.staff
                        && near(s.duration,anchor.duration) && abs(s.point.x-anchor.point.x) <= 20 && abs(s.point.y-anchor.point.y) <= 22
                } && chord.contains { s in
                    s.midi != nil && (s.position.hasPrefix("lower") ? 2 : 1) == long.staff
                        && near(s.duration,long.duration) && abs(s.point.y-long.point.y) <= 22
                }
            }) else { return false }
            previous = group
        }
        return true
    }
    static func regularRunOutlier(_ symbols: ArraySlice<Symbol>) -> Bool {
        let byVoice = Dictionary(grouping:symbols.filter { $0.midi != nil }, by:\.position)
        for notes in byVoice.values where notes.count >= 5 {
            for i in 2..<(notes.count-2) {
                let window = Array(notes[(i-2)...(i+2)])
                let durations = window.map(\.duration), typical = durations[0]
                guard near(typical,0.25), [1,3,4].allSatisfy({ near(durations[$0],typical) }),
                      !near(durations[2],typical) else { continue }
                let dx = zip(window.dropFirst(),window).map { $0.point.x-$1.point.x }
                if let lo=dx.min(),let hi=dx.max(), lo>3, hi<1.65*lo { return true }
            }
        }
        return false
    }
    static func revisedDurations(_ tokens: [Symbol], readings: [[Symbol]]) -> [Symbol]? {
        guard readings.count == 2 else { return nil }
        let indices = tokens.indices.filter { tokens[$0].duration > 0 }
        var result = tokens, changed = false
        let timed = readings.map { $0.filter { $0.duration > 0 } }
        guard timed.allSatisfy({ $0.count == indices.count }) else { return nil }
        for (j,i) in indices.enumerated() {
            let a = timed[0][j], b = timed[1][j], s = tokens[i]
            guard a.rhythm == b.rhythm, [a,b].allSatisfy({
                $0.position == s.position && $0.pitch == s.pitch && $0.lift == s.lift
                    && abs($0.point.x - s.point.x) <= 16 && abs($0.point.y - s.point.y) <= 20
            }) else { return nil }
            if a.rhythm != s.rhythm {
                guard s.midi != nil, s.duration <= 0.5, a.duration <= 0.5 else { return nil }
                result[i].rhythm = a.rhythm; changed = true
            }
        }
        return changed ? result : nil
    }

    static func run(_ initial: Sequence, symbols: [Symbol], region: ScoreRecognitionRegion, raster: ScoreRecognitionRaster,
                    models: ScoreRecognitionModels, options: ScoreOrnamentOptions, context: ScoreRecognitionPitchContext,
                    observe: (Observation) -> Void) throws -> Sequence {
        let ranges = spans(symbols), bars = initial.bars
        guard region.isGrandStaff, bars.count == ranges.count, bars.count >= 2 else { return initial }
        let byMeasure = Dictionary(grouping:initial.notes, by:\.measure)
        var result = initial, offset = 0.0
        for (i,bar) in bars.enumerated() {
            try Task.checkCancellation()
            let range = ranges[i], tokens = symbols[range]
            let adjacent = bars.indices.filter { $0 != i && abs($0-i) <= 2 }.map { bars[$0].duration }
            let common = adjacent.filter { d in adjacent.allSatisfy({ near($0,d) }) }.first
            // A stable neighbor on the same system can also corroborate a sustained pitch.
            let notes = (byMeasure[bar.measure] ?? []).map { n in var n=n; n.beat -= bar.start; return n }
            let targets = Set(adjacent.filter { $0 + 0.5 < bar.duration })
            let delays = targets.compactMap { delayedEntry(notes,length:bar.duration,expected:$0,tokens:tokens) }
            let delay = delays.count == 1 ? delays[0] : nil
            let run = common.map { !near($0,bar.duration) && regularRunOutlier(tokens) } ?? false
            guard delay != nil || run else { continue }
            guard !tokens.contains(where: { $0.rhythm.hasPrefix("timeSignature") || $0.isGrace || ScoreRecognitionOrnaments.ornament($0) != nil }) else { continue }
            let xs = tokens.filter { $0.duration > 0 }.map { $0.point.x }
            guard let xmin=xs.min(),let xmax=xs.max() else { continue }
            let left = max(0,range.lowerBound > 0 ? min(symbols[range.lowerBound-1].point.x,xmin-7) : xmin-15)
            let right = min(region.rect.width*region.scale,range.upperBound < symbols.count ? max(symbols[range.upperBound].point.x,xmax+7) : xmax+15)
            guard right-left > 20, right-left < 0.88 * region.rect.width*region.scale else { continue }
            var log = Observation(measure:bar.measure)
            let start = ProcessInfo.processInfo.systemUptime
            defer { log.seconds = ProcessInfo.processInfo.systemUptime - start; observe(log) }
            var readings: [[Symbol]] = []
            do {
                for factor in [1.0,0.88] {
                    try Task.checkCancellation(); log.reads += 1
                    readings.append(try croppedRead(raster,region:region,left:left,right:right,factor:factor,models:models))
                }
            } catch is CancellationError { throw CancellationError() }
            catch { continue }
            var revised: [ScoreRecognizedNote], duration: Double
            if let delay, readings.allSatisfy({ confirms(delay,in:$0) }) {
                duration = delay.held
                revised = notes.map { n in var n=n; if n.beat >= delay.held-0.0001 { n.beat -= delay.held-delay.entry }; return n }
                guard revised.allSatisfy({ $0.beat >= 0 && $0.beat + $0.duration <= duration+0.0001 }) else { continue }
                log.change = "voice-entry"
            } else if run, let expected=common, let updated = revisedDurations(Array(tokens),readings:readings) {
                // Reconvert the whole symbol sequence so earlier clefs, accidentals and meter
                // remain in scope. Only timings in this measure can leave this function.
                var stream = symbols, localContext = context
                stream.replaceSubrange(range,with:updated)
                guard let trial = try? ScoreRecognitionTimeline.convert(stream,options:options,context:&localContext),
                      trial.bars.count == bars.count, near(trial.bars[i].duration,expected) else { continue }
                revised = trial.notes.filter { $0.measure == bar.measure }.map { n in var n=n; n.beat -= trial.bars[i].start; return n }
                duration=expected; log.change = "rhythm"
            } else { continue }
            let delta = duration-bar.duration
            let oldStart = bar.start + offset
            guard let insertion = result.notes.firstIndex(where: { $0.measure == bar.measure }) else { continue }
            result.notes.removeAll { $0.measure == bar.measure }
            for j in result.notes.indices where result.notes[j].measure > bar.measure { result.notes[j].beat += delta }
            let shifted = revised.map { n in var n=n; n.beat += oldStart; return n }
            result.notes.insert(contentsOf:shifted,at:insertion)
            result.bars[i].duration = duration
            for j in result.bars.indices where j > i { result.bars[j].start += delta }
            result.duration += delta; offset += delta
        }
        return result
    }
}
#endif
