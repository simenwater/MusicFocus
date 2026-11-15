#if DEBUG
import XCTest
import CryptoKit
import AVFoundation
import UIKit
@testable import MusicFocus
final class ScoreSystemGroupingTests: XCTestCase {
    private func sample(_ counts: [Int], pageBorder: Bool = false) -> ([ScoreRecognitionStaff], ScoreRecognitionRaster) {
        let total = counts.reduce(0,+)
        let width = 500, height = total*90+20
        let staffs: [ScoreRecognitionStaff] = (0..<total).map { i in
            let center = Double(50+i*90)
            return ScoreRecognitionStaff(samples: [.init(x:40,y:center,unit:6), .init(x:460,y:center,unit:6)])
        }
        var pixels = [UInt8](repeating:255,count:width*height), index = 0
        for staff in staffs {
            for offset in -2...2 { for x in 40...460 { pixels[(Int(staff.center)+offset*6)*width+x] = 0 } }
        }
        for count in counts {
            if count > 1 { for y in Int(staffs[index].center-12)...Int(staffs[index+count-1].center+12) { pixels[y*width+80] = 0 } }
            index += count
        }
        if pageBorder { for y in 0..<height { pixels[y*width+470] = 0 } }
        return (staffs,.init(width:width,height:height,pixels:pixels,pixelToPDF:.identity))
    }

    func testMixedSystemsAndQuartetPreserveStaffOrder() throws {
        for counts in [[2,2,3],[4,4,3],[1,2,1,3],[4]] {
            let (staffs,raster) = sample(counts)
            let groups = try ScoreRecognitionSystems.groups(staffs:staffs,raster:raster)
            XCTAssertEqual(groups.map(\.count),counts)
            XCTAssertEqual(groups.flatMap{$0},Array(staffs.indices))
        }
    }

    func testPageEdgeAndUnconnectedStaffLinesDoNotJoinSystems() throws {
        for counts in [[2,2,3],[1,1,1,1]] {
            let (staffs,raster) = sample(counts,pageBorder:true)
            XCTAssertEqual(try ScoreRecognitionSystems.groups(staffs:staffs,raster:raster).map(\.count),counts)
        }
    }

    func testImplausiblyLargeGroupRequiresManualLayout() throws {
        let (staffs,raster) = sample([9])
        XCTAssertThrowsError(try ScoreRecognitionSystems.groups(staffs:staffs,raster:raster))
    }

    func testFaintShowThroughIsNotAPlayableSoloSystem() throws {
        let (staffs, original) = sample([1,2])
        var pixels = original.pixels
        for y in 0..<80 { for x in 0..<original.width where pixels[y*original.width+x] == 0 { pixels[y*original.width+x] = 235 } }
        let raster = ScoreRecognitionRaster(width:original.width,height:original.height,pixels:pixels,pixelToPDF:.identity)
        XCTAssertEqual(ScoreRecognitionSystems.printedLineSupport(staffs[0],raster:raster),0)
        XCTAssertThrowsError(try ScoreRecognitionSystems.groups(staffs:staffs,raster:raster))
    }

    func testRecoveryProtectsFaintFrontClefsAndSmallCueStaves() throws {
        let (staffs, original) = sample([1,2,2])
        var pixels = original.pixels
        for i in 0..<(original.width * 80) where pixels[i] == 0 { pixels[i] = 235 }
        let page = ScoreRecognitionRaster(width:original.width,height:original.height,pixels:pixels,pixelToPDF:.identity)
        let frontClef = CGRect(x:64,y:45,width:14,height:11)
        XCTAssertEqual(try ScoreRecognitionSystems.possibleShowThrough(staffs,raster:page,clefBounds:[]),[0])
        XCTAssertTrue(try ScoreRecognitionSystems.possibleShowThrough(staffs,raster:page,clefBounds:[frontClef]).isEmpty)
        let shortKeyMark = CGRect(x:76,y:48,width:5,height:7)
        XCTAssertEqual(try ScoreRecognitionSystems.possibleShowThrough(staffs,raster:page,clefBounds:[shortKeyMark]),[0])
        var withCue = staffs
        withCue[0].samples = staffs[0].samples.map { .init(x:$0.x,y:$0.y,unit:$0.unit * 0.7) }
        XCTAssertTrue(try ScoreRecognitionSystems.possibleShowThrough(withCue,raster:page,clefBounds:[]).isEmpty)
        let pale = ScoreRecognitionRaster(width:original.width,height:original.height,
                                            pixels:original.pixels.map { max($0, 218) },pixelToPDF:.identity)
        XCTAssertTrue(try ScoreRecognitionSystems.possibleShowThrough(staffs,raster:pale,clefBounds:[]).isEmpty)
        XCTAssertFalse(try ScoreRecognitionSystems.confirmsShowThrough(original:staffs,retry:Array(staffs.dropFirst(2)),
                                                                       candidates:[0],raster:page))
    }

    #if MUSICFOCUS_HOMR
    func testOriginalShowThroughPhotoGroupsBothPagesAndProducesAudio() async throws {
        guard let path = ProcessInfo.processInfo.environment["SCORE_GROUP_NOISE_PDF"] else { throw XCTSkip("Supply the two-page Minuet scan") }
        let url = URL(fileURLWithPath:path)
        let digest = SHA256.hash(data:try Data(contentsOf:url)).map { String(format:"%02x",$0) }.joined()
        let models = try ScoreRecognitionModels()
        // Approximate front staff centers measured on the two original pages, top to bottom.
        let centers = [[0.207,0.295,0.411,0.493,0.607,0.686,0.793,0.877],
                       [0.104,0.182,0.286,0.363,0.455,0.526,0.620,0.716,0.806,0.877]]
        for (i,expected) in centers.enumerated() {
            let page = i+1
            let raster = try ScoreRecognitionRaster.read(url,page:page)
            let mask = try models.staffMask(raster) { _ in }
            let originalClefs = models.clefMask
            let rows = try models.staffRegions(in:raster,mask:mask,layout:.automatic,clefBounds:ScoreRecognitionClefs(raster:raster,mask:models.clefMask).candidates.map(\.rect))
            XCTAssertEqual(models.clefMask,originalClefs)
            XCTAssertEqual(rows.map { $0.flatMap(\.staffs).count }, Array(repeating:2,count:expected.count/2))
            let actual = rows.flatMap { $0.flatMap(\.staffs) }.map { $0.center/Double(raster.height) }
            XCTAssertEqual(actual.count,expected.count)
            for (detected, printed) in zip(actual, expected) { XCTAssertEqual(detected,printed,accuracy:0.025) }
            let package = try await ScoreRecognizer.shared.recognize(.init(url:url,digest:digest,title:"Minuet",pages:[page],layout:.automatic)) { _,_ in }
            try package.validate(digest:digest,pageCount:2)
            XCTAssertGreaterThan(try AVAudioPlayer(data:package.audio).duration,1)
            XCTAssertFalse(package.cues.isEmpty)
            XCTAssertEqual(package.recognitionRevision,ScoreAuditionPackage.currentRecognitionRevision)
            print("Minuet page",page,"systems",rows.count,"bars",package.bars?.count ?? 0,"cues",package.cues.count)
        }
    }

    func testCleanAndPaleFrontStavesSurviveTheRecognitionPath() throws {
        guard let path = ProcessInfo.processInfo.environment["SCORE_GROUP_CONTROL_PDF"] else { throw XCTSkip("Supply a clean two-staff scan") }
        let original = try ScoreRecognitionRaster.read(URL(fileURLWithPath:path),page:1)
        let models = try ScoreRecognitionModels()
        for minimum in [0, 130] {
            let pixels = original.pixels.map { UInt8(minimum + Int($0) * (255-minimum) / 255) }
            let raster = ScoreRecognitionRaster(width:original.width,height:original.height,pixels:pixels,pixelToPDF:original.pixelToPDF)
            let mask = try models.staffMask(raster) { _ in }
            let staves = try ScoreRecognitionLayout.staffs(mask:mask,width:raster.width,height:raster.height)
            let first = try ScoreRecognitionLayout.automatic.regions(staffs:staves,mask:mask,width:raster.width,height:raster.height,raster:raster)
            let actual = try models.staffRegions(in:raster,mask:mask,layout:.automatic,clefBounds:ScoreRecognitionClefs(raster:raster,mask:models.clefMask).candidates.map(\.rect))
            XCTAssertEqual(actual.map { $0.flatMap(\.staffs).count },[2])
            XCTAssertEqual(actual.flatMap { $0.map(\.rect) },first.flatMap { $0.map(\.rect) })
        }
    }

    func testOriginalSonataGrouping() throws {
        guard let path = ProcessInfo.processInfo.environment["SCORE_AUDITION_PDF"] else { throw XCTSkip("Supply original Sonata 6 score") }
        let models=try ScoreRecognitionModels(),root=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("SystemGrouping")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        for (page,expected) in [(2,[2,2,2,2,2]),(11,[2,2,2,2,2]),(13,[2,2,2,3]),(14,[4,4,3])] {
            let raster=try ScoreRecognitionRaster.read(URL(fileURLWithPath:path),page:page),mask=try models.staffMask(raster){_ in}
            let staffs=try ScoreRecognitionLayout.staffs(mask:mask,width:raster.width,height:raster.height)
            let boundaries=try ScoreRecognitionSystems.boundaries(staffs:staffs,raster:raster),groups=try ScoreRecognitionSystems.groups(staffs:staffs,raster:raster)
            print("SYSTEM GROUPS",page,staffs.count,groups,boundaries)
            XCTAssertEqual(groups.map(\.count),expected)
            let metadata:[[String:Any]]=staffs.map{["samples":$0.samples.map{["x":$0.x,"y":$0.y,"unit":$0.unit]}]}
            try JSONSerialization.data(withJSONObject:metadata).write(to:root.appendingPathComponent("staffs-\(page).json"))
            guard !groups.isEmpty else { continue }
            let rows=try models.staffRegions(in:raster,mask:mask,layout:.automatic,clefBounds:ScoreRecognitionClefs(raster:raster,mask:models.clefMask).candidates.map(\.rect))
            XCTAssertEqual(rows.map { $0.flatMap(\.staffs).count },expected)
            let regions=rows.map{$0.map{r in ["rect":[r.rect.minX,r.rect.minY,r.rect.width,r.rect.height],"scale":r.scale,"offsetY":r.offsetY,"staves":r.staffs.map{$0.samples.map{["x":$0.x,"y":$0.y,"unit":$0.unit]}}] as [String:Any]}}
            try JSONSerialization.data(withJSONObject:regions).write(to:root.appendingPathComponent("regions-\(page).json"))
        }
    }
    #endif
}
#endif
