//
//  FocusTimerView.swift
//  MusicFocus
//
//  Created by 姜伯龙 on 2025/3/7.
//

import SwiftUI
import Combine

/**
 * @struct AudioLevelIndicator
 * @description 音量水平指示器组件
 */
struct AudioLevelIndicator: View {
    var decibels: Float
    var isActive: Bool
    
    // 分贝值的映射范围
    private let minDB: Float = -60.0
    private let maxDB: Float = 0.0
    
    // 计算归一化的音量水平（0-1）
    private var normalizedLevel: CGFloat {
        guard decibels.isFinite else { return 0 }
        let normalized = CGFloat((decibels - minDB) / (maxDB - minDB))
        return min(max(normalized, 0), 1)
    }
    
    var body: some View {
        VStack(spacing: 4) {
            Text("Volume Level".localized)
                .font(.caption)
                .foregroundColor(.secondary)
             // Meters also appear in a narrow score-reader popover. Measure the
            // container instead of imposing a fraction of the device screen.
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4).fill(Color.gray.opacity(0.2))
                    RoundedRectangle(cornerRadius: 4)
                        .fill(LinearGradient(colors: [.green, .yellow, .red],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: geometry.size.width * normalizedLevel)
                }
            }
            .frame(height: 8)
             Text(isActive ? String(format: "%.1f dB", decibels) : "Monitoring Paused".localized)
                .font(.caption2)
                .foregroundColor(isActive ? .primary : .secondary)
        }
    }
}

/**
 * @struct MusicProbabilityIndicator
 * @description 音乐概率指示器组件
 */
struct MusicProbabilityIndicator: View {
    var probability: Float
    var isActive: Bool
    var title: String = "Instrument Detection".localized

    private var normalizedProbability: CGFloat {
        probability.isFinite ? CGFloat(min(max(probability, 0), 1)) : 0
    }
    
    private var color: Color {
        if probability >= 0.8 {
            return .green
        } else if probability >= 0.6 {
            return .yellow
        } else if probability >= 0.4 {
            return .orange
        } else {
            return .red
        }
    }
    
    var body: some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
             GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4).fill(Color.gray.opacity(0.2))
                    RoundedRectangle(cornerRadius: 4).fill(color)
                        .frame(width: geometry.size.width * normalizedProbability)
                }
            }
            .frame(height: 8)
             Text(isActive ? String(format: "%.1f%%", probability * 100) : "Monitoring Paused".localized)
                .font(.caption2)
                .foregroundColor(isActive ? color : .secondary)
        }
    }
}

/**
 * @struct FeatureRow
 * @description 用于显示AI分析的单个特征行
 */
struct FeatureRow: View {
    var title: String
    var value: Float
    var description: String
    var color: Color
    
    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
                     Spacer()
                     Text(String(format: "%.0f%%", value * 100))
                    .font(.caption)
                    .foregroundColor(color)
            }
             ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.gray.opacity(0.2))
                    .frame(height: 6)
                    .cornerRadius(3)
                     Rectangle()
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: [color.opacity(0.5), color]),
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: CGFloat(value) * UIScreen.main.bounds.width * 0.75, height: 6)
                    .cornerRadius(3)
            }
             Text(description)
                .font(.caption2)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 2)
        }
    }
}

/**
 * @struct DistractionDetailView
 * @description 分心详情列表视图
 */
struct DistractionDetailView: View {
    var distractions: [Distraction]
    var totalDistractionTime: TimeInterval
    
    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("Distraction Records".localized)
                    .font(.headline)
                Spacer()
                Text("%d times, total %@".localizedFormat(distractions.count, TimeFormatter.formatTimeInterval(totalDistractionTime)))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.bottom, 5)

            if distractions.isEmpty {
                Text("Great! No distractions recorded".localized)
                    .font(.subheadline)
                    .foregroundColor(.green)
                    .padding(.vertical, 10)
            } else {
                ForEach(distractions) { distraction in
                    DistractionItemView(distraction: distraction)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
}

/**
 * @struct DistractionItemView
 * @description 单条分心记录视图
 */
struct DistractionItemView: View {
    var distraction: Distraction
    
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundColor(.orange)
                Text(distraction.description.localized)
                    .font(.subheadline)
                Spacer()
                Text(TimeFormatter.formatTimeInterval(distraction.duration))
                    .font(.caption)
                    .foregroundColor(.red)
            }
             Text("\(TimeFormatter.formatTime(distraction.startTime)) - \(distraction.endTime != nil ? TimeFormatter.formatTime(distraction.endTime!) : "In Progress".localized)")
                .font(.caption2)
                .foregroundColor(.secondary)
             Divider()
                .padding(.vertical, 2)
        }
    }
}

/**
 * @struct FocusTimerView
 * @description 专注力时钟主视图
 */
struct FocusTimerView: View {
    var showsLibraryEntry = true
    @EnvironmentObject var focusManager: FocusManager
    @EnvironmentObject private var scoreLibrary: ScoreLibrary
    @Environment(\.scoreExternalWindowID) private var externalWindowID
    @State private var timeElapsed: TimeInterval = 0
    @State private var timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State private var showingPermissionAlert = false
    @State private var showDetailedStats = false
    @State private var totalsDay = Date.distantPast
    @State private var isVisible = false
    private var todayFocusTime: TimeInterval {
        focusManager.practiceStatistics.day(Date()).focusTime
    }
    @State private var currentPureFocusTime: TimeInterval = 0 // 本次纯专注时间
    @State private var currentDistractionTime: TimeInterval = 0 // 本次分心时间
    
    // 练习内容记录
    
    // 添加以下状态变量和方法
    @State private var showTodaySessionsSheet = false
    @State private var todaySessions: [FocusSession] = []
    @State private var editingSessionIndex: Int? = nil
    @State private var editPieceName: String = ""
    @State private var editImprovements: String = ""
    @State private var editNotes: String = ""

    // 消融实验按钮状态

    // 主题预览状态（用于实验模式）
    @State private var previewTheme: String? = nil

    // 紫色主题流光动画位置偏移
    @State private var gradientOffset: Double = 0

    // 王者红色主题动画状态
    @State private var pulseScale: Double = 1.0           // 径向呼吸缩放
    @State private var lightningOpacity: Double = 0.0     // 闪电透明度
    @State private var lightningOffset: CGFloat = 0       // 闪电位置偏移
    @State private var lightningRotation: Double = 0      // 环形雷电旋转角度
    @State private var lightningPulse: Double = 1.0       // 环形雷电脉冲效果

    // MARK: - 动态主题颜色

    /**
     * @enum AppThemeState
     * @description 应用主题状态
     */
    private enum AppThemeState {
        case idle       // 空闲状态 - 蓝色主题
        case distracted // 分心状态 - 橙色主题
        case practicing // 练琴状态 - 绿色主题
    }

    /**
     * @struct ThemeColors
     * @description 主题颜色配置
     */
    private struct ThemeColors {
        let background: Color     // 整体页面背景色
        let primary: Color        // 主色调（按钮、数字、圆圈）
        let light: Color          // 浅色背景（Focus Data卡片）
        let circle: [Color]       // 圆圈渐变色
        let statusText: Color     // 状态文本颜色
        let titleText: Color      // 标题文字颜色
        let secondaryText: Color  // 次级文字颜色

        // 默认主题 - 蓝色（0-青铜：0-60分钟）
        static let blue = ThemeColors(
            background: Color(red: 0.961, green: 0.961, blue: 0.969),  // #F5F5F7 浅灰背景
            primary: Color(red: 0.24, green: 0.48, blue: 0.71),
            light: Color(red: 0.9, green: 0.94, blue: 0.98),
            circle: [.blue, .purple],
            statusText: .blue,
            titleText: Color(red: 0.067, green: 0.094, blue: 0.153),   // #111827
            secondaryText: Color(red: 0.420, green: 0.451, blue: 0.502) // #6B7280
        )

        // 分心状态 - 暖日橙（motivated practice）
        static let orange = ThemeColors(
            background: Color(red: 1.0, green: 0.969, blue: 0.929),    // #FFF7ED 微微偏暖背景
            primary: Color(red: 0.976, green: 0.451, blue: 0.086),     // #F97316 主色
            light: Color(red: 1.0, green: 0.929, blue: 0.835),         // #FFEDD5 浅主色
            circle: [Color(red: 0.976, green: 0.451, blue: 0.086), Color(red: 0.988, green: 0.353, blue: 0.094)],
            statusText: Color(red: 0.976, green: 0.451, blue: 0.086),
            titleText: Color(red: 0.067, green: 0.094, blue: 0.153),   // #111827
            secondaryText: Color(red: 0.294, green: 0.333, blue: 0.388) // #4B5563
        )

        // 练琴专注状态 - 森林绿（calm focus）
        static let green = ThemeColors(
            background: Color(red: 0.961, green: 0.961, blue: 0.969),  // #F5F5F7 浅灰背景
            primary: Color(red: 0.086, green: 0.639, blue: 0.290),     // #16A34A 主色
            light: Color(red: 0.863, green: 0.988, blue: 0.906),       // #DCFCE7 浅主色
            circle: [Color(red: 0.086, green: 0.639, blue: 0.290), Color(red: 0.133, green: 0.545, blue: 0.133)],
            statusText: Color(red: 0.086, green: 0.639, blue: 0.290),
            titleText: Color(red: 0.067, green: 0.094, blue: 0.153),   // #111827
            secondaryText: Color(red: 0.420, green: 0.451, blue: 0.502) // #6B7280
        )

        // 米色主题 - 白银-黄金（60-120分钟）
        static let beige = ThemeColors(
            background: Color(red: 0.961, green: 0.941, blue: 0.910),  // #F5F0E8 浅米色背景
            primary: Color(red: 0.769, green: 0.647, blue: 0.447),     // #C4A572 驼色主色
            light: Color(red: 0.980, green: 0.969, blue: 0.949),       // #FAF7F2 极浅米色
            circle: [Color(red: 0.769, green: 0.647, blue: 0.447), Color(red: 0.722, green: 0.584, blue: 0.416)],
            statusText: Color(red: 0.769, green: 0.647, blue: 0.447),
            titleText: Color(red: 0.067, green: 0.094, blue: 0.153),   // #111827
            secondaryText: Color(red: 0.420, green: 0.451, blue: 0.502) // #6B7280
        )

        // 青色主题 - 铂金-钻石（120-240分钟）
        static let cyan = ThemeColors(
            background: Color(red: 0.929, green: 0.969, blue: 0.969),  // #EDF7F7 浅青背景
            primary: Color(red: 0.086, green: 0.580, blue: 0.588),     // #16949696 深青主色
            light: Color(red: 0.800, green: 0.941, blue: 0.949),       // #CCF0F2 浅青主色
            circle: [Color(red: 0.086, green: 0.580, blue: 0.588), Color(red: 0.133, green: 0.490, blue: 0.557)],
            statusText: Color(red: 0.086, green: 0.580, blue: 0.588),
            titleText: Color(red: 0.067, green: 0.094, blue: 0.153),   // #111827
            secondaryText: Color(red: 0.420, green: 0.451, blue: 0.502) // #6B7280
        )

        // 紫色主题 - 大师+（240分钟以上）
        static let purple = ThemeColors(
            background: Color(red: 0.961, green: 0.929, blue: 0.980),  // #F5EDF9 浅紫背景
            primary: Color(red: 0.584, green: 0.282, blue: 0.769),     // #9548C4 深紫主色
            light: Color(red: 0.922, green: 0.843, blue: 0.969),       // #EBD7F7 浅紫主色
            circle: [Color(red: 0.584, green: 0.282, blue: 0.769), Color(red: 0.745, green: 0.282, blue: 0.816), Color(red: 0.459, green: 0.388, blue: 0.878)],  // 三色渐变
            statusText: Color(red: 0.584, green: 0.282, blue: 0.769),
            titleText: Color(red: 0.067, green: 0.094, blue: 0.153),   // #111827
            secondaryText: Color(red: 0.420, green: 0.451, blue: 0.502) // #6B7280
        )

        // 🌌 霓虹王冠 - 深色霓虹主题（王者：360分钟以上）
        static let red = ThemeColors(
            background: Color(red: 0.063, green: 0.043, blue: 0.157),  // #100B28 深紫黑背景（会叠加渐变）
            primary: Color(red: 0.0, green: 0.961, blue: 1.0),         // #00F5FF 霓虹青主色
            light: Color(red: 0.102, green: 0.078, blue: 0.196),       // #1A1432 深紫灰卡片（半透明基底）
            circle: [
                Color(red: 1.0, green: 0.235, blue: 0.675),    // #FF3CAC 霓虹粉
                Color(red: 0.0, green: 0.961, blue: 1.0),      // #00F5FF 霓虹青
                Color(red: 0.612, green: 1.0, blue: 0.180)     // #9CFF2E 荧光绿
            ],
            statusText: Color(red: 0.0, green: 0.961, blue: 1.0),      // #00F5FF 霓虹青状态文字
            titleText: Color(red: 1.0, green: 0.235, blue: 0.675),     // #FF3CAC 霓虹粉标题
            secondaryText: Color(red: 0.612, green: 1.0, blue: 0.180)  // #9CFF2E 荧光绿次级文本
        )
    }

    /**
     * @computed currentThemeState
     * @description 计算当前应用的主题状态
     */
    private var currentThemeState: AppThemeState {
        // 如果未开始专注，显示蓝色（空闲）
        if !focusManager.isActive {
            return .idle
        }

        // 如果正在分心，显示橙色
        if focusManager.currentDistraction != nil {
            return .distracted
        }

        // 如果检测到乐器声音，显示绿色（练琴中）
        if focusManager.audioMonitor.isPlayingMusic || focusManager.pendingSilenceStart != nil {
            return .practicing
        }

        // 默认显示橙色（已开始但未检测到乐器）
        return .distracted
    }

    /**
     * @computed shouldShowShimmerEffect
     * @description 判断是否显示流光效果（仅紫色主题且空闲状态）
     */
    private var shouldShowShimmerEffect: Bool {
        // 只在空闲状态显示
        guard !focusManager.isActive else { return false }

        // 判断是否是紫色主题
        if let preview = previewTheme {
            return preview == "purple"
        }

        // 或者正常状态下达到大师成就（但不包括王者）
        let todayMinutes = todayFocusTime / 60.0
        return todayMinutes >= 240 && todayMinutes < 360
    }

    /**
     * @computed shouldShowKingEffect
     * @description 判断是否显示王者红色主题的雷霆效果
     */
    private var shouldShowKingEffect: Bool {
        // 只在空闲状态显示
        guard !focusManager.isActive else { return false }

        // 判断是否是红色主题
        if let preview = previewTheme {
            return preview == "red"
        }

        // 或者正常状态下达到王者成就
        let todayMinutes = todayFocusTime / 60.0
        return todayMinutes >= 360
    }

    /**
     * @computed currentTheme
     * @description 根据当前状态获取主题颜色
     */
    private var currentTheme: ThemeColors {
        // 如果有预览主题，优先使用预览主题
        if let preview = previewTheme {
            switch preview {
            case "blue": return .blue
            case "beige": return .beige
            case "cyan": return .cyan
            case "purple": return .purple
            case "red": return .red
            case "orange": return .orange
            case "green": return .green
            default: break
            }
        }

        // 正常主题逻辑
        switch currentThemeState {
        case .idle:
            // 根据今日专注时长选择空闲主题
            let todayMinutes = todayFocusTime / 60.0
            if todayMinutes >= 360 {  // 王者级别（6小时+）
                return .red
            } else if todayMinutes >= 240 {  // 大师级别（4小时+）
                return .purple
            } else if todayMinutes >= 120 {  // 铂金级别（2小时+）
                return .cyan
            } else if todayMinutes >= 60 {  // 白银级别（1小时+）
                return .beige
            } else {
                return .blue  // 默认蓝色
            }
        case .distracted:
            return .orange
        case .practicing:
            return .green
        }
    }

    var body: some View {
        // 使用GeometryReader获取屏幕宽度，以保持一致的布局宽度
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 25) {
                    // 标题 - 使用动态主题色，无背景框
                    Text("Music Focus".localized)
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .foregroundColor(currentTheme.primary)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity)

                    if showsLibraryEntry { ScoreLibraryEntry(tint: currentTheme.primary) }

                    // 本次和今日累积时间统计
                    VStack(spacing: 12) {
                        Text("Focus Data".localized)
                            .font(.headline)
                            .foregroundColor(currentTheme.titleText)  // 使用主题标题颜色
                            .frame(maxWidth: .infinity, alignment: .leading)

                        HStack(spacing: 10) {
                            // 本次专注时间 - 使用动态主题色
                            VStack(alignment: .center, spacing: 5) {
                                Text("Current Focus".localized)
                                    .font(.caption)
                                    .foregroundColor(currentTheme.primary)

                                Text(TimeFormatter.formatTimeInterval(currentPureFocusTime))
                                    .font(.title3)
                                    .fontWeight(shouldShowKingEffect ? .heavy : .semibold)
                                    .foregroundColor(currentTheme.primary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(
                                currentTheme.light
                                    .overlay(currentTheme.primary.opacity(0.1))
                            )
                            .cornerRadius(10)

                            // 分心时间 - 使用动态主题色
                            VStack(alignment: .center, spacing: 5) {
                                Text("Distraction Time".localized)
                                    .font(.caption)
                                    .foregroundColor(currentTheme.primary)

                                Text(TimeFormatter.formatTimeInterval(currentDistractionTime))
                                    .font(.title3)
                                    .fontWeight(shouldShowKingEffect ? .heavy : .semibold)
                                    .foregroundColor(currentTheme.primary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(
                                currentTheme.light
                                    .overlay(currentTheme.primary.opacity(0.1))
                            )
                            .cornerRadius(10)

                            // 今日专注时间 - 使用动态主题色
                            VStack(alignment: .center, spacing: 5) {
                                Text("Today's Focus".localized)
                                    .font(.caption)
                                    .foregroundColor(currentTheme.primary)

                                Text(TimeFormatter.formatTimeInterval(todayFocusTime))
                                    .font(.title3)
                                    .fontWeight(shouldShowKingEffect ? .heavy : .semibold)
                                    .foregroundColor(currentTheme.primary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(
                                currentTheme.light
                                    .overlay(currentTheme.primary.opacity(0.1))
                            )
                            .cornerRadius(10)
                            .onTapGesture {
                                showTodayFocusSessions()
                            }
                        }
                    }
                    .padding()
                    .background(
                        Group {
                            if shouldShowKingEffect {
                                // 霓虹主题：半透明深色玻璃拟态
                                currentTheme.light.opacity(0.25)
                            } else {
                                // 其他主题：实心卡片
                                currentTheme.light
                            }
                        }
                    )
                    .cornerRadius(16)
                    .overlay(
                        // 霓虹王冠主题：双层边框（静态+动态）
                        Group {
                            if shouldShowKingEffect {
                                ZStack {
                                    // 静态冷色边框（霓虹青）
                                    RoundedRectangle(cornerRadius: 16)
                                        .stroke(
                                            Color(red: 0.0, green: 0.961, blue: 1.0).opacity(0.4),  // #00F5FF 霓虹青
                                            lineWidth: 2
                                        )

                                    // 动态脉冲边框
                                    RoundedRectangle(cornerRadius: 16)
                                        .stroke(
                                            LinearGradient(
                                                gradient: Gradient(colors: [
                                                    Color(red: 1.0, green: 0.235, blue: 0.675).opacity(lightningPulse * 0.7),   // #FF3CAC 霓虹粉
                                                    Color(red: 0.0, green: 0.961, blue: 1.0).opacity(lightningPulse * 0.8),     // #00F5FF 霓虹青
                                                    Color(red: 0.612, green: 1.0, blue: 0.180).opacity(lightningPulse * 0.7)    // #9CFF2E 荧光绿
                                                ]),
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            ),
                                            lineWidth: 3
                                        )
                                        .blur(radius: 6)
                                        .opacity(lightningPulse * 0.6)
                                }
                            }
                        }
                    )
                    .shadow(color: Color.black.opacity(0.1), radius: 10, x: 0, y: 4)
                    // Navigation may temporarily propose zero width. Let padding
                    // reserve the margins instead of creating a negative frame.
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 20)

                    // 时钟显示 - 使用动态主题色
                    ZStack {
                        Circle()
                            .stroke(
                                currentTheme.light,
                                lineWidth: 20
                            )

                        // 霓虹王冠主题：环形霓虹光环
                        if shouldShowKingEffect {
                            // 第一层：霓虹粉-青渐变弧（120度）
                            Circle()
                                .trim(from: 0, to: 0.33)  // 120度圆弧
                                .stroke(
                                    LinearGradient(
                                        gradient: Gradient(colors: [
                                            Color(red: 1.0, green: 0.235, blue: 0.675).opacity(0.9),    // #FF3CAC 霓虹粉
                                            Color(red: 0.0, green: 0.961, blue: 1.0).opacity(1.0),      // #00F5FF 霓虹青
                                            Color(red: 1.0, green: 0.235, blue: 0.675).opacity(0.9)     // #FF3CAC 霓虹粉
                                        ]),
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    ),
                                    style: StrokeStyle(lineWidth: 10, lineCap: .round)
                                )
                                .blur(radius: 15)
                                .rotationEffect(.degrees(lightningRotation))
                                .opacity(lightningPulse * 0.9)

                            // 第二层：霓虹青-荧光绿弧（90度，快速旋转）
                            Circle()
                                .trim(from: 0, to: 0.25)  // 90度圆弧
                                .stroke(
                                    LinearGradient(
                                        gradient: Gradient(colors: [
                                            Color(red: 0.0, green: 0.961, blue: 1.0).opacity(0.8),      // #00F5FF 霓虹青
                                            Color(red: 0.612, green: 1.0, blue: 0.180).opacity(0.7)     // #9CFF2E 荧光绿
                                        ]),
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    ),
                                    style: StrokeStyle(lineWidth: 8, lineCap: .round)
                                )
                                .blur(radius: 12)
                                .rotationEffect(.degrees(lightningRotation * 1.5 + 120))
                                .opacity(lightningPulse * 0.7)

                            // 第三层：荧光绿装饰弧（60度，反向旋转）
                            Circle()
                                .trim(from: 0, to: 0.16)  // 60度圆弧
                                .stroke(
                                    Color(red: 0.612, green: 1.0, blue: 0.180).opacity(0.6),  // #9CFF2E 荧光绿
                                    style: StrokeStyle(lineWidth: 6, lineCap: .round)
                                )
                                .blur(radius: 10)
                                .rotationEffect(.degrees(-lightningRotation * 0.8 + 240))
                                .opacity(lightningPulse * 0.6)
                        }

                        // 第一小时圈 - 使用动态主题渐变色
                        Circle()
                            .trim(from: 0, to: min(CGFloat(timeElapsed / 3600), 1.0))
                            .stroke(
                                LinearGradient(
                                    gradient: Gradient(colors: currentTheme.circle),
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                style: StrokeStyle(
                                    lineWidth: 20,
                                    lineCap: .round
                                )
                            )
                            .rotationEffect(.degrees(-90))
                            .animation(.linear, value: timeElapsed)
                                     // 第二小时圈（橙色）- 只在超过1小时后显示
                        if timeElapsed > 3600 {
                            Circle()
                                .trim(from: 0, to: min(CGFloat((timeElapsed - 3600) / 3600), 1.0))
                                .stroke(
                                    LinearGradient(
                                        gradient: Gradient(colors: [.orange, .yellow]),
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    style: StrokeStyle(
                                        lineWidth: 14,
                                        lineCap: .round
                                    )
                                )
                                .rotationEffect(.degrees(-90))
                                .animation(.linear, value: timeElapsed)
                                .frame(width: 210, height: 210)
                        }
                                     // 第三小时圈（绿色）- 只在超过2小时后显示
                        if timeElapsed > 7200 {
                            Circle()
                                .trim(from: 0, to: min(CGFloat((timeElapsed - 7200) / 3600), 1.0))
                                .stroke(
                                    LinearGradient(
                                        gradient: Gradient(colors: [.green, .teal]),
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    style: StrokeStyle(
                                        lineWidth: 8,
                                        lineCap: .round
                                    )
                                )
                                .rotationEffect(.degrees(-90))
                                .animation(.linear, value: timeElapsed)
                                .frame(width: 170, height: 170)
                        }
                                     VStack {
                            Text(TimeFormatter.formatTimeInterval(timeElapsed))
                                .font(.system(size: 40, weight: shouldShowKingEffect ? .heavy : .medium, design: .rounded))
                                .foregroundColor(currentTheme.primary)

                            // 状态文本 - 使用动态主题色
                            Text(
                                focusManager.isActive
                                    ? (focusManager.isManuallyPaused ? "practice.paused".localized :
                                       (focusManager.pendingSilenceStart != nil ? "Silent — waiting, not counted".localized :
                                        (focusManager.currentDistraction != nil ? "Distracted".localized : "Focused".localized)))
                                    : "Ready to focus".localized
                            )
                                .font(shouldShowKingEffect ? .system(.headline, design: .default, weight: .heavy) : .headline)
                                .foregroundColor(currentTheme.statusText)
                        }
                    }
                    .frame(width: 250, height: 250)

                    PracticeModePicker()
                        .padding(.horizontal, 24)
                        .frame(maxWidth: 440)

                    MetronomeBar(tint: currentTheme.primary)
                        .padding(.horizontal, 24)
                        .frame(maxWidth: 440)

                    PitchCard(tint: currentTheme.primary, isPracticing: focusManager.isActive)
                        .padding(.horizontal, 24)
                        .frame(maxWidth: 440)

                    // 音频监测显示 - 无背景框
                    if focusManager.isActive {
                        VStack(spacing: 10) {
                            PracticeAudioStatusView(monitor: focusManager.audioMonitor)

                        }
                        .padding()
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 20)
                    }
                             PracticeSessionControls(style: .full)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 20)

                }
                .padding(.vertical)
                .frame(width: geometry.size.width) // 设置固定宽度
            }
            .background(
                ZStack {
                    // 基础背景色
                    currentTheme.light
                        .overlay(currentTheme.primary.opacity(0.1))

                    // 紫色主题的流光效果层（仅在空闲状态且预览/达成大师成就时显示）
                    if shouldShowShimmerEffect {
                        GeometryReader { geo in
                            LinearGradient(
                                gradient: Gradient(colors: [
                                    Color(red: 0.584, green: 0.282, blue: 0.769).opacity(0.5),  // 主紫色
                                    Color(red: 0.745, green: 0.282, blue: 0.816).opacity(0.6),  // 亮紫色
                                    Color(red: 0.459, green: 0.388, blue: 0.878).opacity(0.55), // 蓝紫色
                                    Color(red: 0.878, green: 0.380, blue: 0.757).opacity(0.6),  // 粉紫色
                                    Color(red: 0.584, green: 0.282, blue: 0.769).opacity(0.5),  // 主紫色
                                    Color(red: 0.459, green: 0.388, blue: 0.878).opacity(0.55), // 蓝紫色
                                    Color(red: 0.745, green: 0.282, blue: 0.816).opacity(0.6),  // 亮紫色
                                    Color(red: 0.878, green: 0.380, blue: 0.757).opacity(0.6)   // 粉紫色（循环）
                                ]),
                                startPoint: UnitPoint(x: gradientOffset, y: 0),
                                endPoint: UnitPoint(x: gradientOffset + 0.6, y: 1)
                            )
                            .frame(width: geo.size.width * 5, height: geo.size.height)
                            .offset(x: -geo.size.width * gradientOffset)
                            .blendMode(.normal)
                        }
                    }

                    // 🌌 霓虹王冠主题的赛博效果（三层动画）
                    if shouldShowKingEffect {
                        GeometryReader { geo in
                            ZStack {
                                // 底层：深紫黑渐变基底（从中心到边缘）
                                RadialGradient(
                                    gradient: Gradient(colors: [
                                        Color(red: 0.235, green: 0.110, blue: 0.475).opacity(0.8),  // #3C1C79 深紫中心
                                        Color(red: 0.145, green: 0.075, blue: 0.318).opacity(0.7),  // 中间紫黑
                                        Color(red: 0.063, green: 0.043, blue: 0.157).opacity(0.9),  // #100B28 边缘深黑
                                        Color(red: 0.020, green: 0.015, blue: 0.050).opacity(1.0)   // 最外层纯黑
                                    ]),
                                    center: .center,
                                    startRadius: 50 * pulseScale,
                                    endRadius: 500 * pulseScale
                                )
                                .opacity(1.0)

                                // 中层：霓虹流光（粉-青-绿渐变流动）
                                LinearGradient(
                                    gradient: Gradient(colors: [
                                        Color(red: 1.0, green: 0.235, blue: 0.675).opacity(0.4),    // #FF3CAC 霓虹粉
                                        Color(red: 0.0, green: 0.961, blue: 1.0).opacity(0.5),      // #00F5FF 霓虹青
                                        Color(red: 0.612, green: 1.0, blue: 0.180).opacity(0.45),   // #9CFF2E 荧光绿
                                        Color(red: 1.0, green: 0.235, blue: 0.675).opacity(0.4),    // #FF3CAC 霓虹粉
                                        Color(red: 0.0, green: 0.961, blue: 1.0).opacity(0.5)       // #00F5FF 霓虹青
                                    ]),
                                    startPoint: UnitPoint(x: gradientOffset, y: 0),
                                    endPoint: UnitPoint(x: gradientOffset + 0.5, y: 1)
                                )
                                .frame(width: geo.size.width * 5, height: geo.size.height)
                                .offset(x: -geo.size.width * gradientOffset)
                            }
                            .blendMode(.plusLighter)
                        }
                    }
                }
                .ignoresSafeArea()  // 让背景色延伸到状态栏区域
            )  // 应用主题中等色背景
        }
        .animation(.easeInOut(duration: 0.3), value: currentThemeState)  // 背景色平滑过渡
        .onChange(of: previewTheme) {
            // 主题切换时重启对应的动画
            if shouldShowKingEffect {
                startKingAnimations()
            } else if shouldShowShimmerEffect {
                startGradientAnimation()
            }
        }
        .onChange(of: currentThemeState) {
            // 正常主题切换时也重启对应的动画
            if shouldShowKingEffect {
                startKingAnimations()
            } else if shouldShowShimmerEffect {
                startGradientAnimation()
            }
        }
        .onReceive(timer) { _ in
            guard isVisible else { return }
            // 更新本次会话累积时间和今日专注时间
            updateTodayTotals()
        }
        .onAppear {
            isVisible = true
            // 初始加载本次会话累积时间和今日专注时间
            updateTodayTotals()

            // 启动紫色主题流光动画
            startGradientAnimation()
        }
        .onDisappear { isVisible = false }
        .alert("Microphone Permission Required".localized, isPresented: $showingPermissionAlert) {
            Button("Go to Settings".localized) {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Cancel".localized, role: .cancel) { }
        } message: {
            Text("The music monitoring feature requires microphone permission to work. Please allow microphone access in Settings.".localized)
        }
        // 添加弹出的今日练习会话列表
        .sheet(isPresented: $showTodaySessionsSheet) {
            TodaySessionsView(
                sessions: $todaySessions,
                editingSessionIndex: $editingSessionIndex,
                editPieceName: $editPieceName,
                editImprovements: $editImprovements,
                editNotes: $editNotes,
                updateSessionContent: updateSessionContent
            )
        }
        .onChange(of: scoreLibrary.externalRequestID) { _, _ in
            guard scoreLibrary.handlesExternalFiles(in: externalWindowID) else { return }
            showTodaySessionsSheet = false
            showingPermissionAlert = false
        }
    }
    
    /**
     * @method updateTodayTotals
     * @description 更新本次会话累积时间统计和今日专注时间
     */
    private func updateTodayTotals() {
        // Historical totals change when records change or the calendar rolls
        // over, not on every clock tick. Live session totals remain per-second.
        let today = Calendar.current.startOfDay(for: Date())
        if totalsDay != today {
            totalsDay = today
            focusManager.refreshPracticeStatistics()
        }
        
        // 计算纯专注时间和纯分心时间
        if focusManager.isActive {
            let totals = focusManager.getFullSessionStats()
            currentPureFocusTime = totals.totalFocusTime
            currentDistractionTime = totals.totalDistractionTime
        } else {
            // 没有会话时清零
            currentPureFocusTime = 0
            currentDistractionTime = 0
        }
        // The main clock and progress rings show effective time too, so a
        // pending silence cannot appear to add time or jump backwards later.
        timeElapsed = currentPureFocusTime
    }

    /**
     * @method startGradientAnimation
     * @description 启动紫色主题的流光动画
     */
    private func startGradientAnimation() {
        // 重置位置偏移
        gradientOffset = 0
        // 使用 DispatchQueue 确保动画在下一个渲染周期启动
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            withAnimation(.linear(duration: 10.0).repeatForever(autoreverses: false)) {
                gradientOffset = 1
            }
        }
    }

    /**
     * @method startKingAnimations
     * @description 启动王者红色主题的三层雷霆动画
     */
    private func startKingAnimations() {
        // 底层：径向呼吸（12秒周期，1.0 <-> 1.3）
        pulseScale = 1.0
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            withAnimation(.easeInOut(duration: 12.0).repeatForever(autoreverses: true)) {
                pulseScale = 1.3
            }
        }

        // 中层：对角流光（15秒周期，比紫色更慢）
        gradientOffset = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            withAnimation(.linear(duration: 15.0).repeatForever(autoreverses: false)) {
                gradientOffset = 1
            }
        }

        // 顶层：环形雷电旋转（8秒旋转一圈）
        lightningRotation = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            withAnimation(.linear(duration: 8.0).repeatForever(autoreverses: false)) {
                lightningRotation = 360
            }
        }

        // 环形雷电脉冲（2秒周期，呼吸效果）
        lightningPulse = 0.7
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
                lightningPulse = 1.0
            }
        }
    }

    /**
     * @method triggerRandomLightning
     * @description 触发随机闪电效果
     */
    private func triggerRandomLightning() {
        // 随机延迟 1-2.5 秒（更频繁的闪电效果）
        let delay = Double.random(in: 1.0...2.5)

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            // 只有在仍然显示王者效果时才继续
            guard shouldShowKingEffect else { return }

            // 随机位置
            lightningOffset = CGFloat.random(in: 50...300)

            // 闪电出现（0.1秒）
            withAnimation(.linear(duration: 0.1)) {
                lightningOpacity = 0.8
            }

            // 闪电消失（0.2秒后）
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                withAnimation(.linear(duration: 0.2)) {
                    lightningOpacity = 0.0
                }

                // 递归调用，继续触发下一次闪电
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    triggerRandomLightning()
                }
            }
        }
    }

    /**
     * @method themeColor
     * @description 获取主题对应的按钮颜色
     * @param theme 主题标识
     * @return 主题颜色
     */
    private func themeColor(for theme: String) -> Color {
        switch theme {
        case "blue":
            return Color(red: 0.24, green: 0.48, blue: 0.71)
        case "beige":
            return Color(red: 0.769, green: 0.647, blue: 0.447)
        case "cyan":
            return Color(red: 0.086, green: 0.580, blue: 0.588)
        case "purple":
            return Color(red: 0.584, green: 0.282, blue: 0.769)
        case "red":
            return Color(red: 0.863, green: 0.078, blue: 0.235)
        case "orange":
            return Color(red: 0.976, green: 0.451, blue: 0.086)
        case "green":
            return Color(red: 0.086, green: 0.639, blue: 0.290)
        default:
            return .gray
        }
    }

    /**
     * @method themeLabel
     * @description 获取主题的文字标签
     * @param theme 主题标识
     * @return 主题标签
     */
    private func themeLabel(for theme: String) -> String {
        switch theme {
        case "blue":
            return "蓝色主题 (0-青铜)"
        case "beige":
            return "米色主题 (白银-黄金)"
        case "cyan":
            return "青色主题 (铂金-钻石)"
        case "purple":
            return "紫色主题 (大师+)"
        case "red":
            return "红色主题 (王者)"
        case "orange":
            return "橙色主题 (分心状态)"
        case "green":
            return "绿色主题 (专注练琴)"
        default:
            return "未知主题"
        }
    }

    /**
     * @method showTodayFocusSessions
     * @description 显示今日练习会话的弹窗
     */
    private func showTodayFocusSessions() {
        todaySessions = focusManager.getSessionsForDate(Date()).sorted { $0.startTime > $1.startTime }

        showTodaySessionsSheet = true
    }
    
    /**
     * @method updateSessionContent
     * @description 更新会话的练习内容
     * @param sessionIndex 要更新的会话索引
     */
    private func updateSessionContent(sessionIndex: Int) {
        guard sessionIndex < todaySessions.count else { return }
        
        // 获取当前会话
        var session = todaySessions[sessionIndex]
        
        // 如果没有练习内容对象，创建一个新的
        if session.practiceContent == nil {
            // 正确创建PracticeContent实例
            session.practiceContent = PracticeContent(
                pieceName: editPieceName,
                improvements: editImprovements,
                notes: editNotes
            )
        } else {
            // 更新练习内容
            session.practiceContent?.pieceName = editPieceName
            session.practiceContent?.improvements = editImprovements
            session.practiceContent?.notes = editNotes
        }
        
        // 更新会话在focusManager中
        let index = focusManager.allSessions.firstIndex(where: { $0.id == session.id })
        if let index = index {
            var updatedSessions = focusManager.allSessions
            updatedSessions[index] = session
            // 直接更新FocusManager中的会话数组
            focusManager.allSessions = updatedSessions
            // 由于saveSessions()是私有的，不调用它，而是依靠
            // allSessions的didSet来触发保存操作
        }
        
        // 更新本地数组
        todaySessions[sessionIndex] = session
        
        // 重置编辑状态
        editingSessionIndex = nil
    }
}

/**
 * @struct AIPerformanceAnalysisView
 * @description AI练琴分析结果展示视图
 */
struct AIPerformanceAnalysisView: View {
    @EnvironmentObject var focusManager: FocusManager 
    @State private var nextUpdateCountdown: Int = 300 // 倒计时秒数
    @State private var updateTimer: Timer? = nil // 用于倒计时的定时器
    @State private var showDetails = false
    
    // 获取当前使用的AI模型显示名称
    private var aiModelDisplayName: String {
        // 如果没有配置AI密钥，则返回空字符串
        if focusManager.aiAPIKey.isEmpty {
            return ""
        }
        
        let modelName = focusManager.aiModelName.lowercased()
        
        // 根据模型名称返回对应的显示名称
        if modelName.contains("deepseek") {
            return "DeepSeek AI"
        } else if modelName.contains("doubao") || modelName.contains("豆包") {
            return "豆包"
        } else if modelName.contains("qwen") || modelName.contains("通义") {
            return "通义千问"
        } else if modelName.contains("glm") || modelName.contains("chatglm") {
            return "ChatGLM"
        } else if modelName.contains("telai") || modelName.contains("telechat") {
            return "TeleChat"
        } else if modelName.contains("internlm") {
            return "InternLM"
        } else {
            // 如果无法识别模型，则返回通用名称
            return "AI"
        }
    }
    
    // 标题按钮视图 - 无背景框
    private func titleButton(geometry: GeometryProxy) -> some View {
        Button(action: {
            withAnimation {
                showDetails.toggle()
            }
        }) {
            HStack {
                Text(String(format: "%@ Practice Analysis".localized, aiModelDisplayName))
                    .font(.headline)
                    .foregroundColor(.primary)

                Spacer()

                Image(systemName: showDetails ? "chevron.up" : "chevron.down")
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .frame(width: geometry.size.width - 16)
        }
        .buttonStyle(PlainButtonStyle())
    }
    
    // 消息内容视图 - 无背景框
    private func messageContentView() -> some View {
        Group {
            if let message = focusManager.aiAnalysisResults["message"] as? String {
                // 仅显示AI消息
                Text(message)
                    .font(.body)
                    .multilineTextAlignment(.leading)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                performanceScoreView()
            }
        }
    }
    
    // 演奏评分视图
    private func performanceScoreView() -> some View {
        let performanceScore = focusManager.aiAnalysisResults["performanceScore"] as? Int ?? 0
        return VStack(spacing: 4) {
            Text("演奏评分")
                .font(.subheadline)
                .foregroundColor(.secondary)
             Text("\(performanceScore)/100")
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .foregroundColor(getScoreColor(score: performanceScore))
             // 评分明细
            if let scoreDetail = focusManager.aiAnalysisResults["scoreDetail"] as? [String: [String: Any]] {
                scoreDetailView(scoreDetail: scoreDetail)
            }
        }
    }
    
    // 评分明细视图
    private func scoreDetailView(scoreDetail: [String: [String: Any]]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().padding(.vertical, 4)
             // 专注时间得分
            if let focusTimeDetail = scoreDetail["focusTimeScore"],
               let score = focusTimeDetail["score"] as? Int {
                scoreItemView(
                    title: "专注时间",
                    score: score,
                    explanation: focusTimeDetail["explanation"] as? String ?? ""
                )
            }
             // 练习效率得分
            if let practiceEfficiencyDetail = scoreDetail["practiceEfficiencyScore"],
               let score = practiceEfficiencyDetail["score"] as? Int {
                scoreItemView(
                    title: "练习效率",
                    score: score,
                    explanation: practiceEfficiencyDetail["explanation"] as? String ?? ""
                )
            }
             // 技术进步得分
            if let technicalProgressDetail = scoreDetail["technicalProgressScore"],
               let score = technicalProgressDetail["score"] as? Int {
                scoreItemView(
                    title: "技术进步",
                    score: score,
                    explanation: technicalProgressDetail["explanation"] as? String ?? ""
                )
            }
        }
    }
    
    // 单个评分项目视图
    private func scoreItemView(title: String, score: Int, explanation: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.subheadline)
                     Spacer()
                     Text("\(score)/100")
                    .font(.subheadline)
                    .fontWeight(.bold)
                    .foregroundColor(getScoreColor(score: score))
            }
             Text(explanation)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
             Divider().padding(.vertical, 4)
        }
    }
    
    // 分析指标视图
    private func analysisMetricsView() -> some View {
        HStack(spacing: 10) {
            // 节奏稳定性
            let rhythmScore = focusManager.aiAnalysisResults["rhythmStability"] as? Double ?? 0
            AnalysisMetricView(
                title: "节奏稳定性",
                value: rhythmScore,
                icon: "metronome",
                color: .blue
            )
             // 音高准确性
            let pitchScore = focusManager.aiAnalysisResults["pitchAccuracy"] as? Double ?? 0
            AnalysisMetricView(
                title: "Pitch Accuracy".localized,
                value: pitchScore,
                icon: "music.note",
                color: .green
            )
        }
    }
    
    // 改进建议视图
    private func suggestionsView() -> some View {
        Group {
            if let suggestions = focusManager.aiAnalysisResults["suggestions"] as? [String] {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Suggestions".localized)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                             ForEach(suggestions.indices, id: \.self) { index in
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(index + 1).")
                                .foregroundColor(.secondary)
                                             Text(suggestions[index])
                                .font(.subheadline)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
        }
    }
    
    // 最后更新时间视图
    private func lastUpdateTimeView() -> some View {
        Group {
            if let lastUpdateTime = focusManager.aiAnalysisResults["timestamp"] as? TimeInterval {
                HStack {
                    Spacer()
                    Text("更新于: \(Date(timeIntervalSince1970: lastUpdateTime).formatted(date: .omitted, time: .shortened))")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
    }
    
    // 详情内容视图
    private func detailsContentView(geometry: GeometryProxy) -> some View {
        GeometryReader { _ in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    messageContentView()
                             // 如果没有直接消息，显示分析指标
                    if focusManager.aiAnalysisResults["message"] == nil {
                        analysisMetricsView()
                        suggestionsView()
                    }
                             lastUpdateTimeView()
                }
                .padding()
                .frame(width: geometry.size.width - 16)
            }
            .frame(height: calculateViewHeight())
        }
    }
    
    // 计算视图高度
    private func calculateViewHeight() -> CGFloat {
        // 根据内容决定高度
        if !showDetails {
            return 0
        }
        
        // 如果有AI分析结果，根据内容类型返回不同高度
        if !focusManager.aiAnalysisResults.isEmpty {
            if focusManager.aiAnalysisResults["message"] != nil {
                // 如果是消息格式，给予较小高度
                return 300
            } else {
                // 如果是详细分析格式，给予较大高度
                return 500
            }
        }
        
        return 50 // 默认高度
    }
    
    var body: some View {
        // 只有在API密钥已配置且启用AI分析时才显示
        if !focusManager.aiAPIKey.isEmpty && focusManager.enableAIAnalysis {
            GeometryReader { geometry in
                VStack(spacing: 8) {
                    titleButton(geometry: geometry)
                             if showDetails {
                        detailsContentView(geometry: geometry)
                    }
                }
            }
            .frame(height: calculateViewHeight() + 50) // 50是标题按钮的高度
        } else {
            EmptyView()
        }
    }
    
    // 根据分数获取颜色
    private func getScoreColor(score: Int) -> Color {
        switch score {
        case 90...100: return .green
        case 70..<90: return .blue
        case 50..<70: return .orange
        default: return .red
        }
    }
}

/**
 * @struct AnalysisMetricView
 * @description 显示单个分析指标的视图组件
 */
struct AnalysisMetricView: View {
    var title: String
    var value: Double
    var icon: String
    var color: Color
    
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(color)
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
             Text("\(Int(value * 100))%")
                .font(.title2)
                .fontWeight(.bold)
             // 进度条
            ZStack(alignment: .leading) {
                Rectangle()
                    .foregroundColor(Color.secondary.opacity(0.2))
                    .frame(height: 4)
                    .cornerRadius(2)
                     Rectangle()
                    .foregroundColor(color)
                    .frame(width: UIScreen.main.bounds.width * 0.25 * CGFloat(value), height: 4)
                    .cornerRadius(2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
    }
}

/**
 * @struct AudioMetricView
 * @description 显示音频质量指标的视图组件
 */
struct AudioMetricView: View {
    var title: String
    var value: CGFloat
    var icon: String
    var color: Color
    var width: CGFloat
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(color)
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
                     Spacer()
                     Text("\(Int(value * 100))%")
                    .font(.caption)
                    .fontWeight(.bold)
            }
             // 进度条
            ZStack(alignment: .leading) {
                Rectangle()
                    .foregroundColor(Color.secondary.opacity(0.2))
                    .frame(height: 4)
                    .cornerRadius(2)
                     Rectangle()
                    .foregroundColor(color)
                    .frame(width: width * value, height: 4)
                    .cornerRadius(2)
            }
        }
    }
}

/**
 * @struct DistractionListView
 * @description 分心详情列表视图
 */
struct DistractionListView: View {
    @EnvironmentObject var focusManager: FocusManager
    @State private var showAll = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Text("Distraction Records".localized)
                    .font(.headline)
                    .foregroundColor(.primary)
                     Spacer()
                     Button(action: {
                    withAnimation {
                        showAll.toggle()
                    }
                }) {
                    Text(showAll ? "Show Less".localized : "Show All".localized)
                        .font(.caption)
                        .foregroundColor(.blue)
                }
            }
             if let session = focusManager.currentSession, !session.distractions.isEmpty {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(
                            showAll ? session.distractions : Array(session.distractions.prefix(3)),
                            id: \.id
                        ) { distraction in
                            DistractionRowView(distraction: distraction)
                        }
                    }
                }
                .frame(height: showAll ? 300 : 150)
            } else {
                Text("Great! No distractions recorded".localized)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
}

/**
 * @struct DistractionRowView
 * @description 单条分心记录视图
 */
struct DistractionRowView: View {
    var distraction: Distraction
    
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundColor(.orange)
                Text(distraction.description.localized)
                    .font(.subheadline)
                Spacer()
                Text(TimeFormatter.formatTimeInterval(distraction.duration))
                    .font(.caption)
                    .foregroundColor(.red)
            }
             Text("\(TimeFormatter.formatTime(distraction.startTime)) - \(distraction.endTime != nil ? TimeFormatter.formatTime(distraction.endTime!) : "In Progress".localized)")
                .font(.caption2)
                .foregroundColor(.secondary)
             Divider()
                .padding(.vertical, 2)
        }
    }
}

/**
 * @struct PracticeContentInputView
 * @description 练习内容输入视图
 */
struct PracticeContentInputView: View {
    @Binding var pieceName: String
    @Binding var improvements: String
    @Binding var notes: String
    var onSave: () -> Void
    var onCancel: () -> Void
    @Environment(\.presentationMode) var presentationMode
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Practice Piece".localized)) {
                    TextField("Enter piece name".localized, text: $pieceName)
                }

                Section(header: Text("Improvements This Session".localized)) {
                    TextEditor(text: $improvements)
                        .frame(minHeight: 100)
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                        )
                        .padding(.vertical, 4)
                }

                Section(header: Text("Other Notes".localized)) {
                    TextEditor(text: $notes)
                        .frame(minHeight: 60)
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                        )
                        .padding(.vertical, 4)
                }
            }
            .navigationTitle("Practice Record".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Skip".localized) {
                        onCancel()
                        presentationMode.wrappedValue.dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save".localized) {
                        onSave()
                        presentationMode.wrappedValue.dismiss()
                    }
                    .disabled(pieceName.isEmpty)
                }
            }
        }
    }
}

/**
 * @struct TodaySessionsView
 * @description 今日练习会话列表视图
 */
struct TodaySessionsView: View {
    @Binding var sessions: [FocusSession]
    @Binding var editingSessionIndex: Int?
    @Binding var editPieceName: String
    @Binding var editImprovements: String
    @Binding var editNotes: String
    
    var updateSessionContent: (Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var focusManager: FocusManager
    
    // 同步会话到FocusManager并保存
    private func synchronizeSessionsWithFocusManager() {
        let todayIDs = Set(focusManager.getSessionsForDate(Date()).map(\.id))
        let otherSessions = focusManager.allSessions.filter { !todayIDs.contains($0.id) }

        // 合并今日会话和其他日期会话
        var updatedSessions = otherSessions
        updatedSessions.append(contentsOf: sessions)
        
        // 更新FocusManager中的所有会话
        focusManager.allSessions = updatedSessions
    }
    
    var body: some View {
        NavigationView {
            List {
                if sessions.isEmpty {
                    Text("No practice sessions today".localized)
                        .foregroundColor(.secondary)
                        .padding()
                        .frame(maxWidth: .infinity)
                } else {
                    ForEach(sessions.indices, id: \.self) { index in
                        SessionItemView(
                            session: sessions[index],
                            isEditing: Binding(
                                get: { editingSessionIndex == index },
                                set: { isEditing in
                                    if isEditing {
                                        // 设置当前编辑的会话
                                        editingSessionIndex = index
                                        editPieceName = sessions[index].practiceContent?.pieceName ?? ""
                                        editImprovements = sessions[index].practiceContent?.improvements ?? ""
                                        editNotes = sessions[index].practiceContent?.notes ?? ""
                                    } else {
                                        // 取消编辑
                                        editingSessionIndex = nil
                                    }
                                }
                            ),
                            pieceName: $editPieceName,
                            improvements: $editImprovements,
                            notes: $editNotes,
                            saveChanges: {
                                updateSessionContent(index)
                            }
                        )
                    }
                    .onDelete { indexSet in
                        // 删除选中的练习记录
                        sessions.remove(atOffsets: indexSet)
                                     // 将更新后的会话同步到FocusManager并保存
                        synchronizeSessionsWithFocusManager()
                    }
                }
            }
            .navigationTitle("Today's Practice Details".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done".localized) {
                        // 保存更改并退出
                        synchronizeSessionsWithFocusManager()
                        dismiss()
                    }
                }
                     ToolbarItem(placement: .navigationBarLeading) {
                    EditButton()
                }
            }
        }
    }
}

/**
 * @struct SessionItemView
 * @description 单个会话项视图
 */
struct SessionItemView: View {
    let session: FocusSession
    @Binding var isEditing: Bool
    @Binding var pieceName: String
    @Binding var improvements: String
    @Binding var notes: String
    
    var saveChanges: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 会话时间信息
            HStack {
                Text("\(TimeFormatter.formatTime(session.startTime)) - \(session.endTime != nil ? TimeFormatter.formatTime(session.endTime!) : "In Progress".localized)")
                    .font(.headline)
                     Spacer()
                     // 编辑按钮
                if !isEditing {
                    Button(action: { isEditing = true }) {
                        Image(systemName: "pencil")
                            .foregroundColor(.blue)
                    }
                }
            }
             // 会话时长信息
            HStack {
                Text("\("Focus:".localized) \(TimeFormatter.formatTimeInterval(session.totalFocusTime))")
                    .foregroundColor(.green)

                Spacer()

                Text("\("Distraction:".localized) \(TimeFormatter.formatTimeInterval(session.distractionTime))")
                    .foregroundColor(.red)
            }
            .font(.subheadline)
             // 练习内容展示或编辑
            if isEditing {
                // 编辑模式
                VStack(alignment: .leading, spacing: 8) {
                    Text("Piece:".localized)
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    TextField("Enter practice piece".localized, text: $pieceName)
                        .textFieldStyle(RoundedBorderTextFieldStyle())

                    Text("Improvements:".localized)
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    TextEditor(text: $improvements)
                        .frame(height: 60)
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                        )

                    Text("Notes:".localized)
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    TextEditor(text: $notes)
                        .frame(height: 60)
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                        )

                    HStack {
                        Button("Cancel".localized) {
                            isEditing = false
                        }
                        .buttonStyle(.bordered)

                        Spacer()

                        Button("Save".localized) {
                            saveChanges()
                            isEditing = false
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(.top, 5)
                }
                .padding(.vertical, 5)
            } else {
                // 显示模式
                if let practiceContent = session.practiceContent,
                   !practiceContent.pieceName.isEmpty ||
                   !practiceContent.improvements.isEmpty ||
                   !practiceContent.notes.isEmpty {

                    VStack(alignment: .leading, spacing: 6) {
                        if !practiceContent.pieceName.isEmpty {
                            HStack {
                                Image(systemName: "music.note")
                                    .foregroundColor(.blue)
                                Text("\("Piece:".localized) \(practiceContent.pieceName)")
                                    .font(.subheadline)
                            }
                        }

                        if !practiceContent.improvements.isEmpty {
                            Text("\("Improvements:".localized) \(practiceContent.improvements)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                        }

                        if !practiceContent.notes.isEmpty {
                            Text("\("Notes:".localized) \(practiceContent.notes)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.vertical, 5)
                } else {
                    Button(action: { isEditing = true }) {
                        Label("Add Practice Content".localized, systemImage: "plus.circle")
                            .font(.subheadline)
                            .foregroundColor(.blue)
                    }
                    .padding(.vertical, 5)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(10)
    }
}
