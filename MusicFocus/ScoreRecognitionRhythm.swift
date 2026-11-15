#if DEBUG || MUSICFOCUS_HOMR
import Foundation

/// Conservative post-decode validation. Fingering numerals can make HOMR read
/// ordinary beamed notes as tuplets. Never flatten a rhythm just for regularity:
/// a complete independent voice and multiple simultaneous anchors must agree.
enum ScoreRecognitionRhythm {
    struct Result { var symbols: [ScoreRecognitionSymbol]; var corrected: Int }
    private struct Event {
        var group: Int
        var symbols: [ScoreRecognitionSymbol]
        var duration: Double { symbols[0].duration }
    }
    private static let replacements = ["note_12": "note_8", "note_24": "note_16",
                                       "note_48": "note_32", "note_96": "note_64",
                                       "rest_12": "rest_8", "rest_24": "rest_16", "rest_48": "rest_32", "rest_96": "rest_64"]
    private static let epsilon = 0.000001

    static func validate(_ symbols: [ScoreRecognitionSymbol]) -> Result {
        var output: [ScoreRecognitionSymbol] = [], bar: [ScoreRecognitionSymbol] = [], corrected = 0
        var bars: [(symbols: [ScoreRecognitionSymbol], end: ScoreRecognitionSymbol)] = []
        for symbol in symbols {
            if symbol.rhythm.contains("barline") || symbol.rhythm.hasPrefix("repeat") {
                bars.append((bar, symbol)); bar = []
            } else { bar.append(symbol) }
        }
        for (index, item) in bars.enumerated() {
            // Sparse accompaniment needs independent evidence from BOTH adjacent
            // complete bars. A single long bass note alone cannot justify repair.
            var neighboringLength: Double?
            if index > 0, index + 1 < bars.count,
               let before = ordinaryBarLength(bars[index - 1].symbols),
               let after = ordinaryBarLength(bars[index + 1].symbols), abs(before - after) < epsilon {
                neighboringLength = before
            }
            let rhythm = validateBar(item.symbols, neighboringLength: neighboringLength)
            let result = separateOverlappingVoices(rhythm.symbols)
            output += result.symbols; corrected += rhythm.corrected + result.corrected
            output.append(item.end)
        }
        // A cropped or unfinished bar does not establish its intended duration.
        output += bar
        return .init(symbols: output, corrected: corrected)
    }

    private static func events(_ symbols: [ScoreRecognitionSymbol]) -> (groups: [[ScoreRecognitionSymbol]], voices: [String: [Event]])? {
        guard !symbols.contains(where: { $0.isGrace || $0.rhythm.hasSuffix("m") }) else { return nil }
        var groups: [[ScoreRecognitionSymbol]] = [], join = false
        for symbol in symbols {
            if symbol.rhythm == "chord" { join = true; continue }
            if join, !groups.isEmpty { groups[groups.count - 1].append(symbol) }
            else { groups.append([symbol]) }
            join = false
        }
        var voices: [String: [Event]] = [:]
        for (index, group) in groups.enumerated() {
            for (voice, chord) in Dictionary(grouping: group.filter { $0.duration > 0 }, by: \.position) {
                // Mixed-length chords require a more general voice reconstruction.
                guard chord.allSatisfy({ abs($0.duration - chord[0].duration) < epsilon }) else { return nil }
                voices[voice, default: []].append(.init(group: index, symbols: chord))
            }
        }
        guard (2...4).contains(voices.count), voices.keys.allSatisfy({ ["upper", "upper2", "lower", "lower2"].contains($0) }) else { return nil }
        return (groups, voices)
    }

    private static func ordinaryBarLength(_ symbols: [ScoreRecognitionSymbol]) -> Double? {
        guard let (_, voices) = events(symbols), let first = voices.values.first else { return nil }
        let length = first.reduce(0) { $0 + $1.duration }
        var sharedStarts: [Int: Double] = [:]
        for voice in voices.values {
            guard voice.first?.group == first.first?.group,
                  voice.allSatisfy({ $0.symbols.allSatisfy(isOrdinary) }),
                  abs(voice.reduce(0, { $0 + $1.duration }) - length) < epsilon else { return nil }
            var beat = 0.0
            for event in voice {
                if let other = sharedStarts[event.group], abs(other - beat) >= epsilon { return nil }
                sharedStarts[event.group] = beat; beat += event.duration
            }
        }
        return length
    }

    private static func validateBar(_ symbols: [ScoreRecognitionSymbol], neighboringLength: Double?) -> Result {
        let unchanged = Result(symbols: symbols, corrected: 0)
        guard let (groups, voices) = events(symbols) else { return unchanged }
        let candidates = voices.keys.filter { voice in
            voices[voice]!.contains { $0.symbols.contains { replacements[$0.rhythm] != nil } }
        }
        guard candidates.count == 1, let candidate = candidates.first else { return unchanged }
        let suspect = voices[candidate]!
        guard suspect.count >= 4,
              suspect.allSatisfy({ $0.symbols.allSatisfy { isOrdinary($0) || replacements[$0.rhythm] != nil } }) else { return unchanged }
        let changedCount = suspect.flatMap(\.symbols).filter { replacements[$0.rhythm] != nil }.count
        guard changedCount >= 4 else { return unchanged }
        let repairedLength = suspect.reduce(0) { $0 + repaired($1.symbols[0]).duration }
        guard let anchor = voices.filter({ $0.key != candidate }).sorted(by: {
            $0.value.count == $1.value.count ? $0.key < $1.key : $0.value.count > $1.value.count
        }).map(\.value).first(where: {
            $0.count >= 2 && $0.first?.group == suspect.first?.group && $0.allSatisfy { $0.symbols.allSatisfy(isOrdinary) }
            && abs($0.reduce(0) { $0 + $1.duration } - repairedLength) < epsilon
        }) else { return unchanged }
        let referenceLength = anchor.reduce(0) { $0 + $1.duration }
        let originalLength = suspect.reduce(0) { $0 + $1.duration }
        guard referenceLength >= 1, referenceLength <= 12,
              abs(originalLength - referenceLength) > 0.125,
              abs(repairedLength - referenceLength) < epsilon else { return unchanged }

        func starts(_ events: [Event], repair: Bool) -> [Int: Double] {
            var beat = 0.0, result: [Int: Double] = [:]
            for event in events {
                result[event.group] = beat
                beat += repair ? repaired(event.symbols[0]).duration : event.duration
            }
            return result
        }
        let proposed = starts(suspect, repair: true), original = starts(suspect, repair: false)
        let reliable = starts(anchor, repair: false)
        let shared = proposed.keys.filter { reliable[$0] != nil }
        // At least three explicitly simultaneous groups, spanning half a bar,
        // must match exactly after repair and disagree in the original decode.
        guard shared.allSatisfy({ abs(proposed[$0]! - reliable[$0]!) < epsilon }) else { return unchanged }
        let denseEvidence = shared.count >= 3
            && (shared.map { proposed[$0]! }.max() ?? 0) >= referenceLength * 0.5
            && shared.contains(where: { abs(original[$0]! - reliable[$0]!) > 0.125 })
        // Four beamed eighths are sometimes decoded as four triplet eighths.
        // With only two half-note bass attacks, require a closed, even-length
        // tail, its exact shared start, and matching complete neighboring bars.
        let tail = suspect.drop(while: { $0.symbols.allSatisfy(isOrdinary) })
        let sparseTailEvidence = neighboringLength.map { abs($0 - referenceLength) < epsilon } == true
            && anchor.count == 2 && shared.count == 2
            && tail.count >= 4 && tail.count.isMultiple(of: 2) && !tail.count.isMultiple(of: 3)
            && tail.allSatisfy { $0.symbols.allSatisfy { $0.rhythm == "note_12" && $0.midi != nil } }
            && tail.first?.group == anchor.last?.group
            && shared.allSatisfy { abs(original[$0]! - reliable[$0]!) < epsilon }
            && (tail.first.flatMap { proposed[$0.group] } ?? 0) >= referenceLength * 0.5
        guard denseEvidence || sparseTailEvidence else { return unchanged }
        var onset = reliable
        for (index, beat) in proposed { onset[index] = beat }
        for (voice, events) in voices where voice != candidate {
            guard events.first?.group == suspect.first?.group,
                  events.allSatisfy({ $0.symbols.allSatisfy(isOrdinary) }),
                  events.reduce(0, { $0 + $1.duration }) <= referenceLength + epsilon else { return unchanged }
            for (index, beat) in starts(events, repair: false) {
                if let existing = onset[index], abs(existing - beat) > epsilon { return unchanged }
                onset[index] = beat
            }
        }
        let ordered = onset.keys.sorted()
        guard zip(ordered, ordered.dropFirst()).allSatisfy({ onset[$0.0]! <= onset[$0.1]! + epsilon }) else { return unchanged }
        guard zip(ordered, ordered.dropFirst()).allSatisfy({
            abs(onset[$0.0]! - onset[$0.1]!) >= epsilon || $0.1 == $0.0 + 1
        }) else { return unchanged }

        // A missed chord separator between the hands must not insert a delay.
        // Only merge adjacent timed groups whose independently accumulated
        // onsets are now exactly equal. Keep untimed clefs/directions in order.
        var result: [ScoreRecognitionSymbol] = [], previousBeat: Double?
        var canJoin = false
        for (index, group) in groups.enumerated() {
            let beat = onset[index]
            let merge = canJoin && beat != nil && previousBeat != nil && abs(beat! - previousBeat!) < epsilon
            for (i, symbol) in group.enumerated() {
                if i > 0 || merge { result.append(.init(rhythm: "chord")) }
                result.append(symbol.position == candidate ? repaired(symbol) : symbol)
            }
            if let beat { previousBeat = beat; canJoin = true }
            else { canJoin = false }
        }
        return .init(symbols: result, corrected: changedCount)
    }

    /// Some polyphonic engraving uses overlapping whole notes in one staff.
    /// Split a mislabeled voice only when TWO complete independent voices agree
    /// at every one of its attacks, and all note endings fit their shared bar.
    private static func separateOverlappingVoices(_ symbols: [ScoreRecognitionSymbol]) -> Result {
        let unchanged = Result(symbols: symbols, corrected: 0)
        guard !symbols.contains(where: { $0.isGrace }) else { return unchanged }
        var groups: [[Int]] = [], join = false
        for (i, symbol) in symbols.enumerated() {
            if symbol.rhythm == "chord" { join = true; continue }
            if join, !groups.isEmpty { groups[groups.count - 1].append(i) } else { groups.append([i]) }
            join = false
        }
        struct Voice { var starts: [Int: Double]; var length: Double; var events: [[Int]] }
        var voices: [String: Voice] = [:]
        for (g, group) in groups.enumerated() {
            for (voice, indices) in Dictionary(grouping: group.filter { symbols[$0].duration > 0 }, by: { symbols[$0].position }) {
                guard indices.allSatisfy({ isOrdinary(symbols[$0]) && abs(symbols[$0].duration - symbols[indices[0]].duration) < epsilon }) else { return unchanged }
                var value = voices[voice] ?? Voice(starts: [:], length: 0, events: [])
                value.starts[g] = value.length; value.length += symbols[indices[0]].duration; value.events.append(indices); voices[voice] = value
            }
        }
        guard (3...4).contains(voices.count) else { return unchanged }
        for candidate in voices.keys.sorted() {
            let voice = voices[candidate]!
            guard voice.events.count >= 2, voice.events.allSatisfy({ symbols[$0[0]].duration >= 1 }) else { continue }
            let references = voices.filter { key, value in key != candidate && value.starts.count >= 3 && value.length < voice.length - epsilon }
            for key in references.keys.sorted() {
                let a = references[key]!
                guard let otherKey = references.keys.sorted().first(where: { $0 != key && abs(references[$0]!.length - a.length) < epsilon }) else { continue }
                let b = references[otherKey]!
                let shared = a.starts.keys.filter { b.starts[$0] != nil }
                guard shared.count >= 3, shared.allSatisfy({ abs(a.starts[$0]! - b.starts[$0]!) < epsilon }),
                      (shared.map { a.starts[$0]! }.max() ?? 0) >= a.length / 2,
                      voice.starts.keys.allSatisfy({ a.starts[$0] != nil && b.starts[$0] != nil }) else { continue }
                var ends: [Double] = [], assignments: [Int: Int] = [:], changed = 0
                for group in voice.starts.keys.sorted() {
                    let start = a.starts[group]!, indices = groups[group].filter { symbols[$0].position == candidate && symbols[$0].duration > 0 }
                    guard let index = indices.first else { continue }
                    let end = start + symbols[index].duration
                    if end > a.length + epsilon { assignments = [:]; break }
                    let lane = ends.firstIndex(where: { $0 <= start + epsilon }) ?? ends.count
                    if lane == ends.count { ends.append(end) } else { ends[lane] = end }
                    for i in indices { assignments[i] = lane; if lane > 0 { changed += 1 } }
                }
                guard changed > 0, !assignments.isEmpty, ends.count <= 2 else { continue }
                var result = symbols
                for (i, lane) in assignments where lane > 0 { result[i].position = candidate + ".overlap" }
                return .init(symbols: result, corrected: changed)
            }
        }
        return unchanged
    }

    private static func repaired(_ symbol: ScoreRecognitionSymbol) -> ScoreRecognitionSymbol {
        var result = symbol
        if let replacement = replacements[symbol.rhythm] { result.rhythm = replacement }
        return result
    }
    private static func isOrdinary(_ symbol: ScoreRecognitionSymbol) -> Bool {
        guard symbol.duration > 0,
              let text = symbol.rhythm.split(separator: "_").last,
              let denominator = Int(text.prefix(while: \.isNumber)) else { return false }
        return denominator == 0 || (denominator > 0 && denominator & (denominator - 1) == 0)
    }
}
#endif
