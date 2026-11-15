import PDFKit
import PencilKit
import SwiftUI
import Combine

/// Turning handwritten digits into fingering marks after the pen pauses.
extension ScoreReaderController {
    func cancelFingering(clearRecent: Bool = true) {
        fingeringRevision += 1
        fingeringTask?.cancel()
        fingeringTask = nil
        fingeringComputation?.cancel()
        if clearRecent { recentFingering.removeAll(); newFingeringIDs.removeAll(); endedFingeringInput.removeAll() }
    }

    func scheduleFingering(_ canvas: ScoreCanvas, before: Data) {
        guard tool == .fingering, editing, let old = try? PKDrawing(data: before) else { return }
        let oldIDs = Set(old.strokes.map(\.fingeringID))
        let added = canvas.drawing.strokes.filter { !oldIDs.contains($0.fingeringID) }
        guard !added.isEmpty, canvas.drawing.strokes.count == old.strokes.count + added.count else { return }
        let page = canvas.pageNumber, now = Date()
        let currentIDs = Set(canvas.drawing.strokes.map(\.fingeringID))
        var recent = (recentFingering[page] ?? [:]).filter { now.timeIntervalSince($0.value) < 10 && currentIDs.contains($0.key) }
        for stroke in added { recent[stroke.fingeringID] = now }
        // A circle may be added well after its number was converted or reopened.
        // Pull in only our own intact fingerings inside that new ring.
        for ring in added where ScoreFingeringBeautifier.isCircle(ring) {
            for mark in fingeringMarks[page] ?? [] {
                if let ink = mark.strokes(in: canvas.drawing),
                   ring.renderBounds.contains(PKDrawing(strokes: ink.filter { $0.legacyFingeringID != mark.coverStrokeID }).bounds) {
                    for stroke in ink { recent[stroke.fingeringID] = now }
                }
            }
        }
        // Keep just a small local group even on a heavily annotated score.
        if recent.count > 24 { recent = Dictionary(uniqueKeysWithValues: recent.sorted { $0.value > $1.value }.prefix(24).map { ($0.key, $0.value) }) }
        recentFingering[page] = recent
        newFingeringIDs[page, default: []].formUnion(added.map(\.fingeringID))
        cancelFingering(clearRecent: false)
        let revision = fingeringRevision
        fingeringTask = Task { @MainActor [weak self, weak canvas] in
            do { try await Task.sleep(for: .milliseconds(850)) } catch { return }
            guard let self, let canvas, !Task.isCancelled, self.fingeringRevision == revision,
                  self.drawingBefore.isEmpty, self.pdfView != nil else { return }
            let snapshot = canvas.drawing
            self.endedFingeringInput.removeValue(forKey: page)
            let original = snapshot.dataRepresentation()
            let eligible = Set((self.recentFingering[page] ?? [:]).keys)
            let fresh = (self.newFingeringIDs[page] ?? []).intersection(eligible)
            let strokes = snapshot.strokes.filter { eligible.contains($0.fingeringID) }
            let recognize = self.fingeringRecognition
            let font = ScoreFingeringFont.saved(in: self.inkDefaults)
            let marks = self.fingeringMarks[page] ?? []
            let coverStyle = self.fingeringCoverEnabled ? self.fingeringCoverStyle : nil
            let fixedSize = self.fingeringSizeMode != .handwritten
            let fixedHeight = self.fingeringSizeMode == .fixed ? self.fixedFingeringHeight : self.fingeringHeight
            let previous = self.fingeringComputation
            // Serial, cancellable work off the main actor; never run a model in a
            // PencilKit callback or while delivering individual pen points.
            let computation = Task.detached(priority: .utility) {
                _ = await previous?.value
                guard !Task.isCancelled else { return [ScoreFingeringReplacement]() }
                // A newly drawn circle around a known digit does not need to
                // recognize the rendered typeface as if it were handwriting.
                let enclosed = Self.encloseKnownFingerings(strokes: strokes, fresh: fresh, marks: marks)
                let consumed = enclosed.reduce(into: Set<UUID>()) { $0.formUnion($1.sourceIDs) }
                let coveredIDs = Set(marks.filter { $0.cover != nil }.flatMap { $0.strokes(in: snapshot)?.map(\.fingeringID) ?? [] })
                let excluded = consumed.union(coveredIDs)
                let remaining = strokes.filter { !excluded.contains($0.fingeringID) }, newIDs = fresh.subtracting(excluded)
                let recognized: [ScoreFingeringReplacement]
                if let recognize { recognized = await recognize(remaining, newIDs) }
                else { recognized = await ScoreFingeringBeautifier.recognize(strokes: remaining, newIDs: newIDs,
                                                                            fingeringOnly: true, font: font) }
                let all = enclosed + recognized
                // When several numbers arrive together, learn the first one the
                // user wrote, not whichever result the recognizer returned first.
                let order = Dictionary(strokes.enumerated().map { ($0.element.fingeringID, $0.offset) }, uniquingKeysWith: min)
                let sorted = all.sorted { lhs, rhs in
                    (lhs.sourceIDs.compactMap { order[$0] }.min() ?? .max) < (rhs.sourceIDs.compactMap { order[$0] }.min() ?? .max)
                }
                let sized = fixedSize ? ScoreFingeringSizing.apply(sorted, height: fixedHeight) : sorted
                return sized.map { replacement in
                    guard !replacement.preservesDigitSize, let coverStyle else { return replacement }
                    return coverStyle.applying(to: replacement)
                }
            }
            self.fingeringComputation = computation
            let replacements = await withTaskCancellationHandler {
                await computation.value
            } onCancel: { computation.cancel() }
            // Keep the already computed result while a navigation gesture is
            // active. Previously a pinch/scroll silently discarded it forever.
            // Pen input, undo, tool changes and closing still cancel this task.
            while self.hasActiveNavigationGesture(around: canvas) {
                guard !Task.isCancelled, self.fingeringRevision == revision else { return }
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
            guard !Task.isCancelled, self.fingeringRevision == revision, self.tool == .fingering,
                  self.editing, self.drawingBefore.isEmpty, self.pdfView != nil,
                  canvas.drawing.dataRepresentation() == original else { return }
            self.newFingeringIDs[page]?.subtract(fresh)
            guard !replacements.isEmpty else { return }
            var result = snapshot.strokes
            var convertedIDs = Set<UUID>()
            for replacement in replacements {
                guard !replacement.drawing.strokes.isEmpty,
                      replacement.sourceIDs.isSubset(of: Set(result.map(\.fingeringID))),
                      let position = result.firstIndex(where: { replacement.sourceIDs.contains($0.fingeringID) }) else { continue }
                self.rememberFingeringSize(replacement)
                let time = replacement.sourceIDs.compactMap { self.recentFingering[page]?[$0] }.max() ?? now
                result.removeAll { replacement.sourceIDs.contains($0.fingeringID) }
                convertedIDs.formUnion(replacement.sourceIDs)
                result.insert(contentsOf: replacement.drawing.strokes, at: min(position, result.count))
                for id in replacement.sourceIDs { self.recentFingering[page]?.removeValue(forKey: id) }
                for stroke in replacement.drawing.strokes { self.recentFingering[page]?[stroke.fingeringID] = time }
                self.fingeringMarks[page, default: []].append(.init(drawing: replacement.drawing,
                    digit: replacement.digit, circled: replacement.circled, font: replacement.font, cover: replacement.cover))
                self.dirtyFingerings = true
            }
            let drawing = PKDrawing(strokes: result), after = drawing.dataRepresentation()
            guard original != after else { return }
            self.drawings[page] = after
            self.dirty[page] = after
            self.displayDrawing(drawing, on: page)
            // Writing a digit and its conversion are one step for the user: Undo
            // removes the digit instead of exposing the raw strokes (which then
            // joined the next digit's recognition and came back on its Undo).
            self.record(.drawing(page, self.popPenInput(page: page, endingAt: original, consuming: convertedIDs), after))
            self.queueSave()
        }
    }

    nonisolated static func encloseKnownFingerings(strokes: [PKStroke], fresh: Set<UUID>, marks: [ScoreFingeringMark]) -> [ScoreFingeringReplacement] {
        let drawing = PKDrawing(strokes: strokes)
        var consumed = Set<UUID>(), result: [ScoreFingeringReplacement] = []
        for ring in strokes where fresh.contains(ring.fingeringID) && ScoreFingeringBeautifier.isCircle(ring) {
            let matches = ScoreFingeringMark.active(in: drawing, marks: marks).filter { mark in
                guard !mark.circled, let ink = mark.glyphStrokes(in: drawing) else { return false }
                return ring.renderBounds.contains(PKDrawing(strokes: ink).bounds)
            }
            guard matches.count == 1, let mark = matches.first, let ink = mark.glyphStrokes(in: drawing),
                  let whole = mark.strokes(in: drawing) else { continue }
            let ids = Set(whole.map(\.fingeringID) + [ring.fingeringID])
            guard ids.isDisjoint(with: consumed) else { continue }
            let clean = ScoreFingeringBeautifier.addingCircle(to: ink, style: ring)
            consumed.formUnion(ids)
            let replacement = ScoreFingeringReplacement(sourceIDs: ids, drawing: clean, digit: mark.digit, circled: true,
                font: mark.font ?? .handwritten, preservesDigitSize: true)
            result.append(mark.cover?.applying(to: replacement) ?? replacement)
        }
        return result
    }
}
