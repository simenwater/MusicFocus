#if DEBUG || MUSICFOCUS_HOMR
import Foundation

/// Reusable notation, never PDF annotations. Retaining it lets adjacent pages
/// share one audio timeline without re-running their recognition models.
struct ScoreRecognitionNotation: Codable, Sendable {
    var pages: [Int]
    var configuration: String
    var notes: [ScoreRecognizedNote]
    var bars: [ScoreAuditionPackage.Bar]
    var marks: [ScoreRecognitionRepeats.Mark]
    var beats: Double
    var consistentBars: Bool
    func validate(pageCount: Int) throws {
        guard pageCount > 0, !pages.isEmpty, pages.count <= 8, pages == Array(Set(pages)).sorted(),
              pages.allSatisfy({ (1...pageCount).contains($0) }),
              zip(pages, pages.dropFirst()).allSatisfy({ $1 == $0 + 1 }),
              configuration.count < 200, beats.isFinite, beats > 0, beats <= 4000,
              !notes.isEmpty, notes.count <= 24_000, bars.count <= 5_000, marks.count <= 10_000 else { throw ScoreAuditionError.invalid }
        for note in notes {
            guard (0...127).contains(note.midi), note.beat.isFinite, note.duration.isFinite,
                  note.beat >= 0, note.duration > 0, note.beat + note.duration <= beats + 0.001,
                  pages.contains(note.page), (1...16).contains(note.staff), note.measure > 0,
                  note.point.x.isFinite, note.point.y.isFinite else { throw ScoreAuditionError.invalid }
        }
        var end = 0.0
        for (index, bar) in bars.enumerated() {
            guard bar.measure == index + 1, bar.start.isFinite, bar.duration.isFinite,
                  abs(bar.start - end) < 0.001, bar.duration > 0 else { throw ScoreAuditionError.invalid }
            end = bar.end
        }
        guard marks.allSatisfy({ (0...bars.count).contains($0.after) && $0.kind.count < 40 && ($0.numbers?.count ?? 0) <= 8 }) else { throw ScoreAuditionError.invalid }
    }
    static func joined(_ pieces: [ScoreRecognitionNotation], secondsPerBeat: Double) throws -> Self {
        guard let first = pieces.first, secondsPerBeat.isFinite, secondsPerBeat > 0 else { throw ScoreAuditionError.invalid }
        var result = Self(pages: [], configuration: first.configuration, notes: [], bars: [], marks: [], beats: 0, consistentBars: true)
        for piece in pieces {
            guard piece.configuration == first.configuration,
                  result.pages.last.map({ piece.pages.first == $0 + 1 }) ?? true else { throw ScoreAuditionError.invalid }
            let count = result.bars.count
            for var note in piece.notes {
                note.beat += result.beats; note.measure += count; note.sourceMeasure = nil
                result.notes.append(note)
            }
            result.bars += piece.bars.map { .init(measure: $0.measure + count, start: $0.start + result.beats * secondsPerBeat, duration: $0.duration) }
            result.marks += piece.marks.map { .init(after: $0.after + count, kind: $0.kind, numbers: $0.numbers) }
            result.beats += piece.beats; result.pages += piece.pages
            result.consistentBars = result.consistentBars && piece.consistentBars
        }
        try result.validate(pageCount: result.pages.last ?? 1)
        return result
    }
}
#endif
#if MUSICFOCUS_HOMR
extension ScoreRecognizer {
    func renderNotation(_ notation: ScoreRecognitionNotation, digest: String, title: String, notice: String,
                        tempo: Double, repeats: Bool, pageCount: Int, revision: Int = ScoreAuditionPackage.currentRecognitionRevision) throws -> ScoreAuditionPackage {
        try notation.validate(pageCount: pageCount)
        var notes = notation.notes, bars = notation.bars, beats = notation.beats, repeatNotice = ""
        if repeats, notation.consistentBars {
            let plan = ScoreRecognitionRepeats.plan(count: bars.count, marks: notation.marks, startsAtBeginning: notation.pages.first == 1)
            if plan.order != Array(1...bars.count) {
                let expanded = ScoreRecognitionRepeats.expand(notes: notes, bars: bars, order: plan.order, secondsPerBeat: 60 / tempo)
                notes = expanded.notes; bars = expanded.bars; beats = expanded.beats
                repeatNotice = ScoreAuditionText.value("已演奏可确认的反复与一房二房。", " Confirmed repeats and first/second endings are performed.")
            }
            if plan.omitted { repeatNotice += ScoreAuditionText.value("部分反复标记不完整，暂保留原顺序。", " Incomplete repeat markings stay in printed order.") }
        }
        guard beats * 60 / tempo <= 600, notes.count <= 24_000 else { throw ScoreRecognitionFailure("已准备的连奏片段过长，请从后面的谱页开始。", "This connected preview is too long. Start from a later page.") }
        try Task.checkCancellation()
        let sustained = ScoreRecognitionTies.merge(notes)
        let audio = try ScoreRecognitionAudio.render(sustained, beats: beats, tempo: tempo)
        let cues = notes.sorted { $0.beat < $1.beat }.map { note in
            ScoreAuditionPackage.Cue(time: note.beat * 60 / tempo, duration: max(0.05, note.duration * 60 / tempo), page: note.page,
                                     staff: note.staff, measure: note.measure, x: note.point.x, y: note.point.y, sourceMeasure: note.sourceMeasure)
        }
        let timingNotice = notation.consistentBars ? "" : ScoreAuditionText.value(
            "多谱表声部的节奏尚未对齐，试听可能不准确；选段循环和反复暂不可用。",
            " Timing across staves is inconsistent. This preview may be inaccurate; bar loops and repeats are unavailable. ")
        let package = ScoreAuditionPackage(sourceSHA256: digest, title: title, notice: notice + repeatNotice + timingNotice
            + ScoreAuditionText.value("请对照原谱核对；D.S./D.C. 等复杂跳转暂不演绎。", " Check against the original; D.S./D.C. navigation is not performed."),
            tempo: tempo, duration: audio.duration, cues: cues, audio: audio.piano, audioWithClicks: audio.clicks,
            bars: notation.consistentBars ? bars : nil, recognitionRevision: revision,
            performsRepeats: repeats, notation: notation)
        try package.validate(digest: digest, pageCount: pageCount)
        try Task.checkCancellation(); try package.cache()
        return package
    }

    /// Join contiguous cached notation. Never concatenate AAC files: that would
    /// retrigger ties and insert the release padding at every page boundary.
    func connectedPreview(around package: ScoreAuditionPackage, pageCount: Int) throws -> ScoreAuditionPackage {
        guard let original = package.notation, original.pages.count == 1, let page = original.pages.first else { return package }
        var pieces = [package], seconds = original.beats * 60 / package.tempo
        func cached(_ page: Int) -> ScoreAuditionPackage? {
            guard (1...pageCount).contains(page), let candidate = ScoreAuditionPackage.cached(digest: package.sourceSHA256, page: page, pageCount: pageCount,
                minimumRevision: package.recognitionRevision, performsRepeats: package.performsRepeats, singlePage: true),
                  candidate.notation?.configuration == original.configuration,
                  let draft = candidate.notation, seconds + draft.beats * 60 / candidate.tempo < 300 else { return nil }
            return candidate
        }
        var before = page - 1
        while pieces.count < 8, let candidate = cached(before) {
            pieces.insert(candidate, at: 0); seconds += candidate.notation!.beats * 60 / candidate.tempo; before -= 1
        }
        var after = page + 1
        while pieces.count < 8, let candidate = cached(after) {
            pieces.append(candidate); seconds += candidate.notation!.beats * 60 / candidate.tempo; after += 1
        }
        guard pieces.count > 1 else { return package }
        let draft = try ScoreRecognitionNotation.joined(pieces.compactMap(\.notation), secondsPerBeat: 60 / package.tempo)
        return try autoreleasepool {
            try renderNotation(draft, digest: package.sourceSHA256, title: package.title,
                notice: ScoreAuditionText.value("相邻谱页连奏 · 第 \(draft.pages.first!)–\(draft.pages.last!) 页。", "Connected preview · Pages \(draft.pages.first!)–\(draft.pages.last!). "),
                tempo: package.tempo, repeats: package.performsRepeats ?? false, pageCount: pageCount, revision: package.recognitionRevision ?? 8)
        }
    }
}
#endif
