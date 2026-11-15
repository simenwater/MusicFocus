import Foundation
import CryptoKit
import PDFKit
import PencilKit

/// A streaming, checksummed container. Restoration stages and validates every
/// file before adding new score IDs; an existing score is never overwritten.
enum ScoreLibraryBackup {
    static let magic = Data("MFSCORE1".utf8)
    struct Entry: Codable { var path: String; var size: UInt64; var hash: String }
    struct Header: Codable { var version = 1; var library: ScoreLibraryManifest; var entries: [Entry] }
    static func read(_ input: FileHandle, count: Int) throws -> Data {
        let data = try input.read(upToCount: count) ?? Data()
        guard data.count == count else { throw ScoreLibraryError.incompatibleLibrary }
        return data
    }
    static func validPath(_ path: String, ids: Set<String>) -> Bool {
        let parts = path.components(separatedBy: "/")
        return parts.count >= 2 && ids.contains(parts[0]) && !path.contains("\\") && !path.contains("\0") &&
            parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}

extension ScoreLibraryDisk {
    func exportBackup(_ manifest: ScoreLibraryManifest) throws -> URL {
        let fm = FileManager.default
        var entries: [ScoreLibraryBackup.Entry] = []
        for score in manifest.scores {
            let referencedAudio = Set(try voiceNotes(score.id).map { voiceURL($0.audioID, scoreID: score.id).standardizedFileURL.path })
            guard FileManager.default.fileExists(atPath: pdfURL(score.id).path),
                  referencedAudio.allSatisfy({ FileManager.default.fileExists(atPath: $0) }) else {
                throw ScoreLibraryError.incompatibleLibrary
            }
            guard let files = fm.enumerator(at: folder(score.id), includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) else {
                throw ScoreLibraryError.incompatibleLibrary
            }
            for case let file as URL in files {
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values.isSymbolicLink != true else { throw ScoreLibraryError.incompatibleLibrary }
                if values.isRegularFile == true {
                    // Old takes exist only to support the open reader's Undo.
                    // A shared backup includes the recordings still in the score.
                    if file.deletingLastPathComponent().lastPathComponent == "voice",
                       !referencedAudio.contains(file.standardizedFileURL.path) { continue }
                    entries.append(.init(path: String(file.path.dropFirst(root.path.count + 1)),
                        size: UInt64(values.fileSize ?? 0), hash: try Self.sha256(of: file)))
                }
            }
        }
        entries.sort { $0.path < $1.path }
        let header = try JSONEncoder().encode(ScoreLibraryBackup.Header(library: manifest, entries: entries))
        guard header.count <= 16_777_216 else { throw ScoreLibraryError.incompatibleLibrary }
        let directory = fm.temporaryDirectory.appendingPathComponent("MusicFocus-Backup-\(UUID())")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("MusicFocus.musicfocusbackup")
        fm.createFile(atPath: url.path, contents: nil)
        do {
            let out = try FileHandle(forWritingTo: url)
            defer { try? out.close() }
            try out.write(contentsOf: ScoreLibraryBackup.magic)
            var size = UInt64(header.count).bigEndian
            try withUnsafeBytes(of: &size) { try out.write(contentsOf: $0) }
            try out.write(contentsOf: header)
            for entry in entries {
                let input = try FileHandle(forReadingFrom: root.appendingPathComponent(entry.path))
                defer { try? input.close() }
                var hash = SHA256(), copied: UInt64 = 0
                while let bytes = try input.read(upToCount: 1_048_576), !bytes.isEmpty {
                    copied += UInt64(bytes.count); hash.update(data: bytes); try out.write(contentsOf: bytes)
                }
                guard copied == entry.size, hash.finalize().map({ String(format: "%02x", $0) }).joined() == entry.hash else {
                    throw ScoreLibraryError.incompatibleLibrary
                }
            }
            return url
        } catch { try? fm.removeItem(at: directory); throw error }
    }

    func restoreBackupCopies(_ source: URL) throws -> ScoreLibraryManifest {
        let fm = FileManager.default
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard try ScoreLibraryBackup.read(input, count: 8) == ScoreLibraryBackup.magic else { throw ScoreLibraryError.incompatibleLibrary }
        let length = try ScoreLibraryBackup.read(input, count: 8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        guard (1...16_777_216).contains(length) else { throw ScoreLibraryError.incompatibleLibrary }
        let header = try JSONDecoder().decode(ScoreLibraryBackup.Header.self, from: ScoreLibraryBackup.read(input, count: Int(length)))
        let ids = Set(header.library.scores.map { $0.id.uuidString })
        guard header.version == 1, header.library.version == 1, ids.count == header.library.scores.count,
              header.entries.count <= 100_000, Set(header.entries.map(\.path)).count == header.entries.count,
              header.entries.allSatisfy({ ScoreLibraryBackup.validPath($0.path, ids: ids) && $0.size <= 20_000_000_000 }) else {
            throw ScoreLibraryError.incompatibleLibrary
        }
        let stage = root.appendingPathComponent(".restore-\(UUID())")
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stage) }
        for entry in header.entries {
            let target = stage.appendingPathComponent(entry.path)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard fm.createFile(atPath: target.path, contents: nil) else { throw ScoreLibraryError.incompatibleLibrary }
            let out = try FileHandle(forWritingTo: target)
            defer { try? out.close() }
            var remaining = entry.size, hash = SHA256()
            while remaining > 0 {
                let bytes = try ScoreLibraryBackup.read(input, count: Int(min(remaining, 1_048_576)))
                hash.update(data: bytes); try out.write(contentsOf: bytes); remaining -= UInt64(bytes.count)
            }
            guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == entry.hash else { throw ScoreLibraryError.incompatibleLibrary }
        }
        guard (try input.read(upToCount: 1) ?? Data()).isEmpty else { throw ScoreLibraryError.incompatibleLibrary }
        // Validate the content before moving any folder into the live library.
        for score in header.library.scores {
            let folder = stage.appendingPathComponent(score.id.uuidString)
            guard score.pageCount > 0, let pdf = PDFDocument(url: folder.appendingPathComponent("score.pdf")),
                  !pdf.isLocked, pdf.pageCount == score.pageCount else { throw ScoreLibraryError.invalidPDF }
            let voiceFile = folder.appendingPathComponent("voice-notes.json")
            if fm.fileExists(atPath: voiceFile.path) {
                let notes = try JSONDecoder().decode([ScoreVoiceNote].self, from: Data(contentsOf: voiceFile))
                for note in notes {
                    _ = try note.validated(pageCount: score.pageCount)
                    guard fm.fileExists(atPath: folder.appendingPathComponent("voice/\(note.audioID).m4a").path) else { throw ScoreLibraryError.incompatibleLibrary }
                }
            }
            for file in try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) where file.pathExtension == "drawing" {
                _ = try PKDrawing(data: Data(contentsOf: file))
            }
        }
        var result = header.library, moved: [UUID] = [], mapping: [UUID: UUID] = [:]
        do {
            for index in result.scores.indices {
                let old = result.scores[index].id, new = UUID()
                try fm.moveItem(at: stage.appendingPathComponent(old.uuidString), to: folder(new))
                moved.append(new); mapping[old] = new; result.scores[index].id = new
            }
        } catch { for id in moved { try? fm.removeItem(at: folder(id)) }; throw error }
        result.visits = result.visits.compactMap { visit in
            guard let id = mapping[visit.scoreID] else { return nil }
            var copy = visit; copy.scoreID = id; return copy
        }
        return result
    }
}
