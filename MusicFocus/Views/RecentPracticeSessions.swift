import SwiftUI

struct RecentPracticeSessions: View {
    @EnvironmentObject private var focus: FocusManager
    @State private var sessions: [FocusSession] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !sessions.isEmpty {
                Text("practice.recentSessions".localized).font(.headline)
                ForEach(sessions) { session in
                    NavigationLink { SessionDetailView(session: session) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: (session.scoreIntervals ?? []).isEmpty ? "waveform" : "music.note.list")
                                .font(.title3).foregroundStyle(.blue).frame(width: 30)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(title(session)).font(.subheadline.weight(.semibold)).lineLimit(1)
                                Text(session.startTime.formatted(Date.FormatStyle().month(.abbreviated).day().hour().minute().locale(AppLocalization.locale)))
                                    .font(.caption).foregroundStyle(.secondary)
                                if let note = session.practiceContent?.notes, !note.isEmpty {
                                    Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer(minLength: 4)
                            Text(TimeFormatter.formatTimeInterval(session.totalFocusTime))
                                .font(.subheadline.weight(.medium)).monospacedDigit()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(16).background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain).accessibilityIdentifier("recentPractice-\(session.id)")
                }
            }
        }
        .task(id: focus.scoreHistoryRevision) {
            let history = focus.allSessions
            let recent = await Task.detached(priority: .userInitiated) {
                Array(history.sorted { $0.startTime > $1.startTime }.prefix(3))
            }.value
            guard !Task.isCancelled else { return }
            sessions = recent
        }
    }

    private func title(_ session: FocusSession) -> String {
        if let name = session.practiceContent?.pieceName, !name.isEmpty { return name }
        if let score = session.scoreIntervals?.first { return score.context.title }
        return "practice.untitledSession".localized
    }
}
