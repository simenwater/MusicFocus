import SwiftUI
import PDFKit

enum ScorePageLabel {
    static func text(_ pages: [Int]) -> String {
        "score.pageLabel".localizedFormat(pages.map(String.init).joined(separator: "–"))
    }
}

struct ScoreStatisticsView: View {
    @EnvironmentObject private var focus: FocusManager
    @EnvironmentObject private var library: ScoreLibrary
    @State private var period = 0
    @State private var summaries: [ScorePracticeSummary] = []
    private var request: ScorePracticeSummaryCache.Key {
        let now = Date(), calendar = Calendar.current
        let range: DateInterval?
        switch period {
        case 1: range = focus.practiceStatistics.recentWeek
        case 2: range = calendar.dateInterval(of: .month, for: now)
        default: range = nil
        }
        return .init(history: focus.scoreHistoryRevision, visits: library.visitsRevision, range: range, day: calendar.startOfDay(for: now))
    }
    var body: some View {
        List {
            Picker("score.period".localized, selection: $period) {
                Text("score.allTime".localized).tag(0)
                Text("score.week".localized).tag(1)
                Text("score.month".localized).tag(2)
            }.pickerStyle(.segmented)
            if focus.isActive { Text("score.historyHint".localized).font(.footnote).foregroundStyle(.secondary) }
            if summaries.isEmpty {
                ContentUnavailableView("score.noStatistics".localized, systemImage: "music.note.list", description: Text("score.noStatisticsHint".localized))
            }
            ForEach(summaries) { summary in
                NavigationLink {
                    ScoreStatisticsDetail(summary: summary, title: title(for: summary),
                                          score: library.scores.first { $0.id == summary.id }, disk: library.disk,
                                          periodLabel: (period == 1 ? "practice.recentSevenDays" : period == 2 ? "score.month" : "score.allTime").localized)
                } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(title(for: summary)).font(.headline)
                        Text("score.practiceTotal".localizedFormat(TimeFormatter.formatTimeInterval(summary.practice)))
                            .foregroundStyle(.secondary)
                    }.padding(.vertical, 6)
                }
            }
            Text("score.statisticsExplanation".localized).font(.footnote).foregroundStyle(.secondary)
        }
        .task(id: request) {
            let result = await focus.scoreSummaryCache.summaries(key: request, sessions: focus.allSessions,
                                                               visits: library.visits, asOf: Date())
            guard !Task.isCancelled else { return }
            summaries = result
        }
        .navigationTitle("score.statistics".localized)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func title(for summary: ScorePracticeSummary) -> String {
        library.scores.first { $0.id == summary.id }?.title ?? summary.title
    }
}

struct ScoreStatisticsDetail: View {
    let summary: ScorePracticeSummary
    let title: String
    var score: LibraryScore?
    var disk: ScoreLibraryDisk?
    var periodLabel: String = "score.allTime".localized
    var body: some View {
        List {
            Text(periodLabel).font(.subheadline).foregroundStyle(.secondary)
            Section {
                ScorePageHeatmap(practice: summary.practiceByPage, details: summary.pages,
                                 pageCount: score?.pageCount ?? summary.practiceByPage.keys.max() ?? 0,
                                 pdfURL: score.flatMap { score in disk.map { $0.pdfURL(score.id) } })
            } header: {
                Text("score.heatmap".localized)
            } footer: {
                Text("score.heatmapHint".localized)
            }
            Section {
                value("score.practice", summary.practice)
                value("score.displayed", summary.displayed)
                value("score.withMetronome", summary.metronome)
            }
            ForEach(summary.groups) { group in
                Section(ScorePageLabel.text(group.pages)) {
                    value("score.practice", group.practice)
                    value("score.displayed", group.displayed)
                    value("score.withMetronome", group.metronome)
                    ForEach(group.tempos.keys.sorted { $0.signature == $1.signature ? $0.bpm < $1.bpm : $0.signature < $1.signature }, id: \.self) { tempo in
                        HStack {
                            Text("\(tempo.bpm) BPM · \(tempo.signature)")
                            Spacer()
                            Text(TimeFormatter.formatTimeInterval(group.tempos[tempo] ?? 0)).monospacedDigit()
                        }.font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
            Text("score.statisticsExplanation".localized).font(.footnote).foregroundStyle(.secondary)
        }
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
    }

    private func value(_ label: String, _ seconds: TimeInterval) -> some View {
        HStack { Text(label.localized); Spacer(); Text(TimeFormatter.formatTimeInterval(seconds)).monospacedDigit() }
    }
}

/// Detected practice per page on the score's own page thumbnails. Magnitude uses
/// one blue ramp (light to dark; flipped in dark mode so "little" recedes into the
/// surface); unpractised pages are neutral and labelled, never colour alone.
struct ScorePageHeatmap: View {
    let practice: [Int: TimeInterval]
    var details: [Int: ScorePracticeSummary.PageDetail] = [:]
    let pageCount: Int
    let pdfURL: URL?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var thumbnails: [Int: UIImage]
    @State private var openedPage: PageSelection?

    private struct PageSelection: Identifiable { let page: Int; var id: Int { page } }

    init(practice: [Int: TimeInterval], details: [Int: ScorePracticeSummary.PageDetail] = [:],
         pageCount: Int, pdfURL: URL?, thumbnails: [Int: UIImage] = [:]) {
        self.practice = practice
        self.details = details
        self.pageCount = pageCount
        self.pdfURL = pdfURL
        _thumbnails = State(initialValue: thumbnails)
    }

    /// Seven steps of the reference sequential blue (150 -> 700).
    static let lightRamp = ["#b7d3f6", "#86b6ef", "#5598e7", "#2a78d6", "#1c5cab", "#104281", "#0d366b"]
    static let darkRamp = Array(lightRamp.reversed())

    /// 0 = not practised; otherwise 1...7 by share of the most-practised page.
    static func level(_ seconds: TimeInterval, maximum: TimeInterval) -> Int {
        guard seconds > 0, maximum > 0 else { return 0 }
        return min(7, max(1, Int((seconds / maximum * 7).rounded(.up))))
    }

    private var maximum: TimeInterval { practice.values.max() ?? 0 }

    private func color(_ level: Int) -> Color {
        guard level > 0 else { return Color(.systemGray5) }
        let ramp = colorScheme == .dark ? Self.darkRamp : Self.lightRamp
        return Self.rgb(ramp[level - 1])
    }

    static func rgb(_ hex: String) -> Color {
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
        return Color(red: Double(value >> 16 & 0xff) / 255, green: Double(value >> 8 & 0xff) / 255,
                     blue: Double(value & 0xff) / 255)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Wider cells on iPad so durations and metronome time are not truncated.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: horizontalSizeClass == .regular ? 120 : 84), spacing: 12, alignment: .top)], spacing: 14) {
                ForEach(1...max(1, pageCount), id: \.self) { page in
                    cell(page)
                }
            }
            legend
        }
        .padding(.vertical, 6)
        .task(id: pdfURL) { await loadThumbnails() }
        .sheet(item: $openedPage) { selection in
            ScorePageHistoryView(page: selection.page, detail: details[selection.page] ?? .init(),
                                 thumbnail: thumbnails[selection.page])
                .presentationDetents([.medium, .large])
        }
    }

    private func cell(_ page: Int) -> some View {
        Button { openedPage = PageSelection(page: page) } label: { cellBody(page) }
            .buttonStyle(.plain)
            .accessibilityIdentifier("scoreHeatmapPage-\(page)")
    }

    private func cellBody(_ page: Int) -> some View {
        let seconds = practice[page] ?? 0
        let level = Self.level(seconds, maximum: maximum)
        let detail = details[page]
        return VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 4).fill(Color(.secondarySystemBackground))
                if let image = thumbnails[page] {
                    Image(uiImage: image).resizable().scaledToFit()
                        .opacity(level == 0 ? 0.55 : 1)
                }
            }
            .aspectRatio(0.77, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(.separator), lineWidth: 0.5))
            RoundedRectangle(cornerRadius: 3).fill(color(level)).frame(height: 8)
            Text(ScorePageLabel.text([page])).font(.caption2).foregroundStyle(.secondary)
            Text(seconds > 0 ? TimeFormatter.formatTimeInterval(seconds) : "score.notPracticed".localized)
                .font(.caption2.weight(seconds > 0 ? .semibold : .regular))
                .foregroundStyle(seconds > 0 ? .primary : .secondary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if let detail, detail.metronome > 0 {
                Label(TimeFormatter.formatTimeInterval(detail.metronome), systemImage: "metronome")
                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            if let last = detail?.lastPracticed {
                Text(ScorePageHistoryView.relative(last))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var legend: some View {
        HStack(spacing: 6) {
            Text("score.heatmapLess".localized)
            HStack(spacing: 2) {
                ForEach(1...7, id: \.self) { RoundedRectangle(cornerRadius: 2).fill(color($0)).frame(width: 16, height: 8) }
            }
            Text("score.heatmapMore".localized)
            Spacer()
            RoundedRectangle(cornerRadius: 2).fill(color(0)).frame(width: 16, height: 8)
            Text("score.notPracticed".localized)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    private func loadThumbnails() async {
        guard let pdfURL, pageCount > 0 else { return }
        let count = pageCount
        let images = await Task.detached(priority: .utility) { () -> [Int: UIImage] in
            guard let document = PDFDocument(url: pdfURL) else { return [:] }
            var result: [Int: UIImage] = [:]
            for index in 0..<min(count, document.pageCount) {
                guard let page = document.page(at: index) else { continue }
                result[index + 1] = page.thumbnail(of: CGSize(width: 148, height: 192), for: .cropBox)
            }
            return result
        }.value
        thumbnails = images
    }
}

/// One page: total practice, how much with the metronome, at which tempos,
/// and every session that practised it (newest first).
struct ScorePageHistoryView: View {
    let page: Int
    let detail: ScorePracticeSummary.PageDetail
    var thumbnail: UIImage?
    @Environment(\.dismiss) private var dismiss

    static func relative(_ date: Date, now: Date = Date()) -> String {
        date.formatted(Date.RelativeFormatStyle(presentation: .named, unitsStyle: .wide).locale(AppLocalization.locale))
    }

    private static func when(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).weekday(.abbreviated).locale(AppLocalization.locale))
    }

    private func duration(_ seconds: TimeInterval) -> some View {
        Text(TimeFormatter.formatTimeInterval(seconds)).monospacedDigit()
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(alignment: .top, spacing: 14) {
                        if let thumbnail {
                            Image(uiImage: thumbnail).resizable().scaledToFit().frame(width: 64)
                                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color(.separator), lineWidth: 0.5))
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            LabeledContent("score.practice".localized) { duration(detail.practice) }
                            LabeledContent("score.withMetronome".localized) { duration(detail.metronome) }
                            if let last = detail.lastPracticed {
                                LabeledContent("score.lastPracticed".localized, value: Self.relative(last))
                            }
                        }
                    }
                }
                if !detail.tempos.isEmpty {
                    Section("score.tempos".localized) {
                        ForEach(detail.tempos.keys.sorted { $0.bpm == $1.bpm ? $0.signature < $1.signature : $0.bpm < $1.bpm }, id: \.self) { tempo in
                            LabeledContent("\(tempo.bpm) BPM · \(tempo.signature)") { duration(detail.tempos[tempo] ?? 0) }
                        }
                    }
                }
                Section("score.pageHistory".localized) {
                    if detail.entries.isEmpty {
                        Text("score.notPracticed".localized).foregroundStyle(.secondary)
                    }
                    ForEach(detail.entries) { entry in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(Self.when(entry.start))
                                Spacer()
                                duration(entry.practice)
                            }
                            Label(entry.tempos.isEmpty ? "score.noMetronome".localized
                                  : entry.tempos.keys.map { "\($0.bpm) BPM" }.sorted().joined(separator: ", "),
                                  systemImage: entry.tempos.isEmpty ? "metronome" : "metronome.fill")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            .navigationTitle(ScorePageLabel.text([page]))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成".localized) { dismiss() } }
            }
        }
    }
}
