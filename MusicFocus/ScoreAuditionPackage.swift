#if DEBUG || MUSICFOCUS_HOMR
import Foundation

/// Development interchange for local or imported recognition results.
/// Recognition-enabled configurations of the main app bundle the runtime and model assets.
struct ScoreAuditionPackage: Codable, Sendable {
    struct Cue: Codable, Sendable {
        var time: Double
        var duration: Double
        var page: Int
        var staff: Int
        var measure: Int
        /// PDF user-space points (bottom-left origin), not raster pixels.
        var x: Double
        var y: Double
        var sourceMeasure: Int? = nil
        var printedMeasure: Int { sourceMeasure ?? measure }
    }
    struct Bar: Codable, Sendable {
        var measure: Int
        var start: Double
        var duration: Double
        var end: Double { start + duration }
    }
    var version: Int = 1
    var sourceSHA256: String
    var title: String
    var notice: String
    var tempo: Double
    var duration: Double
    var cues: [Cue]
    var audio: Data
    /// Identical timeline/duration with clicks mixed in offline. Switching mixes
    /// cannot introduce a second metronome clock or cumulative timing drift.
    var audioWithClicks: Data?
    /// Explicit boundaries include leading/trailing rests. Older previews can
    /// still play, but need re-recognition before selecting whole-bar loops.
    var bars: [Bar]? = nil
    var recognitionRevision: Int? = nil
    var performsRepeats: Bool? = nil
    var notation: ScoreRecognitionNotation? = nil
    static let currentRecognitionRevision = revision(reviewRhythm: true)
    static func revision(reviewRhythm: Bool) -> Int {
        #if DEBUG && MUSICFOCUS_HOMR
        return reviewRhythm ? 12 : 11
        #elseif MUSICFOCUS_HOMR
        return 11
        #else
        return 8
        #endif
    }

    static let maxBytes = 32 * 1_024 * 1_024
    static let cacheBudget = 128 * 1_024 * 1_024

    func validate(digest: String, pageCount: Int) throws {
        guard sourceSHA256 == digest else { throw ScoreAuditionError.wrongScore }
        guard version == 1, sourceSHA256.count == 64,
              sourceSHA256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              title.count <= 300, notice.count <= 2_000,
              tempo.isFinite, (20...300).contains(tempo),
              duration.isFinite, (0.1...1_800).contains(duration),
              !audio.isEmpty, audio.count <= Self.maxBytes / 2,
              audioWithClicks.map({ !$0.isEmpty && $0.count <= Self.maxBytes / 2 }) ?? true,
              !cues.isEmpty, cues.count <= 30_000 else { throw ScoreAuditionError.invalid }
        var previous = -Double.infinity
        for cue in cues {
            guard cue.time.isFinite, cue.duration.isFinite,
                  cue.time >= previous, cue.time >= 0, cue.time < duration,
                  cue.duration > 0, cue.time + cue.duration <= duration + 0.1,
                  (1...max(1, pageCount)).contains(cue.page), (1...16).contains(cue.staff),
                  cue.measure > 0, cue.x.isFinite, cue.y.isFinite,
                  abs(cue.x) < 100_000, abs(cue.y) < 100_000 else { throw ScoreAuditionError.invalid }
            previous = cue.time
        }
        if let bars {
            guard !bars.isEmpty, bars.count <= 5_000 else { throw ScoreAuditionError.invalid }
            var end = 0.0, measure = 0
            for bar in bars {
                guard bar.measure == measure + 1, bar.start.isFinite, bar.duration.isFinite,
                      bar.duration > 0, abs(bar.start - end) < 0.001,
                      bar.end <= duration + 0.001 else { throw ScoreAuditionError.invalid }
                end = bar.end; measure = bar.measure
            }
            for cue in cues {
                guard cue.measure <= bars.count else { throw ScoreAuditionError.invalid }
                let bar = bars[cue.measure - 1]
                guard cue.time >= bar.start - 0.001, cue.time < bar.end + 0.001 else { throw ScoreAuditionError.invalid }
            }
        }
        if let notation { try notation.validate(pageCount: pageCount) }
    }

    static func read(_ url: URL, digest: String, pageCount: Int) throws -> Self {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        let data = try input.read(upToCount: maxBytes + 1) ?? Data()
        guard data.count <= maxBytes else { throw ScoreAuditionError.invalid }
        let package = try JSONDecoder().decode(Self.self, from: data)
        try package.validate(digest: digest, pageCount: pageCount)
        return package
    }

    static func cacheURL(digest: String) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ScoreAuditionPreview", isDirectory: true)
            .appendingPathComponent(digest + ".json")
    }

    func cache(directory: URL? = nil, budget: Int = cacheBudget) throws {
        let root = directory ?? Self.cacheURL(digest: sourceSHA256).deletingLastPathComponent()
        let pages = Set(cues.map(\.page)).sorted().map(String.init).joined(separator: "-")
        let url = root.appendingPathComponent(sourceSHA256 + "-p" + pages + ".json")
        let data = try JSONEncoder().encode(self)
        guard data.count <= min(Self.maxBytes, budget) else { throw ScoreAuditionError.invalid }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        // Re-recognizing a page invalidates joined previews that include it.
        // This directory contains disposable audition results only.
        if notation != nil, Set(cues.map(\.page)).count == 1, let page = cues.first?.page {
            for item in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where item != url {
                let name = item.deletingPathExtension().lastPathComponent
                guard item.pathExtension == "json", name.hasPrefix(sourceSHA256 + "-p") else { continue }
                let pages = name.dropFirst(66).split(separator: "-").compactMap { Int($0) }
                if pages.count > 1, pages.contains(page) { try? FileManager.default.removeItem(at: item) }
            }
        }
        let entries = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
            .filter { $0.pathExtension == "json" && $0.lastPathComponent.prefix(64).count == 64 && $0.lastPathComponent.prefix(64).allSatisfy(\.isHexDigit) }
            .compactMap { item -> (URL, Int, Date)? in
                guard let value = try? item.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
                return (item, value.fileSize ?? 0, value.contentModificationDate ?? .distantPast)
            }.sorted { $0.2 < $1.2 }
        var size = entries.reduce(0) { $0 + $1.1 }
        for (item, bytes, _) in entries where item != url && size > budget {
            if (try? FileManager.default.removeItem(at: item)) != nil { size -= bytes }
        }
    }

    static func cached(digest: String, page: Int, pageCount: Int, directory: URL? = nil, minimumRevision: Int? = nil, performsRepeats: Bool? = nil, singlePage: Bool = false) -> Self? {
        let root = directory ?? cacheURL(digest: digest).deletingLastPathComponent()
        let entries = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let candidates = entries.filter {
            let name = $0.deletingPathExtension().lastPathComponent
            guard $0.pathExtension == "json" else { return false }
            if singlePage { return name == digest + "-p" + String(page) }
            if name == digest { return true } // Legacy multi-page imports.
            guard name.hasPrefix(digest + "-p") else { return false }
            return name.dropFirst(digest.count + 2).split(separator: "-").contains(Substring(String(page)))
        }
            .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for url in candidates {
            guard let package = try? read(url, digest: digest, pageCount: pageCount), package.cues.contains(where: { $0.page == page }) else { continue }
            if let minimumRevision, (package.recognitionRevision ?? 0) < minimumRevision { continue }
            if let performsRepeats, package.performsRepeats != performsRepeats { continue }
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
            return package
        }
        return nil
    }
}

enum ScoreAuditionError: LocalizedError {
    case invalid, wrongScore, busy
    var errorDescription: String? {
        switch self {
        case .invalid: return ScoreAuditionText.value("试听文件无效或音频不完整。", "The preview file is invalid or its audio is incomplete.")
        case .wrongScore: return ScoreAuditionText.value("这份试听结果不属于当前原谱，请打开对应的 PDF。", "This preview belongs to a different PDF. Open the matching original score.")
        case .busy: return ScoreAuditionText.value("请先结束语音录制或播放。", "Finish the voice recording or playback first.")
        }
    }
}

/// Keep experimental strings out of the production catalog until the workflow is settled.
enum ScoreAuditionText {
    static func value(_ chinese: String, _ english: String) -> String {
        (Locale.preferredLanguages.first ?? "en").hasPrefix("zh") ? chinese : english
    }
}
#endif
