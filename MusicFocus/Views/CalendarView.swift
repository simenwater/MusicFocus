import SwiftUI

/**
 * @struct CalendarView
 * @description 自定义日历视图组件
 */
struct CalendarView: View {
    @Binding var selectedDate: Date
    @ObservedObject var focusManager: FocusManager
    @State private var showDailyDetail = false

    private var calendar: Calendar { focusManager.practiceStatistics.calendar }
    private var month: DateInterval { calendar.dateInterval(of: .month, for: selectedDate)! }
    private var leadingDays: Int {
        (calendar.component(.weekday, from: month.start) - calendar.firstWeekday + 7) % 7
    }
    private var dayCount: Int { calendar.range(of: .day, in: .month, for: selectedDate)!.count }
    private var weekdaySymbols: [String] {
        let formatter = DateFormatter()
        formatter.locale = AppLocalization.locale
        formatter.calendar = calendar
        return formatter.veryShortStandaloneWeekdaySymbols
    }
    private var monthTitle: String {
        let formatter = DateFormatter()
        formatter.locale = AppLocalization.locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("yyyyMMMM")
        return formatter.string(from: month.start)
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Button { changeMonth(-1) } label: { Image(systemName: "chevron.left") }
                    .accessibilityLabel("Previous Month".localized)
                    .accessibilityIdentifier("statistics.previousMonth")
                    .frame(width: 44, height: 44)
                Spacer()
                Text(monthTitle).font(.headline)
                    .accessibilityIdentifier("statistics.monthTitle")
                Spacer()
                Button { changeMonth(1) } label: { Image(systemName: "chevron.right") }
                    .accessibilityLabel("Next Month".localized)
                    .accessibilityIdentifier("statistics.nextMonth")
                    .frame(width: 44, height: 44)
                    .disabled(month.end > focusManager.practiceStatistics.asOf)
            }
            HStack(spacing: 0) {
                ForEach(0..<7, id: \.self) { offset in
                    Text(weekdaySymbols[(calendar.firstWeekday - 1 + offset) % 7])
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 2) {
                ForEach(0..<(leadingDays + dayCount), id: \.self) { index in
                    if index < leadingDays {
                        Color.clear.frame(height: 44)
                    } else {
                        let date = calendar.date(byAdding: .day, value: index - leadingDays, to: month.start)!
                        let selected = calendar.isDate(date, inSameDayAs: selectedDate)
                        let day = focusManager.practiceStatistics.day(date)
                        Button {
                            selectedDate = date
                            showDailyDetail = true
                        } label: {
                            VStack(spacing: 3) {
                                Text("\(calendar.component(.day, from: date))").font(.callout)
                                Text(day.sessions.isEmpty ? "—" : TimeFormatter.formatTimeIntervalShort(day.focusTime))
                                    .font(.system(size: 10, weight: .medium)).lineLimit(1).minimumScaleFactor(0.7)
                                    .foregroundStyle(day.focusTime > 0 ? .green : .secondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 54)
                            .background(selected ? Color.blue.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(selected ? .blue : .primary)
                        .disabled(date > focusManager.practiceStatistics.asOf)
                        .accessibilityLabel(TimeFormatter.formatDate(date))
                        .accessibilityValue(day.sessions.isEmpty ? "practice.noRecords".localized : TimeFormatter.formatTimeInterval(day.focusTime))
                        .accessibilityIdentifier("statistics.day-\(calendar.component(.year, from: date))-\(calendar.component(.month, from: date))-\(calendar.component(.day, from: date))")
                    }
                }
            }
        }
        .onChange(of: calendar.startOfDay(for: focusManager.practiceStatistics.asOf)) { previous, current in
            if calendar.isDate(selectedDate, inSameDayAs: previous) { selectedDate = current }
        }
        .sheet(isPresented: $showDailyDetail) {
            DailyDetailView(date: selectedDate, focusManager: focusManager)
        }
    }

    private func changeMonth(_ offset: Int) {
        if let date = calendar.date(byAdding: .month, value: offset, to: month.start) {
            selectedDate = date
        }
    }

}

/**
 * @struct DailyDetailView
 * @description 每日练习详情视图
 */
struct DailyDetailView: View {
    let date: Date
    @ObservedObject var focusManager: FocusManager
    @EnvironmentObject private var library: ScoreLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var scoreSummaries: [ScorePracticeSummary] = []

    private var scoreRequest: ScorePracticeSummaryCache.Key {
        let calendar = focusManager.practiceStatistics.calendar
        return .init(history: focusManager.scoreHistoryRevision, visits: library.visitsRevision,
                     range: calendar.dateInterval(of: .day, for: date), day: calendar.startOfDay(for: date))
    }

    var sessions: [FocusSession] {
        focusManager.getSessionsForDate(date)
    }

    var totalFocusTime: TimeInterval {
        focusManager.getTotalFocusTimeForDate(date)
    }

    var totalDistractionTime: TimeInterval {
        focusManager.getTotalDistractionTimeForDate(date)
    }

    // 计算专注率
    var focusRate: Double {
        let totalTime = totalFocusTime + totalDistractionTime
        return totalTime > 0 ? (totalFocusTime / totalTime) * 100 : 0
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    // 日期标题
                    Text(TimeFormatter.formatDate(date))
                        .font(.title2)
                        .fontWeight(.bold)
                        .padding(.top)

                    // 练习统计卡片
                    HStack(spacing: 20) {
                        VStack {
                            Text("专注时间".localized)
                                .font(.caption)
                                .foregroundColor(.secondary)

                            Text(TimeFormatter.formatTimeInterval(totalFocusTime))
                                .font(.headline)
                                .foregroundColor(.green)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(10)

                        VStack {
                            Text("分心时间".localized)
                                .font(.caption)
                                .foregroundColor(.secondary)

                            Text(TimeFormatter.formatTimeInterval(totalDistractionTime))
                                .font(.headline)
                                .foregroundColor(.red)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(10)
                    }
                    .padding(.horizontal)

                    // 专注率显示
                    VStack {
                        Text("专注率".localized)
                            .font(.caption)
                            .foregroundColor(.secondary)

                        HStack(spacing: 4) {
                            Text(String(format: "%.1f%%", focusRate))
                                .font(.headline)

                            Image(systemName: focusRate >= 80 ? "star.fill" :
                                  focusRate >= 60 ? "star" : "exclamationmark.triangle")
                                .foregroundColor(focusRate >= 80 ? .yellow :
                                                focusRate >= 60 ? .orange : .red)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(10)
                    .padding(.horizontal)

                    if !scoreSummaries.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("score.statistics".localized).font(.headline)
                            ForEach(scoreSummaries) { summary in
                                NavigationLink {
                                    ScoreStatisticsDetail(summary: summary, title: summary.title,
                                        score: library.scores.first { $0.id == summary.id }, disk: library.disk,
                                        periodLabel: TimeFormatter.formatDate(date))
                                } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(library.scores.first { $0.id == summary.id }?.title ?? summary.title)
                                            .font(.subheadline.weight(.semibold))
                                        Text("score.practiceTotal".localizedFormat(TimeFormatter.formatTimeInterval(summary.practice)))
                                            .font(.caption).foregroundStyle(.secondary)
                                        if summary.displayed > 0 {
                                            Text("score.displayed".localized + ": " + TimeFormatter.formatTimeInterval(summary.displayed))
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }.buttonStyle(.plain)
                            }
                        }.padding().background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                            .padding(.horizontal).accessibilityIdentifier("statistics.dailyScores")
                    }

                    // 练习会话列表
                    if sessions.isEmpty {
                        Text("No practice records for this day".localized)
                            .foregroundColor(.secondary)
                            .padding()
                            .frame(maxWidth: .infinity)
                            .background(Color(.secondarySystemBackground))
                            .cornerRadius(10)
                            .padding(.horizontal)
                    } else {
                        VStack(spacing: 10) {
                            ForEach(sessions) { session in
                                NavigationLink(destination: SessionDetailView(session: session)) {
                                    SessionListItem(session: session, accountingDay: date)
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                        }
                        .padding(.horizontal)
                    }
                }
                .padding(.bottom)
            }
            .navigationBarTitleDisplayMode(.inline)
            .task(id: scoreRequest) {
                let result = await focusManager.scoreSummaryCache.summaries(key: scoreRequest,
                    sessions: focusManager.allSessions, visits: library.visits, asOf: focusManager.practiceStatistics.asOf)
                guard !Task.isCancelled else { return }
                scoreSummaries = result
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭".localized) {
                        dismiss()
                    }
                }
            }
        }
    }
}

#Preview {
    CalendarView(selectedDate: .constant(Date()), focusManager: FocusManager())
}
