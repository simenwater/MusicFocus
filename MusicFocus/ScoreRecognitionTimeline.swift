#if DEBUG || MUSICFOCUS_HOMR
import Foundation
import CoreGraphics

struct ScoreRecognitionSymbol: Codable, Sendable {
    var rhythm: String
    var pitch: String = "_"
    var lift: String = "_"
    var position: String = "upper"
    var articulation: String = "_"
    var slur: String = "_"
    var point: CGPoint = .zero
    var endingNumbers: [Int]? = nil
    var isGrace: Bool { rhythm.hasPrefix("note_") && rhythm.contains("G") }
    var duration: Double {
        guard rhythm.hasPrefix("note_") || rhythm.hasPrefix("rest_"), !rhythm.contains("G"), !rhythm.hasSuffix("m") else { return 0 }
        let value = String(rhythm.split(separator: "_").last ?? "")
        let digits = value.prefix(while: \.isNumber)
        guard let n = Double(digits) else { return 0 }
        let base = n == 0 ? 4 : 4 / n
        let dots = value.filter { $0 == "." }.count
        return base * (dots == 2 ? 1.75 : dots == 1 ? 1.5 : 1)
    }
    var midi: Int? {
        guard rhythm.hasPrefix("note_"), let letter = pitch.first, let octave = Int(pitch.dropFirst()),
              let semitone = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11][String(letter)] else { return nil }
        // HOMR's lift describes the sounding alteration, including key signature.
        // Applying the key signature again here would double-sharpen/flatten notes.
        let alteration = ["#": 1, "##": 2, "b": -1, "bb": -2, "N": 0, "_": 0][lift]
        guard let alteration else { return nil }
        let value = 12 * (octave + 1) + semitone + alteration
        return (0...127).contains(value) ? value : nil
    }
}

struct ScoreRecognizedNote: Codable, Sendable {
    var midi: Int
    var beat: Double
    var duration: Double
    var page = 1
    var staff: Int
    var measure: Int
    var point: CGPoint
    var decoration: String? = nil
    var voice: String? = nil
    var slur: String? = nil
    /// Length of the final attack in a tie chain, used for the release tail.
    var tieRelease: Double? = nil
    var sourceMeasure: Int? = nil
    var sourceBeat: Double? = nil
}

enum ScoreRecognitionTimeline {
    struct Result { var notes: [ScoreRecognizedNote]; var duration: Double; var measures: Int; var skippedGrace: Int; var correctedRhythms: Int; var bars: [ScoreAuditionPackage.Bar]; var repeats: [ScoreRecognitionRepeats.Mark] }
    /// Timing follows HOMR 0.7.1 GroupClock: chord tokens join simultaneous
    /// events; the next group waits for its own voices, then advances to the
    /// earliest sounding endpoint. Ported from homr/music_xml_generator.py (AGPL).
    static func convert(_ symbols: [ScoreRecognitionSymbol], options: ScoreOrnamentOptions = .init()) throws -> Result {
        var context = ScoreRecognitionPitchContext()
        return try convert(symbols, options: options, context: &context)
    }
    static func convert(_ symbols: [ScoreRecognitionSymbol], options: ScoreOrnamentOptions,
                        context: inout ScoreRecognitionPitchContext) throws -> Result {
        guard options.tempo.isFinite, (20...300).contains(options.tempo) else { throw ScoreAuditionError.invalid }
        guard !symbols.contains(where: { $0.rhythm.hasPrefix("rest_") && $0.rhythm.hasSuffix("m") }) else {
            throw ScoreRecognitionFailure("这一页包含连续多小节休止，目前还不能可靠还原，请改选其他页。", "Multi-measure rests are not supported reliably yet. Select another page.")
        }
        let validated = ScoreRecognitionRhythm.validate(symbols)
        var groups: [[ScoreRecognitionSymbol]] = [], join = false
        for symbol in validated.symbols {
            if symbol.rhythm == "chord" { join = true; continue }
            if join, !groups.isEmpty { groups[groups.count - 1].append(symbol) }
            else { groups.append([symbol]) }
            join = false
        }
        context.startMeasure()
        var pendingGrace: [String: [[ScoreRecognitionSymbol]]] = [:], skippedGrace = 0
        var notes: [ScoreRecognizedNote] = [], base = 0.0, time = 0.0, maxEnd = 0.0
        var voiceFree: [String: Double] = [:], sounding: [Double] = [], measure = 1, hasEvents = false
        var bars: [ScoreAuditionPackage.Bar] = []
        var repeats: [ScoreRecognitionRepeats.Mark] = []
        func closeMeasure() {
            guard hasEvents else { return }
            bars.append(.init(measure: measure, start: base, duration: max(time, maxEnd)))
            base += max(time, maxEnd); time = 0; maxEnd = 0; voiceFree = [:]; sounding = []; measure += 1; hasEvents = false
        }
        for group in groups {
            for symbol in group where symbol.rhythm.hasPrefix("volta") {
                let boundary = symbol.rhythm == "voltaStart" ? measure - 1 : (hasEvents ? measure : measure - 1)
                repeats.append(.init(after: boundary, kind: symbol.rhythm, numbers: symbol.endingNumbers))
            }
            if group.contains(where: { $0.rhythm.contains("barline") || $0.rhythm.hasPrefix("repeat") }) {
                skippedGrace += pendingGrace.values.flatMap { $0 }.flatMap { $0 }.count
                pendingGrace = [:]; context.startMeasure(); closeMeasure()
                for rhythm in Set(group.map(\.rhythm)).sorted() where rhythm.hasPrefix("repeat") || rhythm == "bolddoublebarline" {
                    repeats.append(.init(after: measure - 1, kind: rhythm))
                }
                continue
            }
            for symbol in group where symbol.rhythm.hasPrefix("keySignature_") { context.observe(symbol) }
            if options.enabled {
                for (position, grace) in Dictionary(grouping: group.filter { $0.isGrace && $0.midi != nil }, by: \.position) {
                    pendingGrace[position, default: []].append(grace)
                }
            }
            // Decoder placeholders are not rests. They must not insert a silent
            // extra beat after the last playable note of a bar.
            let timed = group.filter { $0.duration > 0 && (!$0.rhythm.hasPrefix("note_") || $0.midi != nil) }
            guard !timed.isEmpty else { continue }
            hasEvents = true
            let free = timed.compactMap { voiceFree[$0.position] }.max() ?? 0
            time = max(time, free); sounding.removeAll { $0 <= time + 1e-8 }
            var graceDelay: [String: Double] = [:]
            for position in Set(timed.map(\.position)) {
                let grace = pendingGrace.removeValue(forKey: position) ?? []
                let hosts = timed.filter { $0.position == position && $0.midi != nil }
                guard let shortest = hosts.map(\.duration).min(), !grace.isEmpty else {
                    skippedGrace += grace.flatMap { $0 }.count; continue
                }
                let budget = min(shortest * 0.5, options.step * Double(grace.count))
                guard grace.count <= 8, budget / Double(grace.count) * 60 / options.tempo >= 0.02 else {
                    skippedGrace += grace.flatMap { $0 }.count; continue
                }
                graceDelay[position] = budget
                for (index, chord) in grace.enumerated() {
                    for symbol in chord {
                        context.observe(symbol)
                        guard let pitch = symbol.midi, symbol.point.x.isFinite, symbol.point.y.isFinite else { throw ScoreAuditionError.invalid }
                        notes.append(.init(midi: pitch, beat: base + time + Double(index) * budget / Double(grace.count),
                                           duration: budget / Double(grace.count), staff: position.hasPrefix("lower") ? 2 : 1,
                                           measure: measure, point: symbol.point, decoration: "grace"))
                    }
                }
            }
            // Resolve simultaneous accidentals before expanding ornament neighbors.
            for symbol in timed { context.observe(symbol) }
            for symbol in timed {
                let end = time + symbol.duration
                maxEnd = max(maxEnd, end); sounding.append(end)
                if let pitch = symbol.midi {
                    guard symbol.point.x.isFinite, symbol.point.y.isFinite else { throw ScoreAuditionError.invalid }
                    let delay = graceDelay[symbol.position] ?? 0
                    let note = ScoreRecognizedNote(midi: pitch, beat: base + time + delay, duration: symbol.duration - delay,
                                                   staff: symbol.position.hasPrefix("lower") ? 2 : 1, measure: measure, point: symbol.point,
                                                   voice: symbol.position, slur: symbol.slur)
                    notes += ScoreRecognitionOrnaments.expand(note, symbol: symbol, context: context, options: options)
                }
            }
            for position in Set(timed.map(\.position)) {
                voiceFree[position] = time + timed.filter { $0.position == position }.map(\.duration).min()!
            }
            if let next = sounding.filter({ $0 > time + 1e-8 }).min() { time = next }
            sounding.removeAll { $0 <= time + 1e-8 }
        }
        closeMeasure()
        guard base.isFinite, base <= 4000 else { throw ScoreAuditionError.invalid }
        skippedGrace += pendingGrace.values.flatMap { $0 }.flatMap { $0 }.count
        return .init(notes: notes, duration: base, measures: max(1, measure - 1), skippedGrace: skippedGrace, correctedRhythms: validated.corrected, bars: bars, repeats: repeats)
    }
}

/// HOMR uses one label for ties and slurs. Like its MusicXML converter, only
/// adjacent same-pitch events in the same voice qualify. Merge individual
/// chord members for audio; the unmerged notes remain the score-follow cues.
enum ScoreRecognitionTies {
    static func merge(_ notes: [ScoreRecognizedNote]) -> [ScoreRecognizedNote] {
        let ordered = notes.sorted { $0.beat < $1.beat }
        var result: [ScoreRecognizedNote] = []
        var previous: [String: (beat: Double, members: [Int])] = [:]
        var sourceEnds: [Int: Double] = [:]
        for group in Dictionary(grouping: ordered, by: \.beat).sorted(by: { $0.key < $1.key }) {
            for (voice, chord) in Dictionary(grouping: group.value, by: { "\($0.staff):\($0.voice ?? "unknown")" }) {
                let before = previous[voice]?.members ?? []
                var members: [Int] = [], used: Set<Int> = []
                for note in chord {
                    if note.voice != nil, note.decoration == nil, note.slur?.contains("Stop") == true,
                       let index = before.first(where: {
                           !used.contains($0) && result[$0].midi == note.midi && result[$0].decoration == nil
                           && result[$0].slur?.contains("Start") == true
                           && (sourceEnds[$0] == nil || note.sourceBeat == nil || note.sourceBeat! >= sourceEnds[$0]! - 0.0001)
                           && abs(result[$0].beat + result[$0].duration - note.beat) < 0.0001
                       }) {
                        result[index].duration += note.duration
                        result[index].tieRelease = note.duration
                        result[index].slur = note.slur
                        sourceEnds[index] = note.sourceBeat.map { $0 + note.duration }
                        used.insert(index); members.append(index)
                    } else {
                        sourceEnds[result.count] = note.sourceBeat.map { $0 + note.duration }
                        members.append(result.count); result.append(note)
                    }
                }
                previous[voice] = (group.key, members)
            }
        }
        return result.sorted { $0.beat < $1.beat }
    }
}

enum ScoreRecognitionRepeats {
    struct Mark: Codable, Sendable { var after: Int; var kind: String; var numbers: [Int]? = nil }
    struct Plan { var order: [Int]; var omitted: Bool }
    struct Ending { var start: Int; var end: Int; var numbers: [Int]?; var closed: Bool }
    /// The same two-pass rule as DaSegno, but only for complete, non-overlapping
    /// spans. HOMR's consecutive closed/open brackets represent ordinary 1/2
    /// endings. Explicit OCR numbers override that structural interpretation.
    static func plan(count: Int, marks: [Mark], startsAtBeginning: Bool = false) -> Plan {
        let printed = count > 0 ? Array(1...count) : []
        func fallback() -> Plan { .init(order: printed, omitted: !marks.isEmpty) }
        guard count > 0, !marks.contains(where: { $0.kind == "volta" }) else { return fallback() }
        var endings: [Ending] = [], open: Mark?
        for mark in marks where mark.kind.hasPrefix("volta") {
            if mark.kind == "voltaStart" {
                guard open == nil, mark.after >= 0, mark.after < count else { return fallback() }
                open = mark
            } else {
                guard let first = open, mark.after > first.after, mark.after <= count else { return fallback() }
                endings.append(.init(start: first.after + 1, end: mark.after, numbers: first.numbers, closed: mark.kind == "voltaStop"))
                open = nil
            }
        }
        guard open == nil else { return fallback() }
        var firstEndings: [Int: Ending] = [:], pairedEnds: Set<Int> = []
        var e = 0
        while e < endings.count {
            guard e + 1 < endings.count else { return fallback() }
            let first = endings[e], second = endings[e + 1]
            guard first.closed, second.start == first.end + 1,
                  first.numbers == nil || first.numbers == [1], second.numbers == nil || second.numbers == [2],
                  marks.contains(where: { $0.after == first.end && $0.kind == "repeatEnd" }) else { return fallback() }
            firstEndings[first.end] = first; pairedEnds.insert(first.end); e += 2
        }
        var start: Int?, implicit: Int? = startsAtBeginning ? 1 : nil
        var ranges: [Int: (start: Int, end: Int)] = [:], omitted = false
        for mark in marks {
            guard (0...count).contains(mark.after) else { omitted = true; continue }
            if mark.kind == "repeatEnd" || mark.kind == "repeatEndStart" {
                if let first = start ?? implicit, first <= mark.after {
                    let end = firstEndings[mark.after].map { $0.start - 1 } ?? mark.after
                    guard end >= first - 1 else { return fallback() }
                    ranges[mark.after] = (first, end); pairedEnds.remove(mark.after)
                } else { omitted = true }
                start = nil; implicit = nil
            }
            if mark.kind == "bolddoublebarline" { implicit = startsAtBeginning ? mark.after + 1 : nil }
            if mark.kind == "sectionStart", start == nil { implicit = mark.after + 1 }
            if mark.kind == "repeatStart" || mark.kind == "repeatEndStart" {
                if start != nil { return fallback() }
                start = mark.after + 1
            }
        }
        guard pairedEnds.isEmpty else { return fallback() }
        if let start, start <= count { omitted = true }
        var order: [Int] = []
        for bar in printed {
            order.append(bar)
            if let range = ranges[bar], range.start <= range.end { order += Array(range.start...range.end) }
        }
        return .init(order: order, omitted: omitted)
    }
    static func expand(notes: [ScoreRecognizedNote], bars: [ScoreAuditionPackage.Bar], order: [Int],
                       secondsPerBeat: Double) -> (notes: [ScoreRecognizedNote], bars: [ScoreAuditionPackage.Bar], beats: Double) {
        let grouped = Dictionary(grouping: notes, by: \.measure)
        var result: [ScoreRecognizedNote] = [], timeline: [ScoreAuditionPackage.Bar] = [], time = 0.0
        for (index, original) in order.enumerated() {
            let source = bars[original - 1], measure = index + 1
            for var note in grouped[original] ?? [] {
                note.sourceMeasure = original; note.measure = measure
                note.sourceBeat = note.beat
                note.beat += (time - source.start) / secondsPerBeat
                result.append(note)
            }
            timeline.append(.init(measure: measure, start: time, duration: source.duration))
            time += source.duration
        }
        return (result, timeline, time / secondsPerBeat)
    }
}
#endif
