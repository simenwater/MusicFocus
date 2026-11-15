import SwiftUI

/**
 * @struct BadgeView
 * @description 勋章视图组件
 */
struct BadgeView: View {
    let badge: Badge
    let size: CGFloat
    @EnvironmentObject var focusManager: FocusManager
    @State private var showingDetail = false
    
    init(badge: Badge, size: CGFloat = 40) {
        self.badge = badge
        self.size = size
    }
    
    // 格式化日期
    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = AppLocalization.locale
        formatter.dateStyle = .medium  // 使用系统本地化的中等日期格式
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
    
    private func formattedTime(_ seconds: TimeInterval) -> String {
        TimeFormatter.formatTimeInterval(seconds)
    }

    private func getTimeRangeText(_ range: ClosedRange<Double>) -> String {
        TimeFormatter.formatBadgeRange(range)
    }

    // 获取同等级的所有勋章记录
    private func getAllBadgesOfSameLevel() -> [(date: Date, focusTime: TimeInterval, sessions: Int)] {
        return focusManager.badgeManager.badges
            .filter { $0.level == badge.level }
            .map { badge in
                let day = focusManager.practiceStatistics.day(badge.date)
                return (date: badge.date, focusTime: day.focusTime, sessions: day.sessions.count)
            }
            .sorted { $0.date > $1.date } // 按日期降序排序
    }
    
    // 获取勋章主色调
    private func getBadgeMainColor(_ level: BadgeLevel) -> Color {
        switch level {
        case .bronze: return Color(red: 205/255, green: 127/255, blue: 50/255)
        case .silver: return Color(red: 192/255, green: 192/255, blue: 192/255)
        case .gold: return Color(red: 255/255, green: 215/255, blue: 0/255)
        case .platinum: return Color(red: 90/255, green: 167/255, blue: 167/255)
        case .diamond: return Color(red: 185/255, green: 242/255, blue: 255/255)
        case .master: return Color.purple
        case .king: return Color.red
        }
    }
    
    // 获取勋章渐变色
    private func getBadgeGradient(_ level: BadgeLevel) -> LinearGradient {
        let mainColor = getBadgeMainColor(level)
        return LinearGradient(
            gradient: Gradient(colors: [
                mainColor.opacity(0.6),
                mainColor,
                mainColor.opacity(0.6)
            ]),
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
    
    // 获取勋章装饰效果
    @ViewBuilder
    private func getBadgeDecoration(_ level: BadgeLevel) -> some View {
        switch level {
        case .bronze:
            EmptyView()
        case .silver:
            Image(systemName: "star.fill")
                .font(.system(size: size * 0.3))
                .foregroundColor(.white.opacity(0.8))
                .offset(x: 0, y: -size * 0.1)
        case .gold:
            Image(systemName: "star.fill")
                .font(.system(size: size * 0.3))
                .foregroundColor(.yellow)
                .offset(x: 0, y: -size * 0.1)
        case .platinum:
            ZStack {
                Image(systemName: "star.fill")
                    .font(.system(size: size * 0.3))
                    .foregroundColor(.white)
                Image(systemName: "sparkles")
                    .font(.system(size: size * 0.3))
                    .foregroundColor(.white.opacity(0.8))
            }
            .offset(x: 0, y: -size * 0.1)
        case .diamond:
            ZStack {
                Image(systemName: "star.fill")
                    .font(.system(size: size * 0.3))
                    .foregroundColor(.blue)
                Image(systemName: "sparkles")
                    .font(.system(size: size * 0.3))
                    .foregroundColor(.white)
            }
            .offset(x: 0, y: -size * 0.1)
        case .master:
            ZStack {
                Image(systemName: "star.fill")
                    .font(.system(size: size * 0.3))
                    .foregroundColor(.yellow)
                Image(systemName: "crown.fill")
                    .font(.system(size: size * 0.3))
                    .foregroundColor(.purple)
            }
            .offset(x: 0, y: -size * 0.1)
        case .king:
            ZStack {
                Image(systemName: "star.fill")
                    .font(.system(size: size * 0.3))
                    .foregroundColor(.yellow)
                Image(systemName: "crown.fill")
                    .font(.system(size: size * 0.3))
                    .foregroundColor(.red)
            }
            .offset(x: 0, y: -size * 0.1)
        }
    }
    
    var body: some View {
        Button(action: {
            showingDetail = true
        }) {
            ZStack {
                // 主勋章
                VStack(spacing: 4) {
                    ZStack {
                        // 背景光晕效果
                        Circle()
                            .fill(getBadgeMainColor(badge.level).opacity(0.1))
                            .frame(width: size * 1.2, height: size * 1.2)
                            .blur(radius: 5)
                        
                        // 主勋章图标
                        Image(systemName: badge.level.iconName)
                            .font(.system(size: size))
                            .foregroundStyle(getBadgeGradient(badge.level))
                            .symbolRenderingMode(.hierarchical)
                            .shadow(color: getBadgeMainColor(badge.level).opacity(0.5), radius: 2, x: 0, y: 2)
                        
                        // 装饰效果
                        getBadgeDecoration(badge.level)
                    }
                    
                    Text(badge.level.displayName)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(width: size + 20, height: size + 48)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(.systemBackground))
                    .shadow(color: Color.black.opacity(0.1), radius: 4, x: 0, y: 2)
            )
        }
        .sheet(isPresented: $showingDetail) {
            NavigationView {
                List {
                    Section(header: Text("勋章等级".localized)) {
                        HStack {
                            BadgeView(badge: badge, size: 30)
                                .environmentObject(focusManager)
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text(badge.level.displayName)
                                    .font(.headline)

                                Text("Required practice time: %@".localizedFormat(getTimeRangeText(badge.level.timeRange)))
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.leading, 8)
                        }
                        .padding(.vertical, 4)
                    }
                    
                    Section(header: Text("获得记录".localized)) {
                        let allRecords = getAllBadgesOfSameLevel()
                        ForEach(allRecords, id: \.date) { record in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(formattedDate(record.date))
                                        .font(.headline)
                                    
                                    Spacer()
                                    
                                    Text("%d practice sessions".localizedFormat(record.sessions))
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                }
                                
                                HStack {
                                    Image(systemName: "clock.fill")
                                        .foregroundColor(.blue)
                                    Text("Practice time: %@".localizedFormat(formattedTime(record.focusTime)))
                                        .foregroundColor(.secondary)
                                }
                                .font(.subheadline)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                .navigationTitle("勋章详情".localized)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("关闭".localized) {
                            showingDetail = false
                        }
                    }
                }
            }
        }
    }
}

/**
 * @struct BadgeGridView
 * @description 勋章网格视图
 */
struct BadgeGridView: View {
    let badges: [Badge]
    let badgeSize: CGFloat
    let columns = [
        GridItem(.adaptive(minimum: 60, maximum: 80), spacing: 16)
    ]
    
    init(badges: [Badge], badgeSize: CGFloat = 40) {
        self.badges = badges
        self.badgeSize = badgeSize
    }
    
    // 获取合并后的勋章列表（同类型勋章合并）
    private var mergedBadges: [(Badge, Int)] {
        var badgeCount: [BadgeLevel: Int] = [:]
        var firstBadge: [BadgeLevel: Badge] = [:]
        
        // 统计每种勋章的数量，并记录每种类型的第一个勋章
        for badge in badges {
            badgeCount[badge.level, default: 0] += 1
            if firstBadge[badge.level] == nil {
                firstBadge[badge.level] = badge
            }
        }
        
        // 转换为数组并排序
        return BadgeLevel.allCases
            .compactMap { level in
                guard let count = badgeCount[level], let badge = firstBadge[level] else {
                    return nil
                }
                return (badge, count)
            }
    }
    
    var body: some View {
        LazyVGrid(columns: columns, spacing: 16) {
            ForEach(mergedBadges, id: \.0.id) { badge, count in
                ZStack {
                    BadgeView(badge: badge, size: badgeSize)
                    
                    // 只有当数量大于1时才显示计数标记
                    if count > 1 {
                        Text("×\(count)")
                            .font(.system(size: badgeSize * 0.3, weight: .bold))
                            .foregroundColor(.white)
                            .padding(4)
                            .background(
                                Capsule()
                                    .fill(Color.blue)
                            )
                            .offset(x: badgeSize * 0.4, y: -badgeSize * 0.4)
                    }
                }
            }
        }
        .padding()
    }
}

#Preview {
    VStack {
        BadgeView(badge: Badge(level: .bronze))
        BadgeView(badge: Badge(level: .silver))
        BadgeView(badge: Badge(level: .gold))
        BadgeView(badge: Badge(level: .platinum))
        BadgeView(badge: Badge(level: .diamond))
        BadgeView(badge: Badge(level: .master))
        BadgeView(badge: Badge(level: .king))
    }
    .padding()
}
