import Foundation
import PDFKit

struct ScoreVoiceNote: Codable, Equatable, Identifiable {
    var id = UUID()
    var page: Int
    /// Crop-box coordinates, top-left origin; independent of display zoom.
    var point: CGPoint
    var title: String
    var color: ScoreAnnotationColor
    var audioID = UUID()
    var duration: TimeInterval = 0
    var created = Date()

    func validated(pageCount: Int) throws -> Self {
        guard pageCount > 0, (1...pageCount).contains(page), point.x.isFinite, point.y.isFinite,
              point.x >= 0, point.y >= 0, duration.isFinite, duration >= 0, duration < 31_536_000,
              [color.red, color.green, color.blue].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
            throw ScoreLibraryError.incompatibleLibrary
        }
        return self
    }
}

extension ScoreLibraryDisk {
    nonisolated func voiceURL(_ audioID: UUID, scoreID: UUID) -> URL {
        folder(scoreID).appendingPathComponent("voice", isDirectory: true).appendingPathComponent(audioID.uuidString + ".m4a")
    }
    func prepareVoiceURL(_ audioID: UUID, scoreID: UUID) throws -> URL {
        let url = voiceURL(audioID, scoreID: scoreID)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return url
    }
    func voiceNotes(_ scoreID: UUID) throws -> [ScoreVoiceNote] {
        let url = folder(scoreID).appendingPathComponent("voice-notes.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([ScoreVoiceNote].self, from: Data(contentsOf: url))
    }
    func saveVoiceNotes(_ notes: [ScoreVoiceNote], scoreID: UUID) throws {
        try JSONEncoder().encode(notes).write(to: folder(scoreID).appendingPathComponent("voice-notes.json"), options: .atomic)
        // Re-recorded/deleted clips stay available to Undo and to library backups.
        // Never remove a blob as a side effect of saving or receiving a sync packet.
    }
}

/// Pins are drawn in screen coordinates. Touches continue into PDFKit so a
/// two-finger pinch starting on a speaker cannot become an annotation edit.
final class ScoreVoicePinLayer: UIView {
    private var pins: [UUID: ScoreVoicePin] = [:]
    var onActivate: ((UUID) -> Void)?
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
    func update(_ placements: [(ScoreVoiceNote, CGPoint)], dragging: UUID? = nil) {
        let ids = Set(placements.map { $0.0.id })
        for id in pins.keys.filter({ !ids.contains($0) }) { pins.removeValue(forKey: id)?.removeFromSuperview() }
        for (note, point) in placements {
            let pin = pins[note.id] ?? ScoreVoicePin()
            if pins[note.id] == nil { pins[note.id] = pin; addSubview(pin) }
            pin.transform = .identity
            pin.frame = CGRect(x: point.x-22, y: point.y-22, width: 44, height: 44)
            pin.tintColor = note.color.uiColor
            pin.transform = note.id == dragging ? CGAffineTransform(scaleX: 1.15, y: 1.15) : .identity
            pin.layer.shadowColor = UIColor.black.cgColor
            pin.layer.shadowOpacity = note.id == dragging ? 0.2 : 0
            pin.layer.shadowRadius = 4
            pin.layer.shadowOffset = CGSize(width: 0, height: 2)
            pin.accessibilityLabel = note.title.isEmpty ? "score.voice".localized : note.title
            pin.accessibilityValue = String(format: "%d:%02d", Int(note.duration)/60, Int(note.duration)%60)
            pin.accessibilityIdentifier = "scoreVoicePin-\(note.id.uuidString)"
            pin.activate = { [weak self] in self?.onActivate?(note.id) }
        }
    }
}

private final class ScoreVoicePin: UIView {
    var activate: (() -> Void)?
    private let image = UIImageView(image: UIImage(systemName: "speaker.wave.2.fill"))
    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true; accessibilityTraits = .button
        image.contentMode = .scaleAspectFit
        image.frame = CGRect(x: 10, y: 10, width: 24, height: 24)
        image.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.9)
        image.layer.cornerRadius = 6
        addSubview(image)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func accessibilityActivate() -> Bool { activate?(); return true }
}

/// A second finger always gives control back to PDFKit's pinch gesture.
final class ScoreVoiceHoldRecognizer: UILongPressGestureRecognizer {
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if (event.allTouches?.filter { $0.phase != .ended && $0.phase != .cancelled }.count ?? 0) > 1 {
            state = state == .possible ? .failed : .cancelled
            return
        }
        super.touchesBegan(touches, with: event)
    }
}

/// Starts on a pin without a hold delay; another finger cancels the preview
/// so PDFKit can take over zooming without saving an accidental move.
final class ScoreVoicePanRecognizer: UIPanGestureRecognizer {
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if (event.allTouches?.filter { $0.phase != .ended && $0.phase != .cancelled }.count ?? 0) > 1 {
            state = state == .possible ? .failed : .cancelled
            return
        }
        super.touchesBegan(touches, with: event)
    }
    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool {
        if preventedGestureRecognizer is UIPinchGestureRecognizer { return false }
        return super.canPrevent(preventedGestureRecognizer)
    }
}
