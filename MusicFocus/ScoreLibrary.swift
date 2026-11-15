import Foundation
import PDFKit
import PencilKit
import SwiftUI
import CryptoKit

struct LibraryScore: Identifiable, Codable, Equatable {
    var id: UUID
    var title: String
    var pageCount: Int
    var added: Date = Date()
    var lastOpened: Date?
    var lastPage: Int = 1
    var isFavorite = false
    var nextPracticePage: Int? = nil
    var nextPracticeNote: String? = nil
    var sourceDigest: String? = nil
    var layoutDigest: String? = nil
}

struct ScoreLibraryManifest: Codable {
    var version = 1
    var scores: [LibraryScore] = []
    var visits: [ScoreReadingVisit] = []
}

enum ScoreLibraryError: LocalizedError {
    case invalidPDF, incompatibleLibrary
    var errorDescription: String? {
        switch self {
        case .invalidPDF: return "score.invalidPDF".localized
        case .incompatibleLibrary: return "score.incompatibleLibrary".localized
        }
    }
}

/// Serial disk access keeps PDF copying, thumbnails and atomic writes off the UI/audio threads.
actor ScoreLibraryDisk {
    nonisolated let root: URL
    private var latestRevision = -1
    init(root: URL) { self.root = root }
    nonisolated func folder(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    nonisolated func pdfURL(_ id: UUID) -> URL { folder(id).appendingPathComponent("score.pdf") }
    nonisolated func coverURL(_ id: UUID) -> URL { folder(id).appendingPathComponent("cover.jpg") }

    func load() throws -> ScoreLibraryManifest {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("library.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return ScoreLibraryManifest() }
        let manifest = try JSONDecoder().decode(ScoreLibraryManifest.self, from: Data(contentsOf: url))
        guard manifest.version == 1 else { throw ScoreLibraryError.incompatibleLibrary }
        return manifest
    }

    func save(_ manifest: ScoreLibraryManifest, revision: Int) throws {
        guard revision >= latestRevision else { return }
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: root.appendingPathComponent("library.json"), options: .atomic)
        latestRevision = revision
    }

    func importPDF(_ source: URL, reusing existing: [LibraryScore] = []) throws -> LibraryScore {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let id = UUID()
        let directory = folder(id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            var coordinationError: NSError?
            var copyError: Error?
            NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { readable in
                do { try FileManager.default.copyItem(at: readable, to: pdfURL(id)) }
                catch { copyError = error }
            }
            if let error = coordinationError ?? (copyError as NSError?) { throw error }
            let digest = try Self.sha256(of: pdfURL(id))
            if let saved = existing.first(where: {
                $0.sourceDigest == digest && FileManager.default.fileExists(atPath: pdfURL($0.id).path)
            }) {
                try FileManager.default.removeItem(at: directory)
                return saved
            }
            guard let document = PDFDocument(url: pdfURL(id)), !document.isLocked,
                  document.pageCount > 0, let first = document.page(at: 0) else { throw ScoreLibraryError.invalidPDF }
            if let cover = first.thumbnail(of: CGSize(width: 220, height: 300), for: .cropBox).jpegData(compressionQuality: 0.75) {
                try cover.write(to: coverURL(id), options: .atomic)
            }
            return LibraryScore(id: id, title: source.deletingPathExtension().lastPathComponent,
                                pageCount: document.pageCount, sourceDigest: digest,
                                layoutDigest: Self.layoutDigest(of: document))
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    /// The library copy is never modified, so its hash identifies the imported bytes.
    nonisolated static func sha256(of url: URL) throws -> String {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var hash = SHA256()
        while let bytes = try input.read(upToCount: 1_048_576), !bytes.isEmpty { hash.update(data: bytes) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Page count plus every page's crop size and rotation. Annotations and the
    /// shared viewport are positioned by page and crop box, so two files with the
    /// same layout can share a live lesson even when their bytes differ (a copy
    /// exported with annotations, or one re-saved by another app).
    nonisolated static func layoutDigest(of document: PDFDocument) -> String {
        var text = "layout1|\(document.pageCount)"
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { text += "|-"; continue }
            let crop = page.bounds(for: .cropBox)
            text += "|\(Int(crop.width.rounded()))x\(Int(crop.height.rounded()))r\((page.rotation % 360 + 360) % 360)"
        }
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    nonisolated static func layoutDigest(of url: URL) throws -> String {
        guard let document = PDFDocument(url: url), document.pageCount > 0 else { throw ScoreLibraryError.invalidPDF }
        return layoutDigest(of: document)
    }

    func removeFiles(_ id: UUID) throws { try FileManager.default.removeItem(at: folder(id)) }

    func drawings(_ id: UUID) throws -> [Int: Data] {
        var result: [Int: Data] = [:]
        for url in try FileManager.default.contentsOfDirectory(at: folder(id), includingPropertiesForKeys: nil)
        where url.pathExtension == "drawing" {
            if let page = Int(url.deletingPathExtension().lastPathComponent) { result[page] = try Data(contentsOf: url) }
        }
        return result
    }

    func annotationEdits(_ id: UUID) throws -> ScoreAnnotationEdits {
        let url = folder(id).appendingPathComponent("annotation-edits.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return .init() }
        let edits = try JSONDecoder().decode(ScoreAnnotationEdits.self, from: Data(contentsOf: url))
        guard edits.version == 1 else { throw ScoreLibraryError.incompatibleLibrary }
        return edits
    }

    func saveAnnotationEdits(_ edits: ScoreAnnotationEdits, scoreID: UUID) throws {
        try JSONEncoder().encode(edits).write(to: folder(scoreID).appendingPathComponent("annotation-edits.json"), options: .atomic)
    }

    func fingerings(_ id: UUID) throws -> [Int: [ScoreFingeringMark]] {
        let url = folder(id).appendingPathComponent("fingerings.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        return try JSONDecoder().decode([Int: [ScoreFingeringMark]].self, from: Data(contentsOf: url))
    }

    func saveFingerings(_ marks: [Int: [ScoreFingeringMark]], scoreID: UUID) throws {
        try JSONEncoder().encode(marks).write(to: folder(scoreID).appendingPathComponent("fingerings.json"), options: .atomic)
    }

    func saveDrawing(_ data: Data, scoreID: UUID, page: Int) throws {
        try data.write(to: folder(scoreID).appendingPathComponent("\(page).drawing"), options: .atomic)
    }
}

@MainActor
final class ScoreLibrary: ObservableObject {
    @Published private(set) var scores: [LibraryScore] = []
    @Published private(set) var visits: [ScoreReadingVisit] = [] { didSet { visitsRevision += 1 } }
    @Published private(set) var visitsRevision = 0
    @Published private(set) var isLoaded = false
    @Published private(set) var isImporting = false
    @Published var errorMessage: String?
    @Published private(set) var externalRequestID: UUID?
    private(set) var externalWindowID: UUID?
    @Published var pendingRoomInvite: ScoreRoomInvitation?
    @Published var externalLibraryRequested = false
    @Published var pendingExternalScore: LibraryScore?
    let disk: ScoreLibraryDisk
    private var revision = 0
    private var loadingTask: Task<Void, Never>?
    private var importTask: Task<[LibraryScore], Never>?
    private var importGeneration = UUID()
    private var pendingImports = 0
    private var currentVisit: ScoreReadingVisit?

    init(root: URL? = nil) {
        let root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ScoreLibrary", isDirectory: true)
        disk = ScoreLibraryDisk(root: root)
    }

    func load() async {
        guard !isLoaded else { return }
        if let loadingTask { await loadingTask.value; return }
        let task = Task { @MainActor in
            do {
                let manifest = try await self.disk.load()
                self.scores = manifest.scores
                self.visits = manifest.visits
                self.isLoaded = true
            } catch { self.errorMessage = error.localizedDescription }
        }
        loadingTask = task
        await task.value
        loadingTask = nil
    }

    var orderedScores: [LibraryScore] {
        scores.sorted {
            if $0.isFavorite != $1.isFavorite { return $0.isFavorite }
            return ($0.lastOpened ?? $0.added) > ($1.lastOpened ?? $1.added)
        }
    }

    /// Reading history drives the default shelf, without a favorites boost or
    /// treating a newly imported (but unopened) score as recently practiced.
    var recentlyOpenedScores: [LibraryScore] {
        scores.filter { $0.lastOpened != nil }.sorted {
            ($0.lastOpened ?? .distantPast) > ($1.lastOpened ?? .distantPast)
        }
    }

    /// Resume is independent of favorites and newly imported, unopened scores.
    var mostRecentScore: LibraryScore? {
        scores.filter { $0.lastOpened != nil }.max {
            $0.lastOpened! < $1.lastOpened!
        }
    }

    func searchScores(_ query: String) -> [LibraryScore] {
        orderedScores.filter { $0.title.localizedStandardContains(query) }
    }

    @discardableResult
    func setNextPracticeNote(_ id: UUID, note: String) async -> Bool {
        await setNextPracticePlan(id, note: note, page: scores.first { $0.id == id }?.nextPracticePage)
    }

    @discardableResult
    func setNextPracticePlan(_ id: UUID, note: String, page: Int?) async -> Bool {
        guard let index = scores.firstIndex(where: { $0.id == id }) else { return false }
        let previous = scores[index]
        if let page, (page < 1 || page > previous.pageCount) { return false }
        let trimmed = String(note.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
        let updated = trimmed.isEmpty ? nil : trimmed
        scores[index].nextPracticeNote = updated
        scores[index].nextPracticePage = page
        guard await persist() else {
            if let index = scores.firstIndex(where: { $0.id == id }),
               scores[index].nextPracticeNote == updated, scores[index].nextPracticePage == page {
                scores[index].nextPracticeNote = previous.nextPracticeNote
                scores[index].nextPracticePage = previous.nextPracticePage
            }
            return false
        }
        return true
    }

    @discardableResult
    func importFiles(_ urls: [URL], reusingExisting: Bool = false) async -> [LibraryScore] {
        // Acquire provider access before waiting for startup/other imports.
        let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
        let previous = importTask
        let generation = UUID()
        importGeneration = generation
        pendingImports += 1
        isImporting = true
        let task = Task { @MainActor in
            _ = await previous?.value
            await self.load()
            guard self.isLoaded else { return [LibraryScore]() }
            return await self.performImport(urls, reusingExisting: reusingExisting)
        }
        importTask = task
        let imported = await task.value
        pendingImports -= 1
        isImporting = pendingImports > 0
        if importGeneration == generation { importTask = nil }
        return imported
    }

    private func performImport(_ urls: [URL], reusingExisting: Bool) async -> [LibraryScore] {
        var imported: [LibraryScore] = []
        var added = Set<UUID>()
        for url in urls {
            do {
                let score = try await disk.importPDF(url, reusing: reusingExisting ? scores : [])
                if !scores.contains(where: { $0.id == score.id }) {
                    scores.append(score)
                    added.insert(score.id)
                }
                imported.append(score)
            }
            catch { errorMessage = error.localizedDescription }
        }
        guard !imported.isEmpty else { return [] }
        guard await persist() else {
            // Do not advertise an unsaved import as successful. Keep copied
            // files recoverable if disk writes fail; never remove source files.
            scores.removeAll { added.contains($0.id) }
            _ = await persist()
            return []
        }
        return imported
    }

    func openRoomInvitation(_ invitation: ScoreRoomInvitation, windowID: UUID) {
        guard ScoreSyncAvailability.internet else {
            pendingRoomInvite = nil
            errorMessage = "score.sync.remoteDisabled".localized
            return
        }
        externalWindowID = windowID
        pendingExternalScore = nil
        pendingRoomInvite = invitation
        Task { await ensureLayoutDigests() }
        externalLibraryRequested = true
        externalRequestID = UUID()
    }

    /// SwiftUI delivers document URLs for both cold launch and a running app.
    /// The task outlives the view callback and only opens a durably saved copy.
    @discardableResult
    func openExternalFile(_ url: URL, windowID: UUID? = nil) -> Task<Void, Never>? {
        guard url.isFileURL else { return nil }
        let request = UUID()
        if externalWindowID != windowID { pendingRoomInvite = nil }
        externalWindowID = windowID
        errorMessage = nil
        pendingExternalScore = nil
        externalLibraryRequested = true
        externalRequestID = request
        let access = url.startAccessingSecurityScopedResource()
        return Task { @MainActor in
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let imported = await self.importFiles([url], reusingExisting: true)
            guard self.externalRequestID == request, let score = imported.first else { return }
            self.pendingExternalScore = score
        }
    }

    func handlesExternalFiles(in windowID: UUID?) -> Bool {
        externalWindowID == windowID
    }

    func rename(_ id: UUID, title: String) async {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let index = scores.firstIndex(where: { $0.id == id }) else { return }
        scores[index].title = title
        await persist()
    }

    func favorite(_ id: UUID) async {
        guard let index = scores.firstIndex(where: { $0.id == id }) else { return }
        scores[index].isFavorite.toggle()
        await persist()
    }

    func remove(_ id: UUID) async {
        // History retains its title/page snapshots after a PDF is removed.
        let previous = scores
        scores.removeAll { $0.id == id }
        guard await persist() else { scores = previous; return }
        do { try await disk.removeFiles(id) } catch { errorMessage = error.localizedDescription }
    }

    func beginViewing(_ score: LibraryScore, pages: [Int], at date: Date = Date()) {
        #if DEBUG
        // Hardware UI validation must not add test reading time to a real library.
        if ProcessInfo.processInfo.arguments.contains("-musicfocus-read-only-validation") { return }
        #endif
        let pages = Array(Set(pages.filter { (1...score.pageCount).contains($0) })).sorted()
        guard !pages.isEmpty else { return }
        if currentVisit?.scoreID == score.id, currentVisit?.pages == pages { return }
        endViewing(at: date)
        currentVisit = ScoreReadingVisit(scoreID: score.id, title: score.title, pages: pages, start: date, end: date)
        if let index = scores.firstIndex(where: { $0.id == score.id }) {
            scores[index].lastOpened = date
            scores[index].lastPage = pages[0]
        }
        Task { await persist() }
    }

    func endViewing(at date: Date = Date()) {
        guard var visit = currentVisit else { return }
        currentVisit = nil
        if date > visit.start {
            visit.end = date
            visits.append(visit)
            Task { await persist() }
        }
    }

    /// Scores imported before `sourceDigest` existed get it on first use (nearby sync).
    func ensureSourceDigest(_ id: UUID) async throws -> String {
        guard let score = scores.first(where: { $0.id == id }) else { throw ScoreLibraryError.invalidPDF }
        if let digest = score.sourceDigest { return digest }
        let url = disk.pdfURL(id)
        let digest = try await Task.detached(priority: .userInitiated) { try ScoreLibraryDisk.sha256(of: url) }.value
        if let index = scores.firstIndex(where: { $0.id == id }) { scores[index].sourceDigest = digest }
        await persist()
        return digest
    }

    /// Scores imported before `layoutDigest` existed get it on first use.
    func ensureLayoutDigest(_ id: UUID) async throws -> String {
        guard let score = scores.first(where: { $0.id == id }) else { throw ScoreLibraryError.invalidPDF }
        if let digest = score.layoutDigest { return digest }
        let url = disk.pdfURL(id)
        let digest = try await Task.detached(priority: .userInitiated) { try ScoreLibraryDisk.layoutDigest(of: url) }.value
        if let index = scores.firstIndex(where: { $0.id == id }) { scores[index].layoutDigest = digest }
        await persist()
        return digest
    }

    /// A room invitation names a layout, so every score needs one to be offered as a match.
    func ensureLayoutDigests() async {
        for id in scores.filter({ $0.layoutDigest == nil }).map(\.id) { _ = try? await ensureLayoutDigest(id) }
    }

    func exportBackup() async throws -> URL {
        await load()
        guard isLoaded, !isImporting else { throw ScoreLibraryError.incompatibleLibrary }
        return try await disk.exportBackup(.init(scores: scores, visits: visits))
    }

    func restoreBackupCopies(_ url: URL) async throws -> Int {
        await load()
        guard isLoaded, !isImporting else { throw ScoreLibraryError.incompatibleLibrary }
        let added = try await disk.restoreBackupCopies(url)
        let ids = Set(added.scores.map(\.id))
        scores += added.scores; visits += added.visits
        if await persist() { return added.scores.count }
        scores.removeAll { ids.contains($0.id) }; visits.removeAll { ids.contains($0.scoreID) }
        for id in ids { try? await disk.removeFiles(id) }
        throw ScoreLibraryError.incompatibleLibrary
    }

    @discardableResult
    func persist() async -> Bool {
        guard isLoaded else { return false }
        revision += 1
        let version = revision
        let manifest = ScoreLibraryManifest(scores: scores, visits: visits)
        do { try await disk.save(manifest, revision: version); return true }
        catch { errorMessage = error.localizedDescription; return false }
    }
}
