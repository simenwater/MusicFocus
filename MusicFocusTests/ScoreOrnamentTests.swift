#if DEBUG
import XCTest
@testable import MusicFocus

final class ScoreOrnamentTests: XCTestCase {
    func testGraceNotesBorrowFromOnlyTheirOwnVoiceAndPreserveBarLength() throws {
        let symbols: [ScoreRecognitionSymbol] = [
            .init(rhythm: "note_16G", pitch: "E5", point: .init(x: 10, y: 20)),
            .init(rhythm: "note_16G", pitch: "F5", point: .init(x: 15, y: 20)),
            .init(rhythm: "note_4", pitch: "G5"), .init(rhythm: "chord"),
            .init(rhythm: "note_2", pitch: "C3", position: "lower"),
            .init(rhythm: "note_4", pitch: "A5"), .init(rhythm: "barline"),
            .init(rhythm: "note_4", pitch: "B5")
        ]
        let decorated = try ScoreRecognitionTimeline.convert(symbols)
        let plain = try ScoreRecognitionTimeline.convert(symbols, options: .init(enabled: false))
        XCTAssertEqual(decorated.duration, plain.duration)
        XCTAssertEqual(decorated.duration, 3)
        XCTAssertEqual(decorated.notes.filter { $0.decoration == "grace" }.map(\.midi), [76, 77])
        XCTAssertEqual(decorated.notes.filter { $0.decoration == "grace" }.map(\.beat), [0, 0.125])
        XCTAssertEqual(decorated.notes.first { $0.midi == 79 }?.beat, 0.25)
        XCTAssertEqual(decorated.notes.first { $0.midi == 79 }?.duration, 0.75)
        XCTAssertEqual(decorated.notes.first { $0.staff == 2 }?.beat, 0)
        XCTAssertEqual(decorated.notes.first { $0.staff == 2 }?.duration, 2)
        XCTAssertEqual(decorated.notes.last?.beat, 2)
        XCTAssertEqual(decorated.skippedGrace, 0)
    }
    func testGraceChordPlaysOnceAndMovesAllHostChordNotesTogether() throws {
        let symbols: [ScoreRecognitionSymbol] = [
            .init(rhythm: "note_8G", pitch: "C5"), .init(rhythm: "chord"), .init(rhythm: "note_8G", pitch: "E5"),
            .init(rhythm: "note_4", pitch: "D5"), .init(rhythm: "chord"), .init(rhythm: "note_4", pitch: "F5")
        ]
        let notes = try ScoreRecognitionTimeline.convert(symbols).notes
        XCTAssertEqual(notes.count, 4)
        XCTAssertEqual(notes.prefix(2).map(\.beat), [0, 0])
        XCTAssertEqual(notes.suffix(2).map(\.beat), [0.125, 0.125])
        XCTAssertEqual(notes.suffix(2).map(\.duration), [0.875, 0.875])
    }
    func testUnpairedGraceNeverMigratesPastRestOrBarline() throws {
        let symbols: [ScoreRecognitionSymbol] = [
            .init(rhythm: "note_8G", pitch: "C5"), .init(rhythm: "rest_4"),
            .init(rhythm: "note_8G", pitch: "D5"), .init(rhythm: "barline"),
            .init(rhythm: "note_4", pitch: "E5"), .init(rhythm: "note_8G", pitch: "F5")
        ]
        let result = try ScoreRecognitionTimeline.convert(symbols)
        XCTAssertEqual(result.skippedGrace, 3)
        XCTAssertEqual(result.notes.count, 1); XCTAssertEqual(result.notes[0].beat, 1)
        XCTAssertEqual(result.notes[0].duration, 1)
    }
    func testTrillUsesKeyAndAccidentalsThenResetsAtBarline() throws {
        let symbols: [ScoreRecognitionSymbol] = [
            .init(rhythm: "keySignature_-1"),
            .init(rhythm: "note_4", pitch: "A3", position: "lower", articulation: "trill"),
            .init(rhythm: "barline"),
            .init(rhythm: "note_4", pitch: "B4", lift: "N"),
            .init(rhythm: "note_4", pitch: "A4", articulation: "trill"),
            .init(rhythm: "barline"),
            .init(rhythm: "note_4", pitch: "A4", articulation: "trill")
        ]
        let result = try ScoreRecognitionTimeline.convert(symbols)
        XCTAssertEqual(Set(result.notes.filter { $0.measure == 1 }.map(\.midi)), Set([57, 58]))
        XCTAssertEqual(Set(result.notes.filter { $0.measure == 2 && $0.decoration == "trill" }.map(\.midi)), Set([69, 71]))
        XCTAssertEqual(Set(result.notes.filter { $0.measure == 3 }.map(\.midi)), Set([69, 70]))
        XCTAssertEqual(result.duration, 4)
        XCTAssertTrue(result.notes.allSatisfy { $0.duration > 0 && $0.beat + $0.duration <= 4 })
    }
    func testTrillStartChoiceTurnMordentAndKeyCarryBetweenSystems() throws {
        var context = ScoreRecognitionPitchContext()
        _ = try ScoreRecognitionTimeline.convert([.init(rhythm: "keySignature_1"), .init(rhythm: "note_4", pitch: "C4")], options: .init(), context: &context)
        let trill = ScoreRecognitionSymbol(rhythm: "note_4", pitch: "E5", articulation: "trill")
        let upper = try ScoreRecognitionTimeline.convert([trill], options: .init(), context: &context)
        XCTAssertEqual(upper.notes.first?.midi, 78)
        XCTAssertEqual(upper.notes.last?.midi, 76)
        let principal = try ScoreRecognitionTimeline.convert([trill], options: .init(trillFromUpper: false), context: &context)
        XCTAssertEqual(principal.notes.first?.midi, 76); XCTAssertEqual(principal.notes.last?.midi, 76)
        let turn = try ScoreRecognitionTimeline.convert([.init(rhythm: "note_4", pitch: "C5", articulation: "turn")])
        XCTAssertEqual(turn.notes.map(\.midi), [71, 72, 74, 72])
        let mordent = try ScoreRecognitionTimeline.convert([.init(rhythm: "note_4", pitch: "C5", articulation: "mordent")])
        XCTAssertEqual(mordent.notes.map(\.midi), [72, 71, 72])
        XCTAssertEqual(mordent.notes.map(\.duration).reduce(0,+), 1, accuracy: 1e-9)
    }
    func testDisabledOrnamentsAndVeryShortNotesKeepOriginalTiming() throws {
        for tempo in [30.0, 80, 180] {
            for rhythm in ["note_4.", "note_12", "note_64"] {
                for kind in ["trill", "turn", "mordent", "trill_turn"] {
                    let symbol = ScoreRecognitionSymbol(rhythm: rhythm, pitch: "C5", articulation: kind)
                    let on = try ScoreRecognitionTimeline.convert([symbol], options: .init(tempo: tempo))
                    let off = try ScoreRecognitionTimeline.convert([symbol], options: .init(enabled: false, tempo: tempo))
                    XCTAssertEqual(off.notes.count, 1); XCTAssertEqual(on.duration, off.duration)
                    XCTAssertEqual(on.notes.map(\.duration).reduce(0,+), off.duration, accuracy: 1e-9)
                    XCTAssertTrue(on.notes.allSatisfy { $0.duration.isFinite && $0.duration > 0 && $0.beat >= 0 && $0.beat + $0.duration <= on.duration + 1e-8 })
                }
            }
        }
    }
    func testMordentUsesKeyNaturalAndBarReset() throws {
        let symbols: [ScoreRecognitionSymbol] = [
            .init(rhythm: "keySignature_1"),
            .init(rhythm: "note_4", pitch: "G4", articulation: "mordent"),
            .init(rhythm: "note_4", pitch: "F4", lift: "N"),
            .init(rhythm: "note_4", pitch: "G4", articulation: "mordent"),
            .init(rhythm: "barline"),
            .init(rhythm: "note_4", pitch: "G4", articulation: "mordent")
        ]
        let result = try ScoreRecognitionTimeline.convert(symbols)
        XCTAssertEqual(result.notes.filter { $0.decoration == "mordent" }.map(\.midi),
                       [67, 66, 67, 67, 65, 67, 67, 66, 67])
        XCTAssertEqual(result.duration, 4)
    }

    func testTiesMergeOnlyMarkedChordMembersAndKeepScoreCues() throws {
        let result = try ScoreRecognitionTimeline.convert([
            .init(rhythm: "note_4", pitch: "C5", slur: "slurStart"), .init(rhythm: "chord"),
            .init(rhythm: "note_4", pitch: "E5"), .init(rhythm: "barline"),
            .init(rhythm: "note_4", pitch: "C5", slur: "slurStopStart"), .init(rhythm: "chord"),
            .init(rhythm: "note_4", pitch: "F5"), .init(rhythm: "barline"),
            .init(rhythm: "note_4", pitch: "C5", slur: "slurStop")
        ])
        let audio = ScoreRecognitionTies.merge(result.notes)
        XCTAssertEqual(result.notes.count, 5, "Printed noteheads remain available for follow and tap")
        XCTAssertEqual(audio.count, 3)
        XCTAssertEqual(audio.first(where: { $0.midi == 72 })?.duration, 3)
        XCTAssertEqual(audio.first(where: { $0.midi == 72 })?.tieRelease, 1)
        XCTAssertEqual(audio.filter { $0.midi != 72 }.map(\.duration), [1, 1])
        XCTAssertEqual(result.duration, 3)
    }

    func testSlursDifferentVoicesRestsAndUnmarkedNotesDoNotBecomeTies() throws {
        let pairs: [[ScoreRecognitionSymbol]] = [
            [.init(rhythm: "note_4", pitch: "C5", slur: "slurStart"), .init(rhythm: "note_4", pitch: "D5", slur: "slurStop")],
            [.init(rhythm: "note_4", pitch: "C5", slur: "slurStart"), .init(rhythm: "note_4", pitch: "C5", position: "upper2", slur: "slurStop")],
            [.init(rhythm: "note_4", pitch: "C5", slur: "slurStart"), .init(rhythm: "rest_4"), .init(rhythm: "note_4", pitch: "C5", slur: "slurStop")],
            [.init(rhythm: "note_4", pitch: "C5", slur: "slurStart"), .init(rhythm: "note_4", pitch: "C5")],
            [.init(rhythm: "note_4", pitch: "C5", slur: "slurStart"), .init(rhythm: "note_4", pitch: "D5"), .init(rhythm: "note_4", pitch: "C5", slur: "slurStop")]
        ]
        for pair in pairs {
            let notes = try ScoreRecognitionTimeline.convert(pair).notes
            XCTAssertEqual(ScoreRecognitionTies.merge(notes).count, notes.count)
        }
    }

    func testPairedRepeatsPreservePrintedTargetsAndDoNotGuessNumberedEndings() throws {
        let result = try ScoreRecognitionTimeline.convert([
            .init(rhythm: "repeatStart"), .init(rhythm: "note_4", pitch: "C5"), .init(rhythm: "barline"),
            .init(rhythm: "note_4", pitch: "D5"), .init(rhythm: "repeatEndStart"),
            .init(rhythm: "note_4", pitch: "E5"), .init(rhythm: "repeatEnd")
        ])
        let plan = ScoreRecognitionRepeats.plan(count: result.measures, marks: result.repeats)
        XCTAssertEqual(plan.order, [1, 2, 1, 2, 3, 3]); XCTAssertFalse(plan.omitted)
        let expanded = ScoreRecognitionRepeats.expand(notes: result.notes, bars: result.bars, order: plan.order, secondsPerBeat: 1)
        XCTAssertEqual(expanded.notes.map(\.midi), [72, 74, 72, 74, 76, 76])
        XCTAssertEqual(expanded.notes.map(\.beat), [0, 1, 2, 3, 4, 5])
        XCTAssertEqual(expanded.notes.map(\.sourceMeasure), [1, 2, 1, 2, 3, 3])
        XCTAssertEqual(expanded.bars.map(\.measure), [1, 2, 3, 4, 5, 6]); XCTAssertEqual(expanded.beats, 6)
        let complex = ScoreRecognitionRepeats.plan(count: 3, marks: result.repeats + [.init(after: 1, kind: "volta")])
        XCTAssertEqual(complex.order, [1, 2, 3]); XCTAssertTrue(complex.omitted)
        let missing = ScoreRecognitionRepeats.plan(count: 3, marks: [.init(after: 2, kind: "repeatEnd")])
        XCTAssertEqual(missing.order, [1, 2, 3]); XCTAssertTrue(missing.omitted)
    }

    func testFirstSecondEndingsAcrossPagesKeepPrintedTargets() throws {
        typealias Mark = ScoreRecognitionRepeats.Mark
        let marks: [Mark] = [.init(after: 0, kind: "repeatStart"),
            .init(after: 2, kind: "voltaStart", numbers: [1]), .init(after: 4, kind: "voltaStop"),
            .init(after: 4, kind: "repeatEnd"), .init(after: 4, kind: "voltaStart", numbers: [2]),
            .init(after: 6, kind: "voltaDiscontinue")]
        let plan = ScoreRecognitionRepeats.plan(count: 7, marks: marks)
        XCTAssertEqual(plan.order, [1, 2, 3, 4, 1, 2, 5, 6, 7]); XCTAssertFalse(plan.omitted)
        let bars = (1...7).map { ScoreAuditionPackage.Bar(measure: $0, start: Double($0 - 1), duration: 1) }
        let notes = (1...7).map { ScoreRecognizedNote(midi: 60 + $0, beat: Double($0 - 1), duration: 1,
            page: $0 <= 4 ? 1 : 2, staff: 1, measure: $0, point: .init(x: $0, y: 200), voice: "upper") }
        let expanded = ScoreRecognitionRepeats.expand(notes: notes, bars: bars, order: plan.order, secondsPerBeat: 1)
        XCTAssertEqual(expanded.notes.map(\.sourceMeasure), plan.order.map(Optional.init))
        XCTAssertEqual(expanded.notes.map(\.page), [1,1,1,1,1,1,2,2,2])
        XCTAssertEqual(expanded.notes.map(\.beat), (0..<9).map(Double.init))
        XCTAssertEqual(expanded.beats, 9)
        XCTAssertEqual(ScoreRecognitionRepeats.plan(count: 7, marks: Array(marks.dropFirst()), startsAtBeginning: true).order, plan.order)
        for invalid in [Array(marks.dropLast()), marks.map { Mark(after: $0.after, kind: $0.kind, numbers: $0.numbers == [2] ? [3] : $0.numbers) }, Array(marks.dropFirst())] {
            let fallback = ScoreRecognitionRepeats.plan(count: 7, marks: invalid)
            XCTAssertTrue(fallback.omitted); XCTAssertEqual(fallback.order, Array(1...7))
        }
    }

    func testVoltaBoundariesSurviveSystemAndPageBreaks() throws {
        let first = try ScoreRecognitionTimeline.convert([.init(rhythm: "repeatStart"),
            .init(rhythm: "note_4", pitch: "C5"), .init(rhythm: "barline"),
            .init(rhythm: "voltaStart", endingNumbers: [1]), .init(rhythm: "note_4", pitch: "D5"),
            .init(rhythm: "voltaStop"), .init(rhythm: "repeatEnd")])
        let second = try ScoreRecognitionTimeline.convert([.init(rhythm: "voltaStart", endingNumbers: [2]),
            .init(rhythm: "note_4", pitch: "E5"), .init(rhythm: "voltaDiscontinue"), .init(rhythm: "barline")])
        let marks = first.repeats + second.repeats.map { ScoreRecognitionRepeats.Mark(after: $0.after + first.measures, kind: $0.kind, numbers: $0.numbers) }
        XCTAssertEqual(ScoreRecognitionRepeats.plan(count: 3, marks: marks).order, [1,2,1,3])
    }

    func testCrossPageTieJoinsOnlyMatchingChordMemberWithoutPadding() throws {
        func page(_ page: Int, _ symbols: [ScoreRecognitionSymbol]) throws -> ScoreRecognitionNotation {
            let row = try ScoreRecognitionTimeline.convert(symbols)
            return .init(pages: [page], configuration: "same", notes: row.notes.map { var n = $0; n.page = page; return n },
                         bars: row.bars, marks: row.repeats, beats: row.duration, consistentBars: true)
        }
        let a = try page(1, [.init(rhythm: "note_4", pitch: "C5", slur: "slurStart"), .init(rhythm: "chord"), .init(rhythm: "note_4", pitch: "E5")])
        let b = try page(2, [.init(rhythm: "note_4", pitch: "C5", slur: "slurStop"), .init(rhythm: "chord"), .init(rhythm: "note_4", pitch: "F5")])
        let joined = try ScoreRecognitionNotation.joined([a,b], secondsPerBeat: 1)
        XCTAssertEqual(joined.bars.map(\.start), [0,1]); XCTAssertEqual(joined.beats, 2)
        XCTAssertEqual(joined.notes.count, 4, "All noteheads remain available to tap")
        let merged = ScoreRecognitionTies.merge(joined.notes)
        XCTAssertEqual(merged.count, 3); XCTAssertEqual(merged.first(where: { $0.midi == 72 })?.duration, 2)
        XCTAssertThrowsError(try ScoreRecognitionNotation.joined([b,a], secondsPerBeat: 1))
        XCTAssertThrowsError(try joined.validate(pageCount: 0))
        var wrong = b; wrong.configuration = "different"
        XCTAssertThrowsError(try ScoreRecognitionNotation.joined([a,wrong], secondsPerBeat: 1))
        // A backward repeat must attack again even if the same pitch has both marks.
        var repeated = a.notes; repeated[0].slur = "slurStopStart"
        let expanded = ScoreRecognitionRepeats.expand(notes: repeated, bars: a.bars, order: [1,1], secondsPerBeat: 1)
        XCTAssertEqual(ScoreRecognitionTies.merge(expanded.notes).count, 4)
    }

    func testTieMaySkipFirstEndingButNeverTieBackwardIntoRepeat() throws {
        let row = try ScoreRecognitionTimeline.convert([
            .init(rhythm: "note_4", pitch: "C5", slur: "slurStart"), .init(rhythm: "barline"),
            .init(rhythm: "note_4", pitch: "C5", slur: "slurStop"), .init(rhythm: "barline"),
            .init(rhythm: "note_4", pitch: "C5", slur: "slurStopStart"), .init(rhythm: "barline"),
            .init(rhythm: "note_4", pitch: "C5", slur: "slurStop")])
        let expanded = ScoreRecognitionRepeats.expand(notes: row.notes, bars: row.bars, order: [1,2,1,3,4], secondsPerBeat: 1)
        let audio = ScoreRecognitionTies.merge(expanded.notes)
        XCTAssertEqual(audio.map(\.beat), [0,2]); XCTAssertEqual(audio.map(\.duration), [2,3])
    }

}
#endif
