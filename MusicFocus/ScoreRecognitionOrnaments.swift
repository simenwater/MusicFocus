#if DEBUG || MUSICFOCUS_HOMR
import Foundation

/// Audition rules, not an authoritative performance edition. HOMR does not
/// encode grace slashes, ornament accidentals, or every historical variant.
struct ScoreOrnamentOptions: Sendable {
    var enabled = true
    var trillFromUpper = true
    var tempo = 80.0
    // Eight subdivisions per quarter at ordinary tempi; cap speed at fast tempi.
    var step: Double { max(0.125, tempo * 0.06 / 60) }
}

struct ScoreRecognitionPitchContext: Sendable {
    var keys: [Int: Int] = [:]
    private var accidentals: [Int: [String: Int]] = [:]
    mutating func startMeasure() { accidentals = [:] }
    mutating func observe(_ symbol: ScoreRecognitionSymbol) {
        let staff = symbol.position.hasPrefix("lower") ? 2 : 1
        if symbol.rhythm.hasPrefix("keySignature_"),
           let fifths = Int(symbol.rhythm.dropFirst("keySignature_".count)), (-7...7).contains(fifths) {
            // HOMR exports key signatures for the whole part, not per staff.
            keys = [1: fifths, 2: fifths]; accidentals = [:]
        } else if let midi = symbol.midi, let natural = Self.natural(symbol.pitch) {
            // HOMR lift is already resolved, including the key signature.
            accidentals[staff, default: [:]][symbol.pitch] = midi - natural
        }
    }
    static func natural(_ pitch: String) -> Int? {
        guard let letter = pitch.first, let octave = Int(pitch.dropFirst()),
              let pc = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11][String(letter)] else { return nil }
        return (octave + 1) * 12 + pc
    }
    func neighbor(of symbol: ScoreRecognitionSymbol, direction: Int) -> Int? {
        let letters = Array("CDEFGAB")
        guard let letter = symbol.pitch.first, let index = letters.firstIndex(of: letter),
              let octave = Int(symbol.pitch.dropFirst()) else { return nil }
        let absolute = octave * 7 + index + direction
        guard absolute >= 0 else { return nil }
        let nextLetter = letters[absolute % 7], pitch = "\(nextLetter)\(absolute / 7)"
        guard let natural = Self.natural(pitch) else { return nil }
        let staff = symbol.position.hasPrefix("lower") ? 2 : 1, fifths = keys[staff] ?? 0
        var alteration = 0
        if fifths > 0, Array("FCGDAEB").prefix(fifths).contains(nextLetter) { alteration = 1 }
        if fifths < 0, Array("BEADGCF").prefix(-fifths).contains(nextLetter) { alteration = -1 }
        let result = natural + (accidentals[staff]?[pitch] ?? alteration)
        return (0...127).contains(result) ? result : nil
    }
}

enum ScoreRecognitionOrnaments {
    static func ornament(_ symbol: ScoreRecognitionSymbol) -> String? {
        let marks = Set(symbol.articulation.split(separator: "_").map(String.init))
        if marks.contains("trill") { return marks.contains("turn") ? "trill_turn" : "trill" }
        if marks.contains("mordent") { return "mordent" }
        if marks.contains("turn") { return "turn" }
        return nil
    }
    static func expand(_ note: ScoreRecognizedNote, symbol: ScoreRecognitionSymbol,
                       context: ScoreRecognitionPitchContext, options: ScoreOrnamentOptions) -> [ScoreRecognizedNote] {
        guard options.enabled, let kind = ornament(symbol) else { return [note] }
        let upper = context.neighbor(of: symbol, direction: 1), lower = context.neighbor(of: symbol, direction: -1)
        var pitches: [Int]
        switch kind {
        case "mordent":
            guard let lower else { return [note] }
            pitches = [note.midi, lower, note.midi]
        case "turn":
            // HOMR 0.7.1 exports its `turn` label as MusicXML inverted-turn.
            guard let lower, let upper else { return [note] }
            pitches = [lower, note.midi, upper, note.midi]
        default:
            guard let upper else { return [note] }
            let minimum = options.trillFromUpper ? 2 : 3
            var count = max(minimum, min(64, Int(floor(note.duration / options.step))))
            // Finish on the principal note; optional combined turn is a short ending.
            if options.trillFromUpper, count % 2 != 0 { count -= 1 }
            if !options.trillFromUpper, count % 2 == 0 { count -= 1 }
            pitches = (0..<count).map { i in
                (i % 2 == 0) == options.trillFromUpper ? upper : note.midi
            }
            if kind == "trill_turn", let lower { pitches += [lower, note.midi] }
        }
        // No microscopic bursts on short notes or out-of-range guessed pitches.
        guard note.duration / Double(pitches.count) * 60 / options.tempo >= 0.02 else { return [note] }
        let step = min(options.step, note.duration / Double(pitches.count))
        return pitches.enumerated().map { index, pitch in
            var result = note
            result.midi = pitch; result.beat += Double(index) * step
            result.duration = index == pitches.count - 1 ? note.duration - Double(index) * step : step
            result.decoration = kind
            return result
        }
    }
}
#endif
