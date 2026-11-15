import PDFKit
import PencilKit
import SwiftUI
import Combine

/// Voice-note pins on the page: saving, selecting and dragging.
extension ScoreReaderController {
    func voiceURL(_ note: ScoreVoiceNote) -> URL? {
        guard let score, let disk else { return nil }
        return disk.voiceURL(note.audioID, scoreID: score.id)
    }
    func newVoiceURL(_ note: ScoreVoiceNote) async throws -> URL {
        guard let score, let disk else { throw ScoreLibraryError.invalidPDF }
        return try await disk.prepareVoiceURL(note.audioID, scoreID: score.id)
    }
    func saveVoiceNote(_ note: ScoreVoiceNote) {
        let before = voiceNotes
        var after = before
        if let index = after.firstIndex(where: { $0.id == note.id }) { after[index] = note }
        else { after.append(note) }
        guard before != after else { return }
        setVoiceNotes(after); record(.voices(before, after))
    }
    func deleteVoiceNote(_ id: UUID) {
        let before = voiceNotes, after = voiceNotes.filter { $0.id != id }
        guard before != after else { return }
        selectedVoiceNote = nil
        setVoiceNotes(after); record(.voices(before, after))
    }
    func setVoiceNotes(_ notes: [ScoreVoiceNote]) {
        voiceNotes = notes; dirtyVoiceNotes = true; updateVoicePins(); queueSave()
    }
    func selectVoice(_ id: UUID, editing: Bool = false) {
        inkSelectionEditor.clear()
        voiceEditorExpanded = editing
        guard !voiceAudio.isBusy else { return }
        selectedVoiceNote = voiceNotes.first { $0.id == id }
    }
    func beginMovingVoice(_ id: UUID) {
        guard !voiceAudio.isBusy else { return }
        selectedVoiceNote = nil; editing = true; tool = .voice; movingVoiceID = id
    }
    private func voicePosition(at point: CGPoint) -> (Int, CGPoint)? {
        guard let view = pdfView, let document, let page = view.page(for: point, nearest: false) else { return nil }
        let local = view.convert(point, to: page), crop = page.bounds(for: .cropBox)
        guard crop.contains(local) else { return nil }
        return (document.index(for: page)+1, CGPoint(x: local.x-crop.minX, y: crop.maxY-local.y))
    }
    func voicePoint(_ note: ScoreVoiceNote) -> CGPoint? {
        guard let view = pdfView, let page = document?.page(at: note.page-1), view.visiblePages.contains(page) else { return nil }
        let crop = page.bounds(for: .cropBox)
        return view.convert(CGPoint(x: crop.minX+note.point.x, y: crop.maxY-note.point.y), from: page)
    }
    func voiceHit(at point: CGPoint) -> UUID? {
        voiceNotes.reversed().first { note in
            guard let p = voicePoint(note) else { return false }
            return hypot(p.x-point.x, p.y-point.y) <= 22
        }?.id
    }
    func updateVoicePins() {
        guard let view = pdfView else { return }
        let placements = voiceNotes.compactMap { stored -> (ScoreVoiceNote, CGPoint)? in
            let note = voiceDragPreview?.id == stored.id ? voiceDragPreview! : stored
            guard let p = voicePoint(note) else { return nil }
            return (note, voiceLayer.convert(p, from: view))
        }
        voiceLayer.update(placements, dragging: voiceDragPreview?.id)
        voiceLayer.superview?.bringSubviewToFront(voiceLayer)
    }
    @objc func tappedVoice(_ gesture: UITapGestureRecognizer) {
        guard !voiceAudio.isBusy, let view = pdfView else { return }
        let point = gesture.location(in: view)
        if let id = movingVoiceID, let (page, position) = voicePosition(at: point),
           var note = voiceNotes.first(where: { $0.id == id }) {
            note.page = page; note.point = position
            movingVoiceID = nil; saveVoiceNote(note); selectedVoiceNote = note
        } else if let id = voiceHit(at: point) { selectVoice(id) }
        else if editing && tool == .voice, let (page, position) = voicePosition(at: point) {
            voiceEditorExpanded = true
            selectedVoiceNote = ScoreVoiceNote(page: page, point: position, title: "", color: voiceColor)
        }
    }
    @objc func heldVoice(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .ended, !voiceDragDidMove, !voiceAudio.isBusy, let view = pdfView,
              let id = voiceHit(at: gesture.location(in: view)) else { return }
        selectVoice(id, editing: true)
    }

    @objc func draggedVoice(_ gesture: UIPanGestureRecognizer) {
        guard let view = pdfView else { return }
        if gesture.state == .began {
            guard !voiceAudio.isBusy, let id = voiceDragID,
                  let note = voiceNotes.first(where: { $0.id == id }) else { return }
            voiceDragPreview = note; voiceDragDidMove = true
            selectedVoiceNote = nil; movingVoiceID = nil
        }
        if [.began, .changed, .ended].contains(gesture.state), var note = voiceDragPreview {
            let finger = gesture.location(in: view)
            if let (page, position) = voicePosition(at: CGPoint(x: finger.x - voiceDragGrabOffset.x, y: finger.y - voiceDragGrabOffset.y)) {
                note.page = page; note.point = position; voiceDragPreview = note
            }
            // UIKit-only preview: do not publish the library or save on each finger movement.
            updateVoicePins()
        }
        if [.ended, .cancelled, .failed].contains(gesture.state) {
            let note = voiceDragPreview
            voiceDragPreview = nil; voiceDragID = nil
            if gesture.state == .ended, let note { saveVoiceNote(note) }
            updateVoicePins()
        }
    }
}
