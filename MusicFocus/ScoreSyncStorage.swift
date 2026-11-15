import Foundation
import PencilKit

/// A copy of a score's annotations taken right before nearby sync replaced them.
struct ScoreSyncBackup: Codable, Equatable, Identifiable {
    enum Reason: String, Codable { case sync, live, restore }
    var id = UUID()
    var date: Date
    var reason: Reason
    var peer: String
    var summary: ScoreAnnotationSummary
}

/// Where synced annotations are read from and written to. The open reader owns
/// the live state (including unsaved ink); the disk path serves closed scores and tests.
@MainActor
protocol ScoreSyncTarget: AnyObject {
    func currentAnnotations() async throws -> ScoreAnnotationSnapshot
    /// `durable` waits until the result is on disk (full sync, restore);
    /// live updates only queue the usual save.
    func replaceAnnotations(with snapshot: ScoreAnnotationSnapshot, durable: Bool) async throws
    /// What is on screen (presenter) and showing the presenter's view (viewer).
    /// Only an open reader has a view.
    func currentViewport() -> ScoreSyncViewport?
    func showViewport(_ viewport: ScoreSyncViewport)
}

extension ScoreSyncTarget {
    func currentViewport() -> ScoreSyncViewport? { nil }
    func showViewport(_ viewport: ScoreSyncViewport) {}
}

extension ScoreLibraryDisk {
    static let maximumSyncBackups = 10

    func annotationSnapshot(_ id: UUID) throws -> ScoreAnnotationSnapshot {
        .init(drawings: try drawings(id), edits: try annotationEdits(id), fingerings: try fingerings(id))
    }

    /// Writes through the regular save functions. Pages that lost their ink get an
    /// empty drawing, the same as erasing everything on that page in the reader.
    func replaceAnnotations(_ id: UUID, with snapshot: ScoreAnnotationSnapshot) throws {
        let current = try annotationSnapshot(id)
        let empty = PKDrawing().dataRepresentation()
        for page in Set(current.drawings.keys).union(snapshot.drawings.keys) {
            let data = snapshot.drawings[page] ?? empty
            if (current.drawings[page] ?? empty) != data { try saveDrawing(data, scoreID: id, page: page) }
        }
        if current.fingerings != snapshot.fingerings { try saveFingerings(snapshot.fingerings, scoreID: id) }
        if current.edits != snapshot.edits { try saveAnnotationEdits(snapshot.edits, scoreID: id) }
    }

    nonisolated func syncBackupFolder(_ id: UUID) -> URL {
        folder(id).appendingPathComponent("sync-backups", isDirectory: true)
    }

    /// Keeps the newest few. Backups live inside the score folder and are removed with it.
    @discardableResult
    func backupAnnotations(_ snapshot: ScoreAnnotationSnapshot, scoreID: UUID, reason: ScoreSyncBackup.Reason,
                           peer: String, date: Date = Date()) throws -> ScoreSyncBackup {
        let directory = syncBackupFolder(scoreID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let backup = ScoreSyncBackup(date: date, reason: reason, peer: peer, summary: snapshot.summary)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(snapshot).write(to: directory.appendingPathComponent("\(backup.id.uuidString).snapshot"), options: .atomic)
        try JSONEncoder().encode(backup).write(to: directory.appendingPathComponent("\(backup.id.uuidString).json"), options: .atomic)
        for old in try syncBackups(scoreID).dropFirst(Self.maximumSyncBackups) {
            for ext in ["snapshot", "json"] {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(old.id.uuidString).\(ext)"))
            }
        }
        return backup
    }

    /// Newest first.
    func syncBackups(_ scoreID: UUID) throws -> [ScoreSyncBackup] {
        let directory = syncBackupFolder(scoreID)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(ScoreSyncBackup.self, from: Data(contentsOf: $0)) }
            .sorted { $0.date > $1.date }
    }

    func backupSnapshot(_ backup: ScoreSyncBackup, scoreID: UUID) throws -> ScoreAnnotationSnapshot {
        let url = syncBackupFolder(scoreID).appendingPathComponent("\(backup.id.uuidString).snapshot")
        return try PropertyListDecoder().decode(ScoreAnnotationSnapshot.self, from: Data(contentsOf: url))
    }
}

/// A score that is not open in a reader.
@MainActor
final class ScoreSyncDiskTarget: ScoreSyncTarget {
    let disk: ScoreLibraryDisk
    let scoreID: UUID
    init(disk: ScoreLibraryDisk, scoreID: UUID) { self.disk = disk; self.scoreID = scoreID }
    func currentAnnotations() async throws -> ScoreAnnotationSnapshot { try await disk.annotationSnapshot(scoreID) }
    func replaceAnnotations(with snapshot: ScoreAnnotationSnapshot, durable: Bool) async throws {
        try await disk.replaceAnnotations(scoreID, with: snapshot)
    }
}

/// The open reader: replaces its in-memory state, refreshes visible pages and
/// clears its undo history (the backup is the safety net).
extension ScoreReaderController: ScoreSyncTarget {
    func currentAnnotations() async throws -> ScoreAnnotationSnapshot { syncSnapshot() }
    func replaceAnnotations(with snapshot: ScoreAnnotationSnapshot, durable: Bool) async throws {
        replaceSyncedAnnotations(with: snapshot)
        if durable, !(await flush()) { throw ScoreSyncError.saveFailed }
    }
    func currentViewport() -> ScoreSyncViewport? { syncViewport() }
    func showViewport(_ viewport: ScoreSyncViewport) { followViewport(viewport) }
}
