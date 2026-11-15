import SwiftUI

/**
 * @struct StudentDetailView
 * @description 学生练习详情视图
 */
struct StudentDetailView: View {
    let student: Student
    @State private var selectedTimeRange: TimeRange = .week
    
    enum TimeRange {
        case week
        case month
        case total
    }
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // 时间范围选择器
                Picker("Time Range".localized, selection: $selectedTimeRange) {
                    Text("This Week".localized).tag(TimeRange.week)
                    Text("This Month".localized).tag(TimeRange.month)
                    Text("Total".localized).tag(TimeRange.total)
                }
                .pickerStyle(SegmentedPickerStyle())
                .padding()
                
                // 练习统计
                VStack(spacing: 15) {
                    // 根据选择的时间范围显示不同的统计数据
                    switch selectedTimeRange {
                    case .week:
                        WeeklyStatsCard(student: student)
                    case .month:
                        MonthlyStatsCard(student: student)
                    case .total:
                        TotalStatsCard(student: student)
                    }
                }
                .padding(.horizontal)
                
                // 练习记录列表
                VStack(alignment: .leading, spacing: 10) {
                    Text("Practice Record".localized)
                        .font(.headline)
                        .padding(.horizontal)

                    let records = selectedRecords
                    if records.isEmpty {
                        Text("No practice records yet".localized)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding()
                    } else {
                        ForEach(records) { session in
                            SessionListItem(session: session)
                                .padding(.horizontal)
                        }
                    }
                }
            }
        }
        .navigationTitle(student.name)
    }
    
    // 根据选择的时间范围获取练习记录
    private var selectedRecords: [FocusSession] {
        switch selectedTimeRange {
        case .week:
            return student.weeklyRecords
        case .month:
            return student.monthlyRecords
        case .total:
            return student.practiceRecords
        }
    }
}

/**
 * @struct WeeklyStatsCard
 * @description 周统计卡片
 */
struct WeeklyStatsCard: View {
    let student: Student
    
    var body: some View {
        VStack(spacing: 15) {
            HStack(spacing: 20) {
                StatisticItem(
                    title: "练琴天数",
                    value: "\(student.weeklyPracticeDays)天",
                    icon: "calendar",
                    color: .blue
                )
                
                StatisticItem(
                    title: "累计时长",
                    value: TimeFormatter.formatTimeInterval(student.weeklyPracticeTime),
                    icon: "clock",
                    color: .green
                )
                
                StatisticItem(
                    title: "平均专注度",
                    value: "\(Int(student.weeklyFocusRate * 100))%",
                    icon: "brain",
                    color: .purple
                )
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(15)
    }
}

/**
 * @struct MonthlyStatsCard
 * @description 月统计卡片
 */
struct MonthlyStatsCard: View {
    let student: Student
    
    var body: some View {
        // 暂时复用周统计的UI，后续可以添加更多月度特定的统计
        WeeklyStatsCard(student: student)
    }
}

/**
 * @struct TotalStatsCard
 * @description 总计统计卡片
 */
struct TotalStatsCard: View {
    let student: Student
    
    var body: some View {
        // 暂时复用周统计的UI，后续可以添加更多总计特定的统计
        WeeklyStatsCard(student: student)
    }
} 