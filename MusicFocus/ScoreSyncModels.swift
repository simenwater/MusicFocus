import Foundation
import PencilKit

/// Everything a score's markings consist of: PencilKit ink per page (`N.drawing`),
/// edits to the PDF's own annotations and the fingering marks. The imported PDF
/// itself never travels — both iPads must already hold byte-identical copies.
struct ScoreAnnotationSnapshot: Codable, Equatable {
    var drawings: [Int: Data] = [:]
    var edits = ScoreAnnotationEdits()
    var fingerings: [Int: [ScoreFingeringMark]] = [:]

    /// What part of an incoming snapshot replaces the local one.
    enum Scope: Codable, Equatable {
        case everything
        case pages(Set<Int>)
        case edits
    }

    /// Pure merge shared by the open reader and the closed-library path.
    /// A page missing from `incoming` within the scope becomes blank.
    func merging(_ incoming: ScoreAnnotationSnapshot, scope: Scope) -> ScoreAnnotationSnapshot {
        var result = self
        let pages: Set<Int>
        switch scope {
        case .everything:
            result.edits = incoming.edits
            pages = Set(drawings.keys).union(incoming.drawings.keys).union(fingerings.keys).union(incoming.fingerings.keys)
        case .pages(let chosen): pages = chosen
        case .edits:
            result.edits = incoming.edits
            pages = []
        }
        for page in pages {
            result.drawings[page] = incoming.drawings[page]
            let marks = incoming.fingerings[page] ?? []
            result.fingerings[page] = marks.isEmpty ? nil : marks
        }
        return result
    }

    /// Received data is checked before it can reach the reader or the disk.
    func validated(pageCount: Int) throws -> ScoreAnnotationSnapshot {
        let range = 1...max(1, pageCount)
        guard drawings.keys.allSatisfy(range.contains), fingerings.keys.allSatisfy(range.contains),
              edits.version == 1,
              edits.covers.allSatisfy({ $0.isValid && range.contains($0.page) }),
              Set(edits.covers.map(\.id)).count == edits.covers.count,
              edits.items.keys.allSatisfy({ key in
                  let parts = key.split(separator: ":")
                  return parts.count == 2 && Int(parts[1]) != nil && Int(parts[0]).map(range.contains) == true
              }),
              fingerings.values.allSatisfy({ $0.allSatisfy { (1...5).contains($0.digit) } })
        else { throw ScoreSyncError.invalidPayload }
        for data in drawings.values { _ = try PKDrawing(data: data) }
        return self
    }

    var summary: ScoreAnnotationSummary {
        var summary = ScoreAnnotationSummary()
        for data in drawings.values {
            let strokes = (try? PKDrawing(data: data))?.strokes.count ?? 0
            if strokes > 0 { summary.inkPages += 1; summary.strokes += strokes }
        }
        summary.fingerings = fingerings.values.reduce(0) { $0 + $1.count }
        summary.pdfEdits = edits.items.count + edits.covers.count
        return summary
    }
}

/// Counts shown before anything is overwritten.
struct ScoreAnnotationSummary: Codable, Equatable {
    var inkPages = 0
    var strokes = 0
    var fingerings = 0
    var pdfEdits = 0
    var isEmpty: Bool { strokes == 0 && fingerings == 0 && pdfEdits == 0 }
    var text: String {
        isEmpty ? "score.sync.summaryEmpty".localized
            : "score.sync.summary".localizedFormat(inkPages, strokes, fingerings, pdfEdits)
    }
}

/// "Same base file" means the same imported PDF bytes (SHA-256), never the same title.
/// Saved annotations are only exchanged between identical files. A live lesson is
/// temporary, so it also accepts a file with the same page layout.
struct ScoreSyncIdentity: Codable, Equatable {
    var digest: String
    var pageCount: Int
    var title: String
    /// `ScoreLibraryDisk.layoutDigest`; nil from callers that only know the file hash.
    var layout: String? = nil
    func sameBaseFile(as other: ScoreSyncIdentity) -> Bool {
        !digest.isEmpty && digest == other.digest && pageCount == other.pageCount
    }
    func sameLayout(as other: ScoreSyncIdentity) -> Bool {
        if sameBaseFile(as: other) { return true }
        guard let layout, !layout.isEmpty else { return false }
        return layout == other.layout && pageCount == other.pageCount
    }
    /// What an internet room and its invitation are keyed by.
    var roomKey: String { layout ?? digest }
}

enum ScoreSyncReply: String, Codable {
    case tookYours, sendingMine, declined, differentFile, failed
}

enum ScoreSyncMessage: Codable, Equatable {
    case hello
    /// The initiator's annotations travel with the request so the receiver can
    /// show exactly what would change before choosing a direction.
    case syncRequest(id: UUID, snapshot: ScoreAnnotationSnapshot)
    case syncReply(id: UUID, reply: ScoreSyncReply)
    /// Receiver chose "update theirs from mine".
    case syncPush(id: UUID, snapshot: ScoreAnnotationSnapshot)
    case liveRequest(id: UUID)
    case liveReply(id: UUID, accepted: Bool)
    case liveFull(ScoreAnnotationSnapshot)
    case livePage(page: Int, drawing: Data?, fingerings: [ScoreFingeringMark])
    case liveEdits(ScoreAnnotationEdits)
    /// Where the presenter is looking, so the viewer can follow zoom and scrolling.
    case liveViewport(ScoreSyncViewport)
    /// The presenter's metronome settings; the clicks sound on the viewer's device,
    /// so they line up with what the viewer plays (also across a video call).
    case liveMetronome(ScoreSyncMetronome)
    case liveEnd
}

struct ScoreSyncMetronome: Codable, Equatable {
    var running: Bool
    var tempo: Int
    /// `TimeSignature.storageValue`, e.g. "7/8:2+2+3".
    var timeSignature: String
    var sound: String
    /// Optional so messages from earlier versions still decode.
    var subdivision: Int?

    init(running: Bool, tempo: Int, timeSignature: String, sound: String, subdivision: Int? = nil) {
        self.running = running; self.tempo = tempo; self.timeSignature = timeSignature; self.sound = sound
        self.subdivision = subdivision
    }

    init(_ metronome: Metronome) {
        self.init(running: metronome.isRunning, tempo: metronome.tempo,
                  timeSignature: metronome.timeSignature.storageValue, sound: metronome.sound.rawValue,
                  subdivision: metronome.subdivision.rawValue)
    }

    /// Unknown values (a newer app) keep the viewer's own setting.
    func apply(to metronome: Metronome) {
        metronome.tempo = tempo
        if let signature = TimeSignature(storageValue: timeSignature) { metronome.timeSignature = signature }
        if let sound = MetronomeSound(rawValue: sound) { metronome.sound = sound }
        if let division = MetronomeSubdivision(rawValue: subdivision ?? 1) { metronome.subdivision = division }
        if running != metronome.isRunning { running ? metronome.start() : metronome.stop() }
    }
}

/// The part of the score on the presenter's screen, independent of screen size:
/// a page and the visible rectangle as fractions of its crop box (origin top-left).
/// The rectangle may extend past the page (margins, the second page of a spread).
struct ScoreSyncViewport: Codable, Equatable {
    var page: Int
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var twoPages: Bool

    func validated(pageCount: Int) throws -> ScoreSyncViewport {
        let values = [x, y, width, height]
        guard (1...max(1, pageCount)).contains(page), values.allSatisfy(\.isFinite),
              width > 0.001, height > 0.001, width <= 50, height <= 50, abs(x) <= 50, abs(y) <= 50
        else { throw ScoreSyncError.invalidPayload }
        return self
    }

    /// Scrolling by less than this (a fraction of the page) is not worth sending.
    func isClose(to other: ScoreSyncViewport) -> Bool {
        page == other.page && twoPages == other.twoPages
            && abs(x - other.x) < 0.002 && abs(y - other.y) < 0.002
            && abs(width - other.width) < 0.002 && abs(height - other.height) < 0.002
    }
}

/// Every message names the base file, so nothing is applied to a different PDF.
struct ScoreSyncEnvelope: Codable, Equatable {
    // Older peers ignore unknown rectangle fields. Refuse that connection
    // rather than silently dropping covers on the next two-way synchronization.
    static let schema = 2
    var schema = ScoreSyncEnvelope.schema
    var app: String
    var identity: ScoreSyncIdentity
    var message: ScoreSyncMessage
}

enum ScoreSyncError: LocalizedError {
    case invalidPayload, newerSchema, differentFile, saveFailed
    var errorDescription: String? {
        switch self {
        case .saveFailed: return "score.annotationSaveError".localized
        case .invalidPayload: return "score.sync.invalidPayload".localized
        case .newerSchema: return "score.sync.newerVersion".localized
        case .differentFile: return "score.sync.differentFile".localized
        }
    }
}

/// Binary property list, LZFSE-compressed: PencilKit data stays raw (no base64).
enum ScoreSyncCodec {
    static let maximumSize = 64 * 1_048_576
    static var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?" }

    static func encode(_ envelope: ScoreSyncEnvelope) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try (encoder.encode(envelope) as NSData).compressed(using: .lzfse) as Data
    }

    static func decode(_ data: Data) throws -> ScoreSyncEnvelope {
        guard data.count <= maximumSize,
              let raw = try? (data as NSData).decompressed(using: .lzfse) as Data, raw.count <= maximumSize * 4
        else { throw ScoreSyncError.invalidPayload }
        // Read the schema first so a newer app gets a clear "update" message.
        struct Header: Decodable { var schema: Int }
        guard let header = try? PropertyListDecoder().decode(Header.self, from: raw) else { throw ScoreSyncError.invalidPayload }
        guard header.schema <= ScoreSyncEnvelope.schema else { throw ScoreSyncError.newerSchema }
        guard let envelope = try? PropertyListDecoder().decode(ScoreSyncEnvelope.self, from: raw) else { throw ScoreSyncError.invalidPayload }
        return envelope
    }
}
