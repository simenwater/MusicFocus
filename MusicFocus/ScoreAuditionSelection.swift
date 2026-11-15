#if DEBUG || MUSICFOCUS_HOMR
import Foundation

struct ScoreAuditionLoop: Equatable, Sendable {
    var start: Double
    var end: Double
    var firstMeasure: Int
    var lastMeasure: Int
    var duration: Double { end - start }
    func contains(_ time: Double) -> Bool { time >= start && time < end }
    func isValid(for duration: Double) -> Bool {
        start.isFinite && end.isFinite && start >= 0 && end <= duration && end - start >= 0.1
    }
}

extension ScoreAuditionPackage {
    /// At a page-leading rest the new bar owns the page, even before its first
    /// sounding note. Do not scroll back to the previous page's final cue.
    func followCue(at time: Double) -> Cue? {
        if let bar = bars?.first(where: { time >= $0.start && time < $0.end }),
           let cue = cues.first(where: { $0.measure == bar.measure }), cue.time > time { return cue }
        return cues.last { $0.time <= time }
    }

    /// Whole-bar selection, inclusive of both taps; selecting backwards is valid.
    func loop(from first: Cue, through last: Cue) -> ScoreAuditionLoop? {
        let low = min(first.measure, last.measure), high = max(first.measure, last.measure)
        guard let bars, let firstBar = bars.first(where: { $0.measure == low }),
              let lastBar = bars.first(where: { $0.measure == high }) else { return nil }
        let loop = ScoreAuditionLoop(start: firstBar.start, end: lastBar.end,
                                    firstMeasure: min(first.printedMeasure, last.printedMeasure),
                                    lastMeasure: max(first.printedMeasure, last.printedMeasure))
        return loop.isValid(for: duration) ? loop : nil
    }
}
#endif
