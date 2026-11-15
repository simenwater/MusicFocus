import SwiftUI
import Charts
import UIKit

/**
 * @struct PracticeRecordView
 * @description 练习记录视图，合并了历史记录和统计功能
 */
struct PracticeRecordView: View {
    @EnvironmentObject var focusManager: FocusManager
    @EnvironmentObject private var scoreLibrary: ScoreLibrary
    @Environment(\.scoreExternalWindowID) private var externalWindowID
    @State private var showWeeklyStats = true
    @State private var showPracticeNotes = false
    @State private var showBadgeGuide = false
    @State private var showShareSheet = false
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    NavigationLink {
                        ScoreStatisticsView()
                    } label: {
                        Label("score.statistics".localized, systemImage: "music.note.list")
                            .font(.headline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                    }
                    .accessibilityIdentifier("scoreStatisticsOpen")

                    VStack(alignment: .leading, spacing: 8) {
                        Label("practice.calendar".localized, systemImage: "calendar")
                            .font(.headline)
                        Text("practice.calendarHint".localized)
                            .font(.caption).foregroundStyle(.secondary)
                        MonthlyStatsContent()
                    }
                    .padding()
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))

                    RecentPracticeSessions()

                    CollapsibleStatsCard(
                        title: "practice.recentSevenDays".localized,
                        icon: "chart.bar.fill",
                        isExpanded: $showWeeklyStats
                    ) {
                        AnyView(WeeklyStatsContent())
                    }

                    BadgeShowcaseSection(showBadgeGuide: $showBadgeGuide)

                    CollapsibleStatsCard(
                        title: "Practice Notes".localized,
                        icon: "note.text",
                        isExpanded: $showPracticeNotes
                    ) {
                        AnyView(PracticeNotesContent())
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Practice Record".localized)
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        showShareSheet = true
                    }) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 18))
                    }
                    .accessibilityLabel("Share Weekly Practice".localized)
                }
            }
        }
        .sheet(isPresented: $showBadgeGuide) {
            BadgeGuideView()
                .environmentObject(focusManager)
        }
        .onChange(of: scoreLibrary.externalRequestID) { _, _ in
            guard scoreLibrary.handlesExternalFiles(in: externalWindowID) else { return }
            showBadgeGuide = false
        }
        .onChange(of: showShareSheet) { _, newValue in
            if newValue {
                // 当share按钮点击时，调用分享功能
                shareWeeklyPracticeData()
                showShareSheet = false
            }
        }
    }
    
    /**
     * @method shareWeeklyPracticeData
     * @description 分享最近七天的练习数据
     */
    private func shareWeeklyPracticeData() {
        // 获取过去7天的日期数组
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let weekDates = (0..<7).map { dayOffset in
            calendar.date(byAdding: .day, value: -dayOffset, to: today)!
        }.reversed()
        
        // 收集每日练习数据
        let dateFormatter = DateFormatter()
        dateFormatter.locale = AppLocalization.locale
        dateFormatter.setLocalizedDateFormatFromTemplate("MMMMd")  // 使用本地化的月日格式
        
        var totalWeeklyFocus: TimeInterval = 0
        var totalWeeklyDistraction: TimeInterval = 0
        var dailyData: [(date: String, weekday: String, focusTime: TimeInterval)] = []
        
        for date in weekDates {
            let focusTime = focusManager.getTotalFocusTimeForDate(date)
            totalWeeklyFocus += focusTime
            totalWeeklyDistraction += focusManager.getTotalDistractionTimeForDate(date)
            
            let dayName = getChineseWeekday(for: date)
            let dateString = dateFormatter.string(from: date)
            
            dailyData.append((date: dateString, weekday: dayName, focusTime: focusTime))
        }
        
        // 获取最近7天的勋章
        let weeklyBadges = focusManager.badgeManager.badges.filter { badge in
            if let daysAgo = calendar.dateComponents([.day], from: calendar.startOfDay(for: badge.date), to: today).day {
                return daysAgo >= 0 && daysAgo < 7
            }
            return false
        }
        
        var badgeNames: [String] = []
        if !weeklyBadges.isEmpty {
            badgeNames = Array(Set(weeklyBadges.map { $0.level.displayName }))
        }
        
        // 计算专注率
        let totalTime = totalWeeklyFocus + totalWeeklyDistraction
        let focusRate = totalTime > 0 ? totalWeeklyFocus / totalTime * 100 : 0
        
        // 生成分享图片
        if let shareImage = renderWeeklyDataToImage(
            dailyData: dailyData,
            totalFocusTime: totalWeeklyFocus,
            totalDistractionTime: totalWeeklyDistraction,
            focusRate: focusRate,
            badges: badgeNames
        ) {
            // 显示分享表单
            let activityVC = UIActivityViewController(
                activityItems: [shareImage],
                applicationActivities: nil
            )
            
            // 获取当前的UIWindow场景
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let window = windowScene.windows.first,
               let rootVC = window.rootViewController {
                // 在iPad上设置弹出位置
                if let popoverController = activityVC.popoverPresentationController {
                    popoverController.sourceView = window
                    popoverController.sourceRect = CGRect(x: window.bounds.midX, y: window.bounds.midY, width: 0, height: 0)
                    popoverController.permittedArrowDirections = []
                }
                rootVC.present(activityVC, animated: true)
            }
        }
    }
    
    /**
     * @method renderWeeklyDataToImage
     * @description 将周练习数据渲染成图片
     * @param dailyData 每日练习数据
     * @param totalFocusTime 总专注时间
     * @param totalDistractionTime 总分心时间
     * @param focusRate 专注率
     * @param badges 勋章列表
     * @return 渲染后的图片
     */
    private func renderWeeklyDataToImage(
        dailyData: [(date: String, weekday: String, focusTime: TimeInterval)],
        totalFocusTime: TimeInterval,
        totalDistractionTime: TimeInterval,
        focusRate: Double,
        badges: [String]
    ) -> UIImage? {
        // 创建一个渲染视图
        let renderView = UIHostingController(rootView: WeeklyDataShareView(
            dailyData: dailyData,
            totalFocusTime: totalFocusTime,
            totalDistractionTime: totalDistractionTime,
            focusRate: focusRate,
            badges: badges
        ))
        
        // 设置渲染视图的尺寸，使用更适合移动设备的宽高比
        // 手机屏幕宽高比约为9:16到9:19.5
        let targetSize = CGSize(width: 1080, height: 1920)
        renderView.view.bounds = CGRect(origin: .zero, size: targetSize)
        renderView.view.backgroundColor = .white
        
        // 确保视图已经加载并布局
        renderView.view.layoutIfNeeded()
        
        // 渲染视图为图片
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        return renderer.image { _ in
            renderView.view.drawHierarchy(in: renderView.view.bounds, afterScreenUpdates: true)
    }
}

/**
     * @method getChineseWeekday
     * @description 获取中文星期名称
     * @param date 日期
     * @return 中文星期名称
     */
    private func getChineseWeekday(for date: Date) -> String {
        // 使用DateFormatter获取本地化的星期名称
        let dateFormatter = DateFormatter()
        dateFormatter.locale = AppLocalization.locale
        dateFormatter.dateFormat = "EEE" // 短星期名称（如：Mon, Tue 或 周一、周二）
        return dateFormatter.string(from: date)
    }
}

/**
 * @struct WeeklyDataShareView
 * @description 周练习数据分享视图
 */
struct WeeklyDataShareView: View {
    let dailyData: [(date: String, weekday: String, focusTime: TimeInterval)]
    let totalFocusTime: TimeInterval
    let totalDistractionTime: TimeInterval
    let focusRate: Double
    let badges: [String]
    @State private var allBadges: [Badge] = []
    
    // 初始化时生成徽章实例
    init(
        dailyData: [(date: String, weekday: String, focusTime: TimeInterval)],
        totalFocusTime: TimeInterval,
        totalDistractionTime: TimeInterval,
        focusRate: Double,
        badges: [String]
    ) {
        self.dailyData = dailyData
        self.totalFocusTime = totalFocusTime
        self.totalDistractionTime = totalDistractionTime
        self.focusRate = focusRate
        self.badges = badges
        
        // 将徽章名称转换为徽章实例
        let allBadgesInit = badges.compactMap { badgeName -> Badge? in
            if let level = BadgeLevel.allCases.first(where: { $0.displayName == badgeName }) {
                return Badge(level: level)
            }
            return nil
        }
        self._allBadges = State(initialValue: allBadgesInit)
    }
    
    var body: some View {
        VStack(spacing: 35) {
            // 标题
            VStack(spacing: 8) {
                Text("My Practice Records".localized)
                    .font(.system(size: 44, weight: .bold))
                    .foregroundColor(.black)

                Text("Last 7 Days".localized)
                    .font(.system(size: 28, weight: .medium))
                    .foregroundColor(.gray)
            }
            .padding(.top, 60)
            .padding(.bottom, 30)

            // 获得的勋章
            VStack(alignment: .leading, spacing: 20) {
                Text("Earned Badges".localized)
                    .font(.system(size: 32, weight: .bold))
                    .foregroundColor(.black)
                    .padding(.horizontal)

                if allBadges.isEmpty {
                    Text("No badges this week".localized)
                        .font(.system(size: 24))
                        .foregroundColor(.gray)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 30)
                } else {
                    // 使用原有的徽章视图，只增大尺寸
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 20) {
                            ForEach(allBadges, id: \.id) { badge in
                                BadgeView(badge: badge, size: 80) // 调整尺寸但保持比例
                            }
                        }
                        .padding(.vertical, 20)
                        .padding(.horizontal)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 20)
            .background(Color.white)
            .cornerRadius(20)
            .shadow(color: Color.black.opacity(0.1), radius: 8, x: 0, y: 4)
            .padding(.horizontal)
            
            // 每日练习时间
            VStack(alignment: .leading, spacing: 20) {
                Text("Daily Practice Time".localized)
                    .font(.system(size: 32, weight: .bold))
                    .foregroundColor(.black)
                    .padding(.horizontal)
                
                VStack(spacing: 18) {
                    ForEach(dailyData, id: \.date) { data in
                        HStack(alignment: .center) {
                            Text("\(data.date) (\(data.weekday))")
                                .font(.system(size: 24, weight: .medium))
                                .foregroundColor(.black)
                                .frame(width: 220, alignment: .leading)
                        
                        Spacer()
                        
                            // 时间条
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.gray.opacity(0.2))
                                    .frame(height: 30)
                                
                                let width = min(CGFloat(data.focusTime / 3600) * 60, 300)
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.green)
                                    .frame(width: max(width, 6), height: 30)
                            }
                            .frame(height: 30)
                            .frame(width: 300)
                            
                            Text(TimeFormatter.formatTimeInterval(data.focusTime))
                                .font(.system(size: 22, weight: .medium))
                                .foregroundColor(.black)
                                .frame(width: 120, alignment: .trailing)
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 12)
                        .background(Color.white.opacity(0.8))
                        .cornerRadius(12)
                    }
                }
                .padding(.horizontal)
            }
            .padding(.vertical, 20)
            .background(Color.white)
            .cornerRadius(20)
            .shadow(color: Color.black.opacity(0.1), radius: 8, x: 0, y: 4)
            .padding(.horizontal)
            
            // 总练习数据
            VStack(alignment: .leading, spacing: 20) {
                Text("Total Practice Data".localized)
                    .font(.system(size: 32, weight: .bold))
                    .foregroundColor(.black)
                    .padding(.horizontal)

                HStack(spacing: 20) {
                    VStack(spacing: 12) {
                        Text("Focus Time".localized)
                            .font(.system(size: 22))
                            .foregroundColor(.gray)

                        Text(TimeFormatter.formatTimeInterval(totalFocusTime))
                            .font(.system(size: 28, weight: .bold))
                            .foregroundColor(.green)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .padding(.vertical, 16)
                    .background(Color.green.opacity(0.1))
                    .cornerRadius(16)

                    VStack(spacing: 12) {
                        Text("Distraction Time".localized)
                            .font(.system(size: 22))
                            .foregroundColor(.gray)
                        
                        Text(TimeFormatter.formatTimeInterval(totalDistractionTime))
                            .font(.system(size: 28, weight: .bold))
                            .foregroundColor(.red)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .padding(.vertical, 16)
                    .background(Color.red.opacity(0.1))
                    .cornerRadius(16)
                }
                .padding(.horizontal)
                
                // 专注率
                VStack(spacing: 12) {
                    Text("Focus Rate".localized)
                        .font(.system(size: 24))
                        .foregroundColor(.gray)
                    
                    HStack(spacing: 10) {
                        Text(String(format: "%.1f%%", focusRate))
                            .font(.system(size: 38, weight: .bold))
                            .foregroundColor(focusRate >= 80 ? .green : 
                                             focusRate >= 60 ? .orange : .red)
                        
                        // 添加评级图标
                        Image(systemName: focusRate >= 80 ? "star.fill" : 
                              focusRate >= 60 ? "star.leadinghalf.filled" : "exclamationmark.triangle")
                            .font(.system(size: 30))
                            .foregroundColor(focusRate >= 80 ? .green : 
                                             focusRate >= 60 ? .orange : .red)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding()
                .padding(.vertical, 16)
                .background(Color.blue.opacity(0.1))
                .cornerRadius(16)
                .padding(.horizontal)
                .padding(.bottom, 10)
            }
            .padding(.vertical, 20)
            .background(Color.white)
            .cornerRadius(20)
            .shadow(color: Color.black.opacity(0.1), radius: 8, x: 0, y: 4)
            .padding(.horizontal)
            
            Spacer()
            
            // 页脚
            VStack(spacing: 8) {
                Text("MusicFocus")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(.black.opacity(0.7))

                Text("Music Focus Practice Assistant".localized)
                    .font(.system(size: 20))
                    .foregroundColor(.gray)
            }
            .padding(.bottom, 50)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(
                gradient: Gradient(colors: [
                    Color(.systemBackground),
                    Color(.systemGray6).opacity(0.7),
                    Color(.systemGray5).opacity(0.5)
                ]),
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .edgesIgnoringSafeArea(.all)
    }
}

#Preview {
    PracticeRecordView()
        .environmentObject(FocusManager())
        .environmentObject(ScoreLibrary())
}

