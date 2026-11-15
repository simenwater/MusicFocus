//
//  CollapsibleStatsCard.swift
//  MusicFocus
//
//  Created by Claude on 2025/11/05.
//

import SwiftUI

/**
 * @struct CollapsibleStatsCard
 * @description 可折叠的统计卡片组件
 */
struct CollapsibleStatsCard: View {
    let title: String
    let icon: String
    @Binding var isExpanded: Bool
    let content: () -> AnyView

    var body: some View {
        VStack(spacing: 0) {
            // 头部（始终可见）
            Button(action: {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    isExpanded.toggle()
                }
            }) {
                HStack {
                    Image(systemName: icon)
                        .font(.system(size: 20))
                        .foregroundColor(.blue)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color.blue.opacity(0.1)))

                    Text(title)
                        .font(.headline)
                        .foregroundColor(.primary)

                    Spacer()

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .padding()
                .background(Color(.systemBackground))
            }
            .buttonStyle(PlainButtonStyle())

            // 内容（可折叠）
            if isExpanded {
                content()
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .padding(.horizontal)
                    .padding(.bottom)
            }
        }
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
        .shadow(color: Color.black.opacity(0.05), radius: 5, x: 0, y: 2)
    }
}

/**
 * @struct WeeklyStatsContent
 * @description 周度统计内容
 */
struct WeeklyStatsContent: View {
    @EnvironmentObject var focusManager: FocusManager

    private var summary: PracticeStatistics.Summary {
        let statistics = focusManager.practiceStatistics
        return statistics.summary(in: statistics.recentWeek)
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 20) {
                StatBubble(
                    icon: "clock.fill",
                    value: TimeFormatter.formatTimeIntervalShort(summary.focusTime),
                    label: "Total Time".localized,
                    color: .green
                )

                StatBubble(
                    icon: "calendar.badge.clock",
                    value: "\(summary.practiceDays)",
                    label: "Practice Days".localized,
                    color: .blue
                )
            }

            // 本周勋章
            if !getWeeklyBadges().isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("This Week's Badges".localized)
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(getWeeklyBadges(), id: \.id) { badge in
                                BadgeView(badge: badge, size: 40)
                            }
                        }
                    }
                }
            }
        }
        .padding(.top, 8)
    }

    private func getWeeklyBadges() -> [Badge] {
        let week = focusManager.practiceStatistics.recentWeek
        return focusManager.badgeManager.badges.filter { $0.date >= week.start && $0.date < week.end }
    }

}

/**
 * @struct MonthlyStatsContent
 * @description 月度统计内容
 */
struct MonthlyStatsContent: View {
    @EnvironmentObject var focusManager: FocusManager
    @State private var selectedDate = Date()

    private var summary: PracticeStatistics.Summary {
        focusManager.practiceStatistics.month(containing: selectedDate)
    }

    var body: some View {
        VStack(spacing: 16) {
            // 月历视图
            CalendarView(selectedDate: $selectedDate, focusManager: focusManager)
                .padding(.top, 8)

            HStack(spacing: 20) {
                StatBubble(
                    icon: "clock.fill",
                    value: TimeFormatter.formatTimeIntervalShort(summary.focusTime),
                    label: "Total Time".localized,
                    color: .green
                )

                StatBubble(
                    icon: "calendar",
                    value: "\(summary.practiceDays)",
                    label: "Practice Days".localized,
                    color: .blue
                )
            }

            // 本月最高勋章
            if let highestBadge = getMonthlyHighestBadge() {
                HStack {
                    BadgeView(badge: highestBadge, size: 50)
                    VStack(alignment: .leading) {
                        Text("Highest Achievement".localized)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(highestBadge.level.displayName)
                            .font(.headline)
                    }
                    Spacer()
                }
                .padding()
                .background(Color(.tertiarySystemBackground))
                .cornerRadius(8)
            }

        }
        .padding(.top, 8)
    }

    private func getMonthlyHighestBadge() -> Badge? {
        let calendar = focusManager.practiceStatistics.calendar
        guard let month = calendar.dateInterval(of: .month, for: selectedDate) else { return nil }
        return focusManager.badgeManager.badges
            .filter { $0.date >= month.start && $0.date < month.end }
            .max { $0.level.timeRange.lowerBound < $1.level.timeRange.lowerBound }
    }

}

/**
 * @struct StatBubble
 * @description 统计气泡组件
 */
struct StatBubble: View {
    let icon: String
    let value: String
    let label: String
    let color: Color

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.15))
                    .frame(width: 50, height: 50)

                Image(systemName: icon)
                    .font(.system(size: 22))
                    .foregroundColor(color)
            }

            Text(value)
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.primary)

            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color(.tertiarySystemBackground))
        .cornerRadius(12)
    }
}

/**
 * @struct SelectedDateDetailView
 * @description 选中日期的详细信息视图
 */
struct SelectedDateDetailView: View {
    @EnvironmentObject var focusManager: FocusManager
    let selectedDate: Date

    private var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter
    }

    private var dailySessions: [FocusSession] { focusManager.getSessionsForDate(selectedDate) }
    private var dailyFocusTime: TimeInterval { focusManager.getTotalFocusTimeForDate(selectedDate) }
    private var dailyDistractionTime: TimeInterval { focusManager.getTotalDistractionTimeForDate(selectedDate) }

    private var dailyBadges: [Badge] {
        let calendar = Calendar.current
        return focusManager.badgeManager.badges.filter { badge in
            calendar.isDate(badge.date, inSameDayAs: selectedDate)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "calendar.circle.fill")
                    .foregroundColor(.blue)
                Text(dateFormatter.string(from: selectedDate))
                    .font(.headline)
                Spacer()
            }

            if dailySessions.isEmpty {
                Text("No practice records for this day".localized)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
            } else {
                VStack(spacing: 8) {
                    HStack {
                        Label(TimeFormatter.formatTimeInterval(dailyFocusTime), systemImage: "clock.fill")
                            .font(.subheadline)
                            .foregroundColor(.green)
                        Spacer()
                        Label(TimeFormatter.formatTimeInterval(dailyDistractionTime), systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundColor(.red)
                    }

                    if !dailyBadges.isEmpty {
                        HStack(spacing: 8) {
                            Text("Badges:".localized)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            ForEach(dailyBadges, id: \.id) { badge in
                                BadgeView(badge: badge, size: 25)
                            }
                            Spacer()
                        }
                    }

                    Text("%d practice sessions".localizedFormat(dailySessions.count))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.blue.opacity(0.1))
        )
    }
}

#Preview {
    let manager = FocusManager()
    return VStack {
        CollapsibleStatsCard(
            title: "Weekly Statistics",
            icon: "chart.bar.fill",
            isExpanded: .constant(true)
        ) {
            AnyView(WeeklyStatsContent().environmentObject(manager))
        }

        CollapsibleStatsCard(
            title: "Monthly Statistics",
            icon: "calendar",
            isExpanded: .constant(false)
        ) {
            AnyView(MonthlyStatsContent().environmentObject(manager))
        }
    }
    .padding()
    .environmentObject(manager)
}
