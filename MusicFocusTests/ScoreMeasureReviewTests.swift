#if DEBUG && MUSICFOCUS_HOMR
import XCTest
@testable import MusicFocus

final class ScoreMeasureReviewTests: XCTestCase {
    private func notes(_ rhythms: [String]) -> [ScoreRecognitionSymbol] {
        rhythms.enumerated().map { i,r in
            .init(rhythm:r, pitch:"C4", point:CGPoint(x:40+12*i,y:55))
        }
    }

    func testEvenSixteenthsAndVisiblySpacedDottedPassageDoNotRequestAnotherRead() {
        let even = notes(Array(repeating:"note_16",count:5))
        XCTAssertFalse(ScoreRecognitionMeasureReview.regularRunOutlier(even[...]))
        var unusual = even
        unusual[2].rhythm = "note_8"
        XCTAssertTrue(ScoreRecognitionMeasureReview.regularRunOutlier(unusual[...]))
        unusual[3].point.x += 10
        XCTAssertFalse(ScoreRecognitionMeasureReview.regularRunOutlier(unusual[...]))
    }

    func testCropsMustAgreeAndKeepPrintedPitchesPositionsAndSlurs() throws {
        let good = notes(Array(repeating:"note_16",count:5))
        var primary = good
        primary[2].rhythm = "note_8"
        primary[2].slur = "slurStart"
        let reviewed = try XCTUnwrap(ScoreRecognitionMeasureReview.revisedDurations(primary,readings:[good,good]))
        XCTAssertEqual(reviewed.map(\.rhythm),good.map(\.rhythm))
        XCTAssertEqual(reviewed[2].slur,primary[2].slur)
        XCTAssertEqual(reviewed[2].point,primary[2].point)
        XCTAssertNil(ScoreRecognitionMeasureReview.revisedDurations(primary,readings:[good,primary]))
        var mismatch = good
        mismatch[2].pitch = "D4"
        XCTAssertNil(ScoreRecognitionMeasureReview.revisedDurations(primary,readings:[mismatch,mismatch]))
        mismatch = good
        mismatch[2].point.x += 22
        XCTAssertNil(ScoreRecognitionMeasureReview.revisedDurations(primary,readings:[mismatch,mismatch]))
        XCTAssertNil(ScoreRecognitionMeasureReview.revisedDurations(primary,readings:[good]))
    }

    func testContextRereadWritesOnlyTheFlaggedBarAndRequiresAgreement() throws {
        func stream(_ uneven: Bool) -> [ScoreRecognitionSymbol] {
            var result: [ScoreRecognitionSymbol] = []
            for bar in 0..<3 {
                for index in 0..<8 {
                    let rhythm = uneven && bar == 1 && index == 0 ? "note_8." : "note_8"
                    result.append(.init(rhythm:rhythm,pitch:"C4",point:CGPoint(x:40+bar*220+index*20,y:42)))
                }
                result.append(.init(rhythm:"barline"))
            }
            return result
        }
        let input = stream(true)
        let original = try ScoreRecognitionTimeline.convert(input)
        let correct = try ScoreRecognitionTimeline.convert(stream(false))
        var alternate = correct
        // Re-reading context can be wrong about the first bar. Its notes are protected.
        alternate.notes[0].midi += 2
        var picked: [Int] = []
        let fixed = try ScoreRecognitionContextReview.run(original,protected:[],symbols:input,beamCount:{ _ in nil },
            read:{ _ in alternate },observe:{ picked.append($0.measure) })
        XCTAssertEqual(picked,[2])
        XCTAssertEqual(fixed.notes.map(\.beat),correct.notes.map(\.beat))
        XCTAssertEqual(fixed.notes.map(\.duration),correct.notes.map(\.duration))
        XCTAssertEqual(fixed.notes.map(\.midi),original.notes.map(\.midi))
        XCTAssertEqual(fixed.notes.map(\.point),original.notes.map(\.point))
        let conflict = try ScoreRecognitionContextReview.run(original,protected:[],symbols:input,beamCount:{ _ in nil },
            read:{ smaller in smaller ? original:alternate },observe:{ _ in })
        XCTAssertEqual(conflict.notes.map(\.beat),original.notes.map(\.beat))
        for (source,tokens,protected) in [(correct,stream(false),Set<Int>()),(original,input,Set([2]))] {
            _ = try ScoreRecognitionContextReview.run(source,protected:protected,symbols:tokens,beamCount:{ _ in nil },
                read:{ _ in XCTFail("No flagged bar should reach inference"); return source },observe:{ _ in })
        }
    }

    func testIdlePreviewCannotSatisfyAuditionReviewRevision() {
        XCTAssertLessThan(ScoreAuditionPackage.revision(reviewRhythm:false),ScoreAuditionPackage.currentRecognitionRevision)
    }
}
#endif
