//
//  AvatarShowroomView.swift
//  MusicFocus
//
//  Created by Claude on 2025/11/05.
//

import SwiftUI

/**
 * @struct AvatarShowroomView
 * @description 虚拟形象展览馆主视图
 */
struct AvatarShowroomView: View {
    @EnvironmentObject var focusManager: FocusManager
    @StateObject private var avatarManager = LocalAvatarManager()
    @State private var showAvatarPicker = false
    @State private var showWeeklyStats = false
    @State private var showMonthlyStats = true
    @State private var showBadgeGuide = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // 1. 虚拟形象展示区
                AvatarDisplaySection(
                    avatarManager: avatarManager,
                    showAvatarPicker: $showAvatarPicker
                )

                // 2. 快速数据总览
                QuickStatsBar()

                // 3. 可折叠统计卡片
                StatsCardsSection(
                    showWeeklyStats: $showWeeklyStats,
                    showMonthlyStats: $showMonthlyStats
                )

                // 4. 勋章展示墙
                BadgeShowcaseSection(showBadgeGuide: $showBadgeGuide)

                // 5. 装备解锁进度（可选）
                EquipmentProgressSection()
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .sheet(isPresented: $showAvatarPicker) {
            LocalAvatarPickerView(avatarManager: avatarManager)
                .environmentObject(focusManager)
        }
        .sheet(isPresented: $showBadgeGuide) {
            BadgeGuideView()
        }
    }
}

/**
 * @struct AvatarDisplaySection
 * @description 虚拟形象展示区域
 */
struct AvatarDisplaySection: View {
    @ObservedObject var avatarManager: LocalAvatarManager
    @Binding var showAvatarPicker: Bool

    var body: some View {
        VStack(spacing: 16) {
            Text("My Music Avatar".localized)
                .font(.system(size: 24, weight: .bold))

            // 头像展示
            ZStack {
                // 背景舞台
                RoundedRectangle(cornerRadius: 20)
                    .fill(
                        LinearGradient(
                            colors: [Color.blue.opacity(0.1), Color.purple.opacity(0.1)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(height: 350)

                // 显示本地头像
                VStack(spacing: 20) {
                    ZStack {
                        Circle()
                            .fill(avatarManager.currentAvatar.color.opacity(0.3))
                            .frame(width: 200, height: 200)

                        Circle()
                            .fill(avatarManager.currentAvatar.color.opacity(0.15))
                            .frame(width: 160, height: 160)

                        Image(systemName: avatarManager.currentAvatar.iconName)
                            .font(.system(size: 100))
                            .foregroundColor(avatarManager.currentAvatar.color)
                    }

                    Text(avatarManager.currentAvatar.displayName)
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(.primary)

                    Text(avatarManager.currentAvatar.category.rawValue)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color(.tertiarySystemBackground)))
                }

                // 装饰音符
                musicNotesDecoration
            }

            // 操作按钮
            HStack(spacing: 16) {
                Button(action: {
                    showAvatarPicker = true
                }) {
                    Label("Change Avatar".localized,
                          systemImage: "person.crop.circle.badge.plus")
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.blue)
                        .cornerRadius(12)
                }

                Button(action: {
                    shareAvatar()
                }) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.headline)
                        .foregroundColor(.blue)
                        .padding()
                        .background(Color.blue.opacity(0.1))
                        .cornerRadius(12)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(16)
        .shadow(color: Color.black.opacity(0.05), radius: 10, x: 0, y: 5)
    }

    private var musicNotesDecoration: some View {
        ZStack {
            Image(systemName: "music.note")
                .font(.system(size: 30))
                .foregroundColor(.blue.opacity(0.3))
                .offset(x: -120, y: -100)
                .rotationEffect(.degrees(-15))

            Image(systemName: "music.note.list")
                .font(.system(size: 25))
                .foregroundColor(.purple.opacity(0.3))
                .offset(x: 110, y: -80)
                .rotationEffect(.degrees(20))

            Image(systemName: "music.quarternote.3")
                .font(.system(size: 35))
                .foregroundColor(.green.opacity(0.3))
                .offset(x: -100, y: 120)
                .rotationEffect(.degrees(10))
        }
    }

    private func shareAvatar() {
        // 实现分享功能
        print("分享头像")
    }
}

/**
 * @struct QuickStatsBar
 * @description 快速数据总览条
 */
struct QuickStatsBar: View {
    @EnvironmentObject var focusManager: FocusManager

    private var monthlyTotalTime: TimeInterval {
        let calendar = Calendar.current
        let month = calendar.component(.month, from: Date())
        let year = calendar.component(.year, from: Date())

        return focusManager.allSessions
            .filter {
                let sessionMonth = calendar.component(.month, from: $0.startTime)
                let sessionYear = calendar.component(.year, from: $0.startTime)
                return sessionMonth == month && sessionYear == year
            }
            .reduce(0) { $0 + $1.totalFocusTime }
    }

    private var continuousDays: Int {
        let calendar = Calendar.current
        var days = 0
        var currentDate = calendar.startOfDay(for: Date())

        while true {
            let hasPractice = focusManager.allSessions.contains { session in
                calendar.isDate(session.startTime, inSameDayAs: currentDate)
            }

            if hasPractice {
                days += 1
                guard let previousDay = calendar.date(byAdding: .day, value: -1, to: currentDate) else { break }
                currentDate = previousDay
            } else {
                break
            }
        }

        return days
    }

    private var highestBadge: Badge? {
        focusManager.badgeManager.badges.max(by: { $0.level.timeRange.lowerBound < $1.level.timeRange.lowerBound })
    }

    var body: some View {
        HStack(spacing: 12) {
            QuickStatItem(
                icon: "⏱️",
                value: TimeFormatter.formatTimeIntervalShort(monthlyTotalTime),
                label: "This Month".localized
            )

            Divider()

            QuickStatItem(
                icon: "🔥",
                value: "\(continuousDays)",
                label: "Streak".localized
            )

            Divider()

            if let badge = highestBadge {
                QuickStatItem(
                    icon: badge.level.iconName,
                    value: badge.level.displayName,
                    label: "Highest".localized
                )
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
}

/**
 * @struct QuickStatItem
 * @description 快速统计项
 */
struct QuickStatItem: View {
    let icon: String
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 6) {
            if icon.count == 1 {
                Text(icon)
                    .font(.system(size: 28))
            } else {
                Image(systemName: icon)
                    .font(.system(size: 24))
                    .foregroundColor(.blue)
            }

            Text(value)
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.primary)

            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

/**
 * @struct StatsCardsSection
 * @description 统计卡片区域
 */
struct StatsCardsSection: View {
    @Binding var showWeeklyStats: Bool
    @Binding var showMonthlyStats: Bool

    var body: some View {
        VStack(spacing: 12) {
            CollapsibleStatsCard(
                title: "Weekly Statistics".localized,
                icon: "chart.bar.fill",
                isExpanded: $showWeeklyStats
            ) {
                AnyView(WeeklyStatsContent())
            }

            CollapsibleStatsCard(
                title: "Monthly Statistics".localized,
                icon: "calendar",
                isExpanded: $showMonthlyStats
            ) {
                AnyView(MonthlyStatsContent())
            }
        }
    }
}

/**
 * @struct BadgeShowcaseSection
 * @description 勋章展示墙
 */
struct BadgeShowcaseSection: View {
    @EnvironmentObject var focusManager: FocusManager
    @Binding var showBadgeGuide: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "rosette")
                    .font(.system(size: 24))
                    .foregroundColor(.yellow)

                Text("Badge Collection".localized)
                    .font(.headline)

                Spacer()

                Text("\(focusManager.badgeManager.badges.count)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Button(action: {
                    showBadgeGuide = true
                }) {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 20))
                        .foregroundColor(.blue)
                }
                .accessibilityLabel("Badge Guide".localized)
            }

            if focusManager.badgeManager.badges.isEmpty {
                emptyBadgesView
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(BadgeLevel.allCases, id: \.self) { level in
                            BadgeLevelCard(level: level)
                        }
                    }
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    private var emptyBadgesView: some View {
        VStack(spacing: 12) {
            Image(systemName: "star.circle")
                .font(.system(size: 50))
                .foregroundColor(.gray.opacity(0.5))

            Text("Start practicing to earn badges!".localized)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }
}

/**
 * @struct BadgeLevelCard
 * @description 勋章等级卡片
 */
struct BadgeLevelCard: View {
    @EnvironmentObject var focusManager: FocusManager
    let level: BadgeLevel

    private var count: Int {
        focusManager.badgeManager.badges.filter { $0.level == level }.count
    }

    private var hasUnlocked: Bool {
        count > 0
    }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(hasUnlocked ? Color.yellow.opacity(0.2) : Color.gray.opacity(0.1))
                    .frame(width: 70, height: 70)

                Image(systemName: level.iconName)
                    .font(.system(size: 35))
                    .foregroundColor(hasUnlocked ? .yellow : .gray.opacity(0.5))
            }

            Text(level.displayName)
                .font(.caption)
                .foregroundColor(hasUnlocked ? .primary : .secondary)

            if count > 1 {
                Text("×\(count)")
                    .font(.caption2)
                    .foregroundColor(.blue)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.blue.opacity(0.1)))
            }
        }
        .frame(width: 90)
        .padding(.vertical, 8)
        .background(Color(.tertiarySystemBackground))
        .cornerRadius(12)
        .opacity(hasUnlocked ? 1 : 0.6)
    }
}

/**
 * @struct EquipmentProgressSection
 * @description 装备解锁进度区域
 */
struct EquipmentProgressSection: View {
    @EnvironmentObject var focusManager: FocusManager

    private var nextBadge: (level: BadgeLevel, progress: Double)? {
        let currentMonthTime = getCurrentMonthFocusTime()
        let currentMinutes = currentMonthTime / 60

        for level in BadgeLevel.allCases {
            if currentMinutes < level.timeRange.lowerBound {
                let progress = currentMinutes / level.timeRange.lowerBound
                return (level, progress)
            }
        }
        return nil
    }

    private func getCurrentMonthFocusTime() -> TimeInterval {
        let calendar = Calendar.current
        let month = calendar.component(.month, from: Date())
        let year = calendar.component(.year, from: Date())

        return focusManager.allSessions
            .filter {
                let sessionMonth = calendar.component(.month, from: $0.startTime)
                let sessionYear = calendar.component(.year, from: $0.startTime)
                return sessionMonth == month && sessionYear == year
            }
            .reduce(0) { $0 + $1.totalFocusTime }
    }

    var body: some View {
        if let next = nextBadge {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "gift.fill")
                        .foregroundColor(.purple)

                    Text("Next Unlock".localized)
                        .font(.headline)

                    Spacer()
                }

                HStack {
                    Image(systemName: next.level.iconName)
                        .font(.system(size: 30))
                        .foregroundColor(.yellow)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(next.level.displayName)
                            .font(.subheadline)
                            .fontWeight(.semibold)

                        ProgressView(value: next.progress)
                            .tint(.purple)

                        let remaining = next.level.timeRange.lowerBound - (getCurrentMonthFocusTime() / 60)
                        Text("\(Int(remaining)) minutes to unlock".localized)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding()
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)
        }
    }
}

#Preview {
    let manager = FocusManager()
    return AvatarShowroomView()
        .environmentObject(manager)
}
