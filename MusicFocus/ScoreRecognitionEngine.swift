#if MUSICFOCUS_HOMR
import Foundation
import CoreGraphics
import OnnxRuntimeBindings
import Darwin

/// On-device HOMR 0.7.1 resources in recognition-enabled builds.
/// See the bundled license and Development/README.md.
final class ScoreRecognitionModels {
    static let fields = ["rhythm", "pitch", "lift", "position", "articulation", "slur"]
    static let outputs = ["out_rhythms", "out_pitchs", "out_lifts", "out_positions", "out_articulations", "out_slurs", "attention"]
    let env: ORTEnv
    let options: ORTSessionOptions
    let vocabulary: [String: [String]]
    var encoder: ORTSession?
    var decoder: ORTSession?
    private(set) var clefMask: [UInt8] = []
    static func resource(_ name: String) -> URL {
        Bundle.main.resourceURL!.appendingPathComponent("ScoreRecognitionModels").appendingPathComponent(name)
    }
    init() throws {
        env = try ORTEnv(loggingLevel: .warning)
        options = try ORTSessionOptions(); try options.setIntraOpNumThreads(2); try options.setGraphOptimizationLevel(.all)
        vocabulary = try JSONDecoder().decode([String: [String]].self, from: Data(contentsOf: Self.resource("vocabulary.json")))
    }
    func session(_ name: String) throws -> ORTSession {
        try ORTSession(env: env, modelPath: Self.resource(name + ".onnx").path, sessionOptions: options)
    }
    static func tensor(_ data: Data, _ type: ORTTensorElementDataType, _ shape: [Int]) throws -> ORTValue {
        try ORTValue(tensorData: NSMutableData(data: data), elementType: type, shape: shape.map(NSNumber.init))
    }
    static func tensor(_ floats: [Float], _ shape: [Int]) throws -> ORTValue {
        try floats.withUnsafeBytes { try tensor(Data($0), .float, shape) }
    }
    static func scalar(_ value: Int64, shape: [Int] = [1, 1]) throws -> ORTValue {
        var value = value
        return try withUnsafeBytes(of: &value) { try tensor(Data($0), .int64, shape) }
    }
    static func floats(_ value: ORTValue) throws -> [Float] {
        let data = try value.tensorData() as Data
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
    func staffRegions(in raster: ScoreRecognitionRaster, mask: [UInt8],
                      layout: ScoreRecognitionLayout, clefBounds: [CGRect]) throws -> [[ScoreRecognitionRegion]] {
        let original = try ScoreRecognitionLayout.staffs(mask: mask, width: raster.width, height: raster.height)
        let candidates = try ScoreRecognitionSystems.possibleShowThrough(original, raster: raster, clefBounds: clefBounds)
        if !candidates.isEmpty {
            let originalClefs = clefMask
            defer { clefMask = originalClefs }
            do {
                try Task.checkCancellation()
                // Whiten only the lightest tones in the layout detector's copy.
                // Pitch, rhythm, clefs and all printed symbols still use the original.
                let tones = (0...255).map { UInt8(min(255, $0 * 255 / 225)) }
                let copy = ScoreRecognitionRaster(width: raster.width, height: raster.height,
                                                  pixels: raster.pixels.map { tones[Int($0)] }, pixelToPDF: raster.pixelToPDF)
                let retryMask = try staffMask(copy) { _ in }
                let retry = try ScoreRecognitionLayout.staffs(mask: retryMask, width: raster.width, height: raster.height)
                if try ScoreRecognitionSystems.confirmsShowThrough(original: original, retry: retry,
                                                                    candidates: candidates, raster: raster) {
                    return try layout.regions(staffs: retry, mask: retryMask, width: raster.width,
                                              height: raster.height, raster: raster)
                }
            } catch is CancellationError { throw CancellationError() }
            catch { /* When the additional reading fails, use the first layout. */ }
        }
        return try layout.regions(staffs: original, mask: mask, width: raster.width, height: raster.height, raster: raster)
    }
    func staffMask(_ raster: ScoreRecognitionRaster, progress: (Double) -> Void) throws -> [UInt8] {
        // Release large transformer sessions before allocating the segmentation arena.
        encoder = nil; decoder = nil
        return try autoreleasepool {
            let model = try session("segnet"), w = raster.width, h = raster.height
            let runOptions = try ORTRunOptions()
            try runOptions.addConfigEntry(withKey: "memory.enable_memory_arena_shrinkage", value: "cpu:0")
            let reusableOutput = try Self.tensor([Float](repeating: 0, count: 6 * 320 * 320), [1, 6, 320, 320])
            var mask = [UInt8](repeating: 0, count: w * h)
            var clefs = [UInt8](repeating: 0, count: w * h)
            let xs = Array(stride(from: 0, to: w, by: 288)), ys = Array(stride(from: 0, to: h, by: 288))
            var step = 0
            for y in ys { for x in xs {
                try Task.checkCancellation()
                try autoreleasepool {
                    let xx = min(x, w - 320), yy = min(y, h - 320), area = 320 * 320
                    var patch = [Float](repeating: 255, count: 3 * area)
                    for py in 0..<320 { for px in 0..<320 {
                        let value = Float(raster.pixels[(yy + py) * w + xx + px]), i = py * 320 + px
                        patch[i] = value; patch[i + area] = value; patch[i + 2 * area] = value
                    } }
                    let input = try Self.tensor(patch, [1, 3, 320, 320])
                    try model.run(withInputs: ["input": input], outputs: ["output": reusableOutput], runOptions: runOptions)
                    let values = try Self.floats(reusableOutput)
                    guard values.count == area * 6 else { throw ScoreAuditionError.invalid }
                    for i in 0..<area {
                        var best = 0
                        for c in 1..<6 where values[c * area + i] > values[best * area + i] { best = c }
                        if best == 4 { mask[(yy + i / 320) * w + xx + i % 320] = 1 }
                        if best == 3 { clefs[(yy + i / 320) * w + xx + i % 320] = 1 }
                    }
                }
                step += 1; progress(Double(step) / Double(xs.count * ys.count))
            } }
            clefMask = clefs
            return mask
        }
    }
    func recognize(_ pixels: [Float]) throws -> [ScoreRecognitionSymbol] {
        return try autoreleasepool {
            if encoder == nil { encoder = try session("encoder") }
            if decoder == nil { decoder = try session("decoder") }
            let input = try Self.tensor(pixels, [1, 1, 256, 1280])
            let context = try encoder!.run(withInputs: ["input": input], outputNames: ["output"], runOptions: nil)["output"]!
            let reduced = try Self.tensor(Data((try context.tensorData() as Data).prefix(512 * 4)), .float, [1, 1, 512])
            var cache = try (0..<32).map { _ in try Self.tensor(Data(), .float, [1, 8, 0, 64]) }
            var last: [Int64] = [1, 0, 0, 0, 0, 0], symbols: [ScoreRecognitionSymbol] = []
            let names = Set(Self.outputs + (0..<32).map { "cache_out\($0)" })
            for step in 0..<608 {
                try Task.checkCancellation()
                // The ObjC ORT wrapper autoreleases outputs. Drain on EVERY token;
                // otherwise cross-attention caches can accumulate to several GB.
                let (ids, point, nextCache) = try autoreleasepool { () -> ([Int], CGPoint, [ORTValue]) in
                    var inputs: [String: ORTValue] = [
                        "rhythms": try Self.scalar(last[0]), "pitchs": try Self.scalar(last[1]), "lifts": try Self.scalar(last[2]),
                        "articulations": try Self.scalar(last[4]), "slurs": try Self.scalar(last[5]),
                        "context": step == 0 ? context : reduced, "cache_len": try Self.scalar(Int64(step), shape: [1])
                    ]
                    for i in 0..<32 { inputs["cache_in\(i)"] = cache[i] }
                    let out = try decoder!.run(withInputs: inputs, outputNames: names, runOptions: nil)
                    let ids = try Self.outputs.prefix(6).map { key -> Int in
                        let values = try Self.floats(out[key]!)
                        guard !values.isEmpty, values.allSatisfy(\.isFinite) else { throw ScoreAuditionError.invalid }
                        return values.indices.max(by: { values[$0] < values[$1] })!
                    }
                    let xy = try Self.floats(out["attention"]!)
                    guard xy.count >= 2, xy[0].isFinite, xy[1].isFinite else { throw ScoreAuditionError.invalid }
                    return (ids, CGPoint(x: Double(xy[0]), y: Double(xy[1])), (0..<32).map { out["cache_out\($0)"]! })
                }
                cache = nextCache
                if ids[0] == 2 { return symbols }
                let labels = zip(Self.fields, ids).map { vocabulary[$0.0]![$0.1] }
                symbols.append(.init(rhythm: labels[0], pitch: labels[1], lift: labels[2], position: labels[3], articulation: labels[4], slur: labels[5], point: point))
                last = ids.map(Int64.init)
            }
            throw ScoreRecognitionFailure("这一行过密，识别未能完整结束。请改用更简单的谱页。", "This system is too dense to finish reliably. Try a simpler page.")
        }
    }
}

actor ScoreRecognizer {
    static let shared = ScoreRecognizer()
    struct Request: Sendable {
        var url: URL; var digest: String; var title: String; var pages: [Int]; var layout: ScoreRecognitionLayout
        var tempo: Double = 80
        var ornaments = true
        var ignoreColoredMarks = false
        var trillFromUpper = true
        var repeats = false
        var connectCachedPages = false
        var reviewRhythm = true
        #if DEBUG
        var onMeasureReview: (@Sendable (Int, ScoreRecognitionMeasureReview.Observation) -> Void)?
        #endif
    }
    func recognize(_ request: Request, diagnostics: URL? = nil, progress: @escaping @Sendable (Double, String) -> Void) throws -> ScoreAuditionPackage {
        let package = try autoreleasepool { try recognizeWithinPool(request, diagnostics: diagnostics, progress: progress) }
        guard request.connectCachedPages, let doc = CGPDFDocument(request.url as CFURL) else { return package }
        progress(0.98, ScoreAuditionText.value("衔接已准备的谱页", "Connecting prepared pages"))
        return try connectedPreview(around: package, pageCount: doc.numberOfPages)
    }
    private func recognizeWithinPool(_ request: Request, diagnostics: URL?, progress: @escaping @Sendable (Double, String) -> Void) throws -> ScoreAuditionPackage {
        guard !request.pages.isEmpty, request.pages.count <= 3, request.pages == Array(Set(request.pages)).sorted(), zip(request.pages, request.pages.dropFirst()).allSatisfy({ $1 == $0 + 1 }), request.tempo >= 20, request.tempo <= 200 else { throw ScoreAuditionError.invalid }
        var memoryTrace: [[String: String]] = []
        func trace(_ stage: String) {
            guard let diagnostics else { return }
            var info = task_vm_info_data_t()
            var size = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.size)
            let result = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &size) } }
            if result == KERN_SUCCESS {
                memoryTrace.append(["stage": stage, "physicalMB": String(Double(info.phys_footprint) / 1048576)])
                if let data = try? JSONSerialization.data(withJSONObject: memoryTrace, options: .prettyPrinted) { try? data.write(to: diagnostics.appendingPathExtension("memory.json"), options: .atomic) }
            }
        }
        trace("start")
        let models = try ScoreRecognitionModels()
        struct DiagnosticRow: Codable { var page: Int; var row: Int; var part: Int; var symbols: [ScoreRecognitionSymbol]; var opticalRhythmCorrections: Int }
        var diagnosticRows: [DiagnosticRow] = []
        struct BracketRow: Codable { var page: Int; var row: Int; var brackets: [ScoreRecognitionEndings.Bracket] }
        var bracketRows: [BracketRow] = []
        var contexts: [Int: ScoreRecognitionPitchContext] = [:]
        var graceCount = 0, ornamentCount = 0, skippedGrace = 0, correctedRhythms = 0
        let options = ScoreOrnamentOptions(enabled: request.ornaments, trillFromUpper: request.trillFromUpper, tempo: request.tempo)
        var bars: [ScoreAuditionPackage.Bar] = [], consistentBars = true
        var repeatMarks: [ScoreRecognitionRepeats.Mark] = []
        var all: [ScoreRecognizedNote] = [], offset = 0.0, measureOffset = 0, summaries: [String] = []
        for (pageIndex, page) in request.pages.enumerated() {
            try Task.checkCancellation()
            let raster = try ScoreRecognitionRaster.read(request.url, page: page, ignoreColoredMarks: request.ignoreColoredMarks)
            let mask = try models.staffMask(raster) { fraction in
                if Int(fraction * 100) % 20 == 0 || fraction < 0.02 { trace("seg \(Int(fraction * 100))%") }
                progress((Double(pageIndex) + fraction * 0.45) / Double(request.pages.count), ScoreAuditionText.value("第 \(page) 页 · 寻找谱行", "Page \(page) · Finding staves"))
            }
            trace("page \(page) segmented")
            if let diagnostics {
                try Data(models.clefMask).write(to:diagnostics.appendingPathExtension("page-\(page)-clefs.raw"))
                try Data(raster.pixels).write(to:diagnostics.appendingPathExtension("page-\(page)-pixels.raw"))
            }
            let clefEvidence = ScoreRecognitionClefs(raster:raster,mask:models.clefMask)
            let rows = try models.staffRegions(in: raster, mask: mask, layout: request.layout,
                                              clefBounds: clefEvidence.candidates.map(\.rect))
            if let diagnostics {
                let geometry = rows.map { $0.map { r in
                    ["rect":[r.rect.minX,r.rect.minY,r.rect.width,r.rect.height], "scale":r.scale, "offsetY":r.offsetY,
                     "staves":r.staffs.map{$0.samples.map{["x":$0.x,"y":$0.y,"unit":$0.unit]}}] as [String:Any]
                } }
                try JSONSerialization.data(withJSONObject:geometry).write(to:diagnostics.appendingPathExtension("page-\(page)-regions.json"))
            }
            var repairedRaster: ScoreRecognitionRaster?
            var decodedPage: [[[ScoreRecognitionSymbol]]] = []
            var printedUnits: [Double] = []
            // Decode the page before interpreting tuplets: a printed denominator
            // later on the same page can corroborate its compound subdivisions.
            for (rowIndex,row) in rows.enumerated() {
                var parts: [[ScoreRecognitionSymbol]] = []
                for (part,region) in row.enumerated() {
                    try Task.checkCancellation()
                    let useScanRepair = region.staffs.allSatisfy { $0.unit >= 14 }
                    if useScanRepair, repairedRaster == nil { repairedRaster = raster.closingSmallGaps(radius:1) }
                    let pixels = region.tensorPixels(useScanRepair ? repairedRaster! : raster)
                    if let diagnostics,pageIndex==0,rowIndex==0,part==0 {
                        try pixels.withUnsafeBytes {try Data($0).write(to:diagnostics.appendingPathExtension("staff-f32"))}
                    }
                    let decoded = try models.recognize(pixels).filter { region.isGrandStaff || !$0.position.hasPrefix("lower") }
                    let clefs = clefEvidence.repair(decoded,region:region)
                    let graphicMeters = try ScoreRecognitionGraphicMeters.read(clefs.symbols,raster:raster,region:region)
                    if let diagnostics {
                        let base = diagnostics.appendingPathExtension("page-\(page)-row-\(rowIndex)-part-\(part)")
                        try JSONEncoder().encode(decoded).write(to: base.appendingPathExtension("raw.json"))
                        try JSONEncoder().encode(graphicMeters).write(to: base.appendingPathExtension("meters.json"))
                    }
                    printedUnits += graphicMeters.filter{$0.count>=6 && $0.count.isMultiple(of:3)}.map(\.unit)
                    if let diagnostics {
                        try JSONSerialization.data(withJSONObject:["recovered":clefs.recovered,"changedNotes":clefs.changedNotes])
                            .write(to:diagnostics.appendingPathExtension("page-\(page)-row-\(rowIndex)-part-\(part)-clef-repair.json"))
                    }
                    parts.append(ScoreRecognitionGraphicMeters.removingIcons(clefs.symbols,readings:graphicMeters))
                }
                decodedPage.append(parts)
                progress((Double(pageIndex)+0.45+0.37*Double(rowIndex+1)/Double(rows.count))/Double(request.pages.count),ScoreAuditionText.value("第 \(page) 页 · 识别第 \(rowIndex+1)/\(rows.count) 行","Page \(page) · Reading system \(rowIndex+1)/\(rows.count)"))
            }
            let compoundUnit = Set(printedUnits).count==1 ? printedUnits.first : nil
            for (rowIndex, row) in rows.enumerated() {
                try Task.checkCancellation()
                var rowDuration = 0.0, rowMeasures = 0
                var rowBars: [ScoreAuditionPackage.Bar] = []
                var partBars: [[ScoreAuditionPackage.Bar]] = []
                for (part, region) in row.enumerated() {
                    let nested = try ScoreRecognitionOpticalRhythm.repairNested(decodedPage[rowIndex][part],raster:raster,region:region,unit:compoundUnit)
                    let beamed = ScoreRecognitionOpticalRhythm.repairBeams(nested.symbols,raster:repairedRaster ?? raster,region:region)
                    correctedRhythms += nested.corrected + beamed.corrected
                    let symbols = beamed.symbols
                    if diagnostics != nil { diagnosticRows.append(.init(page: page, row: rowIndex, part: part, symbols: symbols, opticalRhythmCorrections: nested.corrected + beamed.corrected)) }
                    graceCount += symbols.filter { $0.isGrace && $0.midi != nil }.count
                    ornamentCount += symbols.filter { $0.duration > 0 && $0.midi != nil && ScoreRecognitionOrnaments.ornament($0) != nil }.count
                    var context = contexts[part] ?? ScoreRecognitionPitchContext()
                    #if DEBUG
                    let enteringContext = context
                    #endif
                    var sequence = try ScoreRecognitionTimeline.convert(symbols, options: options, context: &context)
                    #if DEBUG
                    if request.reviewRhythm && row.count == 1 {
                        var protected = Set<Int>()
                        sequence = try ScoreRecognitionMeasureReview.run(sequence, symbols:symbols, region:region, raster:raster,
                            models:models, options:options, context:enteringContext) { sample in
                            if sample.change != "none" { protected.insert(sample.measure) }
                            request.onMeasureReview?(sample.measure + measureOffset, sample)
                            if let diagnostics {
                                let url = diagnostics.appendingPathExtension("review-p\(page)-s\(rowIndex)-m\(sample.measure + measureOffset).json")
                                try? JSONEncoder().encode(sample).write(to:url,options:.atomic)
                            }
                        }
                        if region.isGrandStaff {
                            let beams = ScoreRecognitionBeamEvidence(raster:raster)
                            sequence = try ScoreRecognitionContextReview.run(sequence, protected:protected, symbols:symbols, beamCount: { mark in
                                let staff = region.staffs[mark.position.hasPrefix("lower") ? 1 : 0]
                                return beams.count(at:region.sourcePoint(mark.point),unit:staff.unit)
                            }) { smaller in
                                let factor = smaller ? 0.88 : (region.staffs.allSatisfy { $0.unit >= 14 } ? 1.0 : 0.96)
                                let offset = factor == 1 ? region.offsetY : floor((256-region.rect.height*region.scale*factor)/2)
                                let alternate = ScoreRecognitionRegion(staffs:region.staffs,rect:region.rect,scale:region.scale*factor,offsetY:offset)
                                let image = smaller && region.staffs.allSatisfy({ $0.unit >= 14 }) ? (repairedRaster ?? raster) : raster
                                let raw = try models.recognize(alternate.tensorPixels(image)).map { original in
                                    var s=original
                                    s.point=CGPoint(x:s.point.x/factor,y:(s.point.y-offset)/factor+region.offsetY)
                                    return s
                                }
                                let clefs=clefEvidence.repair(raw,region:region)
                                let meters=try ScoreRecognitionGraphicMeters.read(clefs.symbols,raster:raster,region:region)
                                let clean=ScoreRecognitionGraphicMeters.removingIcons(clefs.symbols,readings:meters)
                                let nested=try ScoreRecognitionOpticalRhythm.repairNested(clean,raster:raster,region:region,unit:compoundUnit)
                                let beamed=ScoreRecognitionOpticalRhythm.repairBeams(nested.symbols,raster:repairedRaster ?? raster,region:region)
                                var local=enteringContext
                                return try ScoreRecognitionTimeline.convert(beamed.symbols,options:options,context:&local)
                            } observe: { observation in
                                request.onMeasureReview?(observation.measure + measureOffset,observation)
                            }
                        }
                    }
                    #endif
                    if part == 0 {
                        let detected = try ScoreRecognitionEndings.brackets(raster: raster, region: region, includeUnconfirmed: diagnostics != nil)
                        if diagnostics != nil { bracketRows.append(.init(page: page, row: rowIndex, brackets: detected)) }
                        let confirmed = detected.filter { $0.number != nil || (!$0.starts && $0.ends && $0.right - $0.left > (region.staffs[0].samples.last!.x - region.staffs[0].samples.first!.x) * 0.75) }
                        let printed = try ScoreRecognitionEndings.marks(raster: raster, region: region, sequence: sequence, detected: confirmed)
                        if !printed.isEmpty {
                            sequence.repeats.removeAll { $0.kind.hasPrefix("volta") }
                            sequence.repeats += printed
                        }
                        if rowIndex == 0, try ScoreRecognitionEndings.beginsSection(raster: raster, region: region, symbols: symbols) {
                            sequence.repeats.append(.init(after: 0, kind: "sectionStart"))
                        }
                        func rank(_ kind: String) -> Int { kind == "voltaStop" || kind == "voltaDiscontinue" ? 0 : kind == "repeatEnd" || kind == "repeatEndStart" ? 1 : 2 }
                        sequence.repeats.sort { $0.after == $1.after ? rank($0.kind) < rank($1.kind) : $0.after < $1.after }
                    }
                    contexts[part] = context; skippedGrace += sequence.skippedGrace
                    correctedRhythms += sequence.correctedRhythms
                    if part == 0 { repeatMarks += sequence.repeats.map { .init(after: $0.after + measureOffset, kind: $0.kind, numbers: $0.numbers) } }
                    for var note in sequence.notes {
                        note.beat += offset; note.page = page; note.staff += part * 2; note.measure += measureOffset
                        note.point = region.sourcePoint(note.point).applying(raster.pixelToPDF)
                        all.append(note)
                    }
                    partBars.append(sequence.bars)
                    if sequence.duration > rowDuration { rowBars = sequence.bars }
                    rowDuration = max(rowDuration, sequence.duration); rowMeasures = max(rowMeasures, sequence.measures)
                }
                guard rowDuration > 0 else { throw ScoreRecognitionFailure("有一行没有识别到可播放的音符，未生成不完整的试听。", "A system contained no playable notes. An incomplete preview was not saved.") }
                trace("page \(page) row \(rowIndex) decoded")
                // Independently decoded organ parts may disagree about barlines.
                // Keep their existing audition available; do not invent loop bounds.
                if partBars.contains(where: { part in
                    part.count != rowBars.count || zip(part, rowBars).contains { abs($0.start - $1.start) > 0.001 || abs($0.duration - $1.duration) > 0.001 }
                }) { consistentBars = false }
                for bar in rowBars {
                    bars.append(.init(measure: bar.measure + measureOffset, start: (offset + bar.start) * 60 / request.tempo, duration: bar.duration * 60 / request.tempo))
                }
                offset += rowDuration; measureOffset += rowMeasures
                guard offset * 60 / request.tempo <= 600, all.count <= 12_000 else { throw ScoreRecognitionFailure("本次试听过长，请减少选页。", "This preview is too long. Select fewer pages.") }
                progress((Double(pageIndex) + 0.82 + 0.08 * Double(rowIndex + 1) / Double(rows.count)) / Double(request.pages.count), ScoreAuditionText.value("第 \(page) 页 · 识别第 \(rowIndex + 1)/\(rows.count) 行", "Page \(page) · Reading system \(rowIndex + 1)/\(rows.count)"))
            }
            summaries.append("\(page):\(rows.count)")
        }
        guard all.count >= 4 else { throw ScoreRecognitionFailure("识别结果不足，请尝试更清晰的谱页。", "Too few notes were recognized. Try a clearer score.") }
        // The transformer is no longer needed while rendering/caching audio.
        models.encoder = nil; models.decoder = nil
        let configuration = "\(request.layout.rawValue)/\(request.tempo)/\(request.ornaments)/\(request.trillFromUpper)/\(request.ignoreColoredMarks)"
        let notation = ScoreRecognitionNotation(pages: request.pages, configuration: configuration, notes: all, bars: bars,
                                                marks: repeatMarks, beats: offset, consistentBars: consistentBars)
        try Task.checkCancellation()
        progress(0.93, ScoreAuditionText.value("生成本机试听音频", "Rendering audio on this device"))
        if let diagnostics {
            try JSONEncoder().encode(bracketRows).write(to: diagnostics.appendingPathExtension("brackets.json"), options: .atomic)
            try JSONEncoder().encode(all).write(to: diagnostics, options: .atomic)
            try JSONEncoder().encode(diagnosticRows).write(to: diagnostics.appendingPathExtension("symbols.json"), options: .atomic)
        }
        guard let document = CGPDFDocument(request.url as CFURL) else { throw ScoreAuditionError.invalid }
        let performance = request.ornaments
            ? ScoreAuditionText.value("已识别 \(graceCount) 个倚音、\(ornamentCount) 处装饰标记。", "Detected \(graceCount) grace notes and \(ornamentCount) ornament marks. ")
            : ScoreAuditionText.value("倚音与装饰音演奏已关闭。", "Grace notes and ornaments are off. ")
        let package = try renderNotation(notation, digest: request.digest, title: request.title, notice: performance,
                                         tempo: request.tempo, repeats: request.repeats, pageCount: document.numberOfPages, revision: ScoreAuditionPackage.revision(reviewRhythm:request.reviewRhythm))
        trace("audio rendered")
        progress(1, ScoreAuditionText.value("识别完成", "Recognition complete"))
        return package
    }
}
#endif
