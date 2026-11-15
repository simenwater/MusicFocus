import SwiftUI
import UniformTypeIdentifiers

struct ScoreLibraryEntry: View {
    @EnvironmentObject private var library: ScoreLibrary
    @Environment(\.scoreExternalWindowID) private var externalWindowID
    @State private var showing = false
    var tint: Color = .blue
    var body: some View {
        Button { showing = true } label: {
            HStack(spacing: 14) {
                Image(systemName: "books.vertical").font(.title2)
                VStack(alignment: .leading, spacing: 3) {
                    Text("score.library".localized).font(.headline)
                    Text(library.mostRecentScore?.title ?? "score.libraryHint".localized)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
            }
            .padding(14).background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain).foregroundStyle(tint)
        .accessibilityIdentifier("scoreLibraryOpen")
        .fullScreenCover(isPresented: $showing) { ScoreLibraryView() }
        .onAppear { presentExternalLibrary() }
        .onChange(of: library.externalLibraryRequested) { _, _ in presentExternalLibrary() }
    }

    private func presentExternalLibrary() {
        guard library.handlesExternalFiles(in: externalWindowID), library.externalLibraryRequested else { return }
        library.externalLibraryRequested = false
        showing = true
    }
}

/// iPad practice home and the phone's modal use the same local library.
struct ScoreLibraryView: View {
    var isPracticeHome = false
    @EnvironmentObject private var library: ScoreLibrary
    @Environment(\.scoreExternalWindowID) private var externalWindowID
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false
    @State private var query = ""
    private enum ShelfFilter { case recent, all, favorites }
    @State private var shelfFilter: ShelfFilter = .recent
    @State private var selected: LibraryScore?
    @State private var readerPresented = false
    @State private var openedExternally = false
    @State private var isVisible = false
    @State private var timerClosing = false
    @State private var timerPresented = false
    @State private var renaming: LibraryScore?
    @State private var newTitle = ""
    @State private var deleting: LibraryScore?
    private var searchQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var filtered: [LibraryScore] {
        if !searchQuery.isEmpty { return library.searchScores(searchQuery) }
        switch shelfFilter {
        case .recent: return library.recentlyOpenedScores
        case .all: return library.orderedScores
        case .favorites: return library.orderedScores.filter(\.isFavorite)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    ViewThatFits(in: .horizontal) {
                        HStack { heading; Spacer(); TodayPracticeLabel() }
                        VStack(alignment: .leading, spacing: 12) { heading; TodayPracticeLabel() }
                    }
                    if library.handlesExternalFiles(in: externalWindowID), let invitation = library.pendingRoomInvite {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("score.sync.roomInvitationTitle".localizedFormat(invitation.code)).font(.headline)
                                Spacer()
                                Button("Cancel".localized) { library.pendingRoomInvite = nil }
                            }
                            if let match = library.orderedScores.first(where: { $0.layoutDigest == invitation.digest || $0.sourceDigest == invitation.digest }) {
                                Button { openScore(match) } label: { Label(match.title, systemImage: "book") }
                                    .accessibilityIdentifier("scoreInviteOpenMatch")
                            } else {
                                Text("score.sync.chooseOriginal".localized).foregroundStyle(.secondary)
                            }
                        }
                        .padding().background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
                    }
                    PracticeSessionControls(style: .banner)
                    if searchQuery.isEmpty, let score = library.mostRecentScore { resumeCard(score) }
                    HStack {
                        Text("home.myScores".localized).font(.title3.weight(.semibold))
                        Spacer()
                        if isPracticeHome {
                            Button { timerPresented = true } label: {
                                Label("home.withoutScore".localized, systemImage: "timer")
                            }
                            .font(.subheadline.weight(.medium)).frame(minHeight: 44)
                            .accessibilityIdentifier("practiceWithoutScore")
                        }
                    }
                    libraryContent
                }
                .padding(24).frame(maxWidth: 1100).frame(maxWidth: .infinity)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(isPracticeHome ? "MusicFocus" : "score.library".localized)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "score.search".localized)
            .toolbar {
                if !isPracticeHome {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("score.close".localized) { dismiss() }.accessibilityIdentifier("scoreLibraryClose")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { importing = true } label: { Label("score.import".localized, systemImage: "plus") }
                        .disabled(!library.isLoaded || library.isImporting).accessibilityIdentifier("scoreImport")
                }
            }
            .overlay {
                if library.isImporting {
                    ProgressView("score.importing".localized).padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): Task {
                let countBeforeImport = library.scores.count
                await library.importFiles(urls)
                if library.scores.count > countBeforeImport {
                    // Imported PDFs have not been opened yet. Show them immediately.
                    shelfFilter = .all
                    query = ""
                }
            }
            case .failure(let error): library.errorMessage = error.localizedDescription
            }
        }
        .fullScreenCover(item: $selected, onDismiss: {
            readerPresented = false
            presentPendingScore()
        }) { ScoreReaderView(score: $0, showsImportConfirmation: openedExternally) }
        .fullScreenCover(isPresented: $timerPresented, onDismiss: {
            timerClosing = false
            presentPendingScore()
        }) {
            NavigationStack {
                FocusTimerView(showsLibraryEntry: false)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("score.library".localized, systemImage: "chevron.left") { timerPresented = false }
                                .accessibilityIdentifier("practiceReturnToLibrary")
                        }
                    }
            }
        }
        .alert("score.rename".localized, isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("score.title".localized, text: $newTitle)
            Button("score.save".localized) { if let score = renaming { Task { await library.rename(score.id, title: newTitle) } } }
            Button("Cancel".localized, role: .cancel) { }
        }
        .confirmationDialog("score.removeConfirm".localized, isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("score.remove".localized, role: .destructive) {
                if let score = deleting { Task { await library.remove(score.id) } }
            }
        } message: { Text("score.removeHint".localized) }
        .alert("score.error".localized, isPresented: Binding(get: { isVisible && library.errorMessage != nil }, set: { if !$0 { library.errorMessage = nil } })) {
            Button("OK".localized) { library.errorMessage = nil }
        } message: { Text(library.errorMessage ?? "") }
        .onAppear { isVisible = true; presentPendingScore() }
        .onDisappear { isVisible = false }
        .onChange(of: library.pendingExternalScore?.id) { _, _ in presentPendingScore() }
        .onChange(of: library.externalRequestID) { _, _ in
            guard library.handlesExternalFiles(in: externalWindowID) else { return }
            if timerPresented { timerClosing = true; timerPresented = false }
            importing = false
            renaming = nil
            deleting = nil
        }
        .onChange(of: importing) { _, value in if !value { presentPendingScore() } }
    }

    private func openScore(_ score: LibraryScore, external: Bool = false) {
        openedExternally = external
        readerPresented = true
        selected = score
    }

    private func presentPendingScore() {
        guard library.handlesExternalFiles(in: externalWindowID), let score = library.pendingExternalScore else { return }
        if timerPresented { timerClosing = true; timerPresented = false; return }
        if importing { importing = false; return }
        guard isVisible, !readerPresented, !timerClosing else { return }
        renaming = nil
        deleting = nil
        query = ""
        shelfFilter = .all
        library.pendingExternalScore = nil
        if isPracticeHome { library.externalLibraryRequested = false }
        openScore(score, external: true)
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("home.yourScores".localized).font(.largeTitle.bold())
            Text(Date().formatted(Date.FormatStyle().month(.wide).day().weekday(.wide).locale(AppLocalization.locale)))
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }
    private func openResumePage(_ score: LibraryScore) {
        var opening = score
        opening.lastPage = score.nextPracticePage ?? score.lastPage
        openScore(opening)
    }

    private func resumeCard(_ score: LibraryScore) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("home.resume".localized).font(.caption.weight(.semibold)).foregroundStyle(.blue)
                    Text(score.title).font(.headline).lineLimit(2)
                    Text("home.resumePage".localizedFormat(min(max(1, score.nextPracticePage ?? score.lastPage), score.pageCount)))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button { openResumePage(score) } label: { Label((score.nextPracticePage == nil ? "home.continueScore" : "home.resumeBookmark").localized, systemImage: "book") }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .accessibilityIdentifier("scoreResumeLast")
            }
            if let note = score.nextPracticeNote, !note.isEmpty {
                Label(note, systemImage: "note.text").font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
                    .accessibilityIdentifier("scoreResumeNote")
            }
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 18))
    }

    @ViewBuilder private var libraryContent: some View {
        if !library.isLoaded {
            if library.errorMessage != nil {
                ContentUnavailableView {
                    Label("score.error".localized, systemImage: "exclamationmark.triangle")
                } actions: {
                    Button("score.retry".localized) { Task { await library.load() } }
                }
            } else { ProgressView("score.loading".localized).frame(maxWidth: .infinity).padding(50) }
        } else if library.scores.isEmpty {
            ContentUnavailableView {
                Label("score.empty".localized, systemImage: "books.vertical")
            } description: {
                Text("score.emptyHint".localized)
            } actions: {
                Button("score.import".localized) { importing = true }
                    .buttonStyle(.borderedProminent).controlSize(.large).accessibilityIdentifier("scoreImportEmpty")
            }
        } else {
            let visibleScores = filtered
            if searchQuery.isEmpty {
                Picker("home.scoreFilter".localized, selection: $shelfFilter) {
                    Text("home.recentScores".localized).tag(ShelfFilter.recent)
                    Text("home.allScores".localized).tag(ShelfFilter.all)
                    Text("home.favoriteScores".localized).tag(ShelfFilter.favorites)
                }
                .pickerStyle(.segmented).frame(maxWidth: 360).accessibilityIdentifier("scoreLibraryFilter")
            } else {
                Text("home.allSearchResults".localized).font(.headline)
            }
            if visibleScores.isEmpty && shelfFilter == .recent && searchQuery.isEmpty {
                ContentUnavailableView {
                    Label("home.noRecentScores".localized, systemImage: "clock")
                } description: {
                    Text("home.noRecentScoresHint".localized)
                } actions: {
                    Button("home.browseAllScores".localized) { shelfFilter = .all }
                        .buttonStyle(.bordered).accessibilityIdentifier("scoreShowAll")
                }
            } else if visibleScores.isEmpty {
                ContentUnavailableView {
                    Label("home.noMatchingScores".localized, systemImage: "magnifyingglass")
                } description: { Text("home.adjustSearch".localized) }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 24)], spacing: 28) {
                    ForEach(visibleScores) { score in
                        VStack(alignment: .leading, spacing: 8) {
                            Button { openScore(score) } label: {
                                ScoreBookCard(score: score, coverURL: library.disk.coverURL(score.id))
                            }
                            .buttonStyle(.plain).accessibilityIdentifier("scoreBook-\(score.title)")
                            .contextMenu { bookActions(score) }
                            HStack {
                                Text("score.pagesCount".localizedFormat(score.pageCount)).font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Menu { bookActions(score) } label: {
                                    Image(systemName: "ellipsis").frame(minWidth: 44, minHeight: 36)
                                }.accessibilityLabel("home.scoreActions".localizedFormat(score.title))
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func bookActions(_ score: LibraryScore) -> some View {
        if let page = score.nextPracticePage {
            Button("practice.openMarkedPage".localizedFormat(page), systemImage: "bookmark") { openResumePage(score) }
            Button("practice.clearMarkedPage".localized, systemImage: "bookmark.slash") {
                Task { await library.setNextPracticePlan(score.id, note: score.nextPracticeNote ?? "", page: nil) }
            }
        }
        Button(score.isFavorite ? "score.unfavorite".localized : "score.favorite".localized,
               systemImage: score.isFavorite ? "star.slash" : "star") { Task { await library.favorite(score.id) } }
        Button("score.rename".localized, systemImage: "pencil") { newTitle = score.title; renaming = score }
        Button("score.remove".localized, systemImage: "trash", role: .destructive) { deleting = score }
    }
}

private struct TodayPracticeLabel: View {
    @EnvironmentObject private var focus: FocusManager
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock").foregroundStyle(.secondary)
            Text("home.todayPractice".localized)
            Text(TimeFormatter.formatTimeInterval(focus.practiceStatistics.day(Date()).focusTime)).fontWeight(.semibold).monospacedDigit()
        }
        .font(.subheadline).padding(.horizontal, 16).padding(.vertical, 12)
        .background(Color(.secondarySystemGroupedBackground), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

private struct ScoreBookCard: View {
    var score: LibraryScore
    var coverURL: URL
    @State private var cover: UIImage?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(.white)
                if let cover { Image(uiImage: cover).resizable().scaledToFit().padding(8) }
                else { Image(systemName: "music.note").font(.largeTitle).foregroundStyle(.gray) }
            }
            .frame(height: 230).clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .leading) { Rectangle().fill(.black.opacity(0.04)).frame(width: 4) }
            .shadow(color: .black.opacity(0.08), radius: 6, x: 2, y: 4)
            HStack(alignment: .top, spacing: 5) {
                Text(score.title).font(.subheadline.weight(.semibold)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                if score.isFavorite { Image(systemName: "star.fill").foregroundStyle(.orange).font(.caption) }
            }
        }
        .accessibilityElement(children: .combine)
        .task(id: coverURL) {
            let url = coverURL
            let data = await Task.detached(priority: .utility) { try? Data(contentsOf: url) }.value
            guard !Task.isCancelled else { return }
            cover = data.flatMap { UIImage(data: $0) }
        }
    }
}
