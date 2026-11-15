//
//  FocusManager.swift
//  MusicFocus
//
//  Created by 姜伯龙 on 2025/3/7.
//

import Foundation
import UIKit
import Combine
import CryptoKit
import UserNotifications
import SwiftKeychainWrapper
// 添加Utils引用，确保TimeFormatter可用

/**
 * @class FocusSession
 * @description 表示一次专注练琴的会话
 */
struct FocusSession: Identifiable, Codable {
    var id = UUID()
    var startTime: Date
    var endTime: Date?
    var distractions: [Distraction]
    var practiceContent: PracticeContent? // 添加练习内容记录
    var practiceMode: PracticeMode? = nil // Older saved sessions have no mode.
    var silenceConfirmationDelay: TimeInterval? = nil
    // Short silent gaps stay inside the segment, but never count as practice.
    // Optional for compatibility with history saved before this setting existed.
    var unsegmentedSilences: [Distraction]? = nil
    var scoreIntervals: [ScorePracticeInterval]? = nil

    // 心率数据（v2.12，功能已移除）：字段保留，读写旧记录时原样保存，不丢数据
    var heartRateDataJSON: String? // JSON编码的心率数组
    var averageHeartRate: Double = 0.0
    var maxHeartRate: Double = 0.0
    var minHeartRate: Double = 0.0
    var effortScore: Double = 0.0
    var intensity: String = "none" // none/relaxed/light/moderate/vigorous/extreme

    var totalFocusTime: TimeInterval {
        PracticeTimeAccounting.totals(self).focus
    }
    var distractionTime: TimeInterval {
        PracticeTimeAccounting.totals(self).pause
    }
}

/**
 * @class PracticeContent
 * @description 表示练习的具体内容
 */
struct PracticeContent: Codable {
    var pieceName: String // 练习曲目名称
    var improvements: String // 本次改进内容
    var notes: String // 其他备注
}

/**
 * @class Distraction
 * @description 表示一次分心的记录
 */
struct Distraction: Identifiable, Codable {
    var id = UUID()
    var startTime: Date
    var endTime: Date?
    var description: String
    var duration: TimeInterval {
        guard let endTime = endTime else {
            return Date().timeIntervalSince(startTime)
        }
        return endTime.timeIntervalSince(startTime)
    }
}

/**
 * @enum DistractionType
 * @description 分心类型枚举
 */
enum DistractionType: String, Codable {
    case appSwitch = "离开音乐专注应用"
    case silence = "练琴中断(分心超过10秒)"
    case manual = "手动结束"
    case other = "其他原因"
}

/**
 * @enum InstrumentType
 * @description 乐器类型枚举
 */
enum InstrumentType: String, Codable, CaseIterable {
    case piano = "钢琴"
    case guitar = "吉他"
    case violin = "小提琴"
    case flute = "长笛"
    case saxophone = "萨克斯"
    case trumpet = "小号"
    case accordion = "手风琴"
    case ukulele = "尤克里里"
    case erhu = "二胡"
    case guzheng = "古筝"
    case drums = "打击乐"
    case voice = "声乐"
    case custom = "自定义"
    
    var recommendedThreshold: Float {
        switch self {
        case .piano: return -40.0
        case .guitar: return -42.0
        case .violin: return -45.0
        case .flute: return -40.0
        case .saxophone: return -36.0
        case .trumpet: return -34.0
        case .accordion: return -40.0
        case .ukulele: return -45.0
        case .erhu: return -44.0
        case .guzheng: return -40.0
        case .drums: return -32.0  // 提高打击乐的检测阈值
        case .voice: return -38.0
        case .custom: return -42.0
        }
    }
    
    var recommendedDistance: String {
        switch self {
        case .piano: return "将设备放置在钢琴旁约50厘米处"
        case .guitar: return "将设备放置在吉他前方约30-50厘米处"
        case .violin: return "将设备放置在小提琴侧前方30厘米处"
        case .flute: return "将设备放置在长笛侧前方30-50厘米处"
        case .saxophone: return "将设备放置在萨克斯侧方50-70厘米处"
        case .trumpet: return "将设备放置在小号前方70-100厘米处"
        case .accordion: return "将设备放置在手风琴侧前方40-60厘米处"
        case .ukulele: return "将设备放置在尤克里里前方20-30厘米处"
        case .erhu: return "将设备放置在二胡侧前方30-40厘米处"
        case .guzheng: return "将设备放置在古筝侧方约50厘米处"
        case .drums: return "将设备放置在打击乐器外侧1-2米处"
        case .voice: return "将设备放置在演唱者前方30-50厘米处"
        case .custom: return "根据乐器音量调整设备距离，音量越大距离越远"
        }
    }
}

/**
 * @struct Message
 * @description 表示一条消息记录
 */
struct Message: Identifiable, Equatable, Codable {
    var id = UUID()
    var content: String
    var isFromUser: Bool
    var timestamp: Date = Date()
    
    static func == (lhs: Message, rhs: Message) -> Bool {
        return lhs.id == rhs.id
    }
}

/**
 * @struct TeacherNote
 * @description 表示练琴笔记
 */
struct TeacherNote: Identifiable, Codable {
    var id = UUID()
    var title: String
    var content: String
    var date: Date
    var importance: Int
    var isCompleted: Bool = false
    var hasMedia: Bool = false
    var mediaType: MediaType = .audio
    var mediaURL: String = ""
    var transcription: String = ""
    var keyPoints: [String] = []
    var editHistory: [EditRecord] = []  // 添加编辑历史记录
    var metadata: [String: String]? = nil  // 添加元数据字段，用于存储其他信息
    var aiAnalysisResult: String = ""  // 添加AI分析结果字段
    var isAnalyzing: Bool = false  // 是否正在分析中
    var autoRefreshAnalysis: Bool = false  // 是否自动刷新分析
    var hasScoreFiles: Bool = false  // 是否有乐谱文件
    var scoreFiles: [ScoreFile] = []  // 乐谱文件列表
    
    enum MediaType: String, Codable {
        case audio
        case video
        case image
        case pdf
    }
    
    /**
     * @struct ScoreFile
     * @description 表示一个乐谱文件
     */
    struct ScoreFile: Identifiable, Codable {
        var id = UUID()
        var fileName: String
        var fileURL: String
        var fileType: MediaType
        var uploadDate: Date
        var description: String = ""
    }
    
    /**
     * @struct EditRecord
     * @description 表示一次编辑记录
     */
    struct EditRecord: Codable {
        var date: Date
        var content: String
        var changes: String  // 描述这次编辑的主要变化
    }
}

/**
 * @struct Conversation
 * @description 表示一个完整的对话
 */
struct Conversation: Identifiable, Codable {
    var id = UUID()
    var title: String
    var messages: [Message]
    var createdAt: Date
    var updatedAt: Date
    
    init(title: String = "新对话", messages: [Message] = [], createdAt: Date = Date()) {
        self.id = UUID()
        self.title = title
        self.messages = messages
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }
    
    // 根据对话内容自动生成标题
    mutating func generateTitle() {
        if let firstUserMessage = messages.first(where: { $0.isFromUser }) {
            // 从第一条用户消息中提取标题（取前15个字符）
            let content = firstUserMessage.content
            let endIndex = content.index(content.startIndex, offsetBy: min(15, content.count))
            let titlePrefix = String(content[..<endIndex])
            self.title = titlePrefix + (content.count > 15 ? "..." : "")
        } else {
            self.title = "新对话"
        }
    }
}

/**
 * @struct UserAccount
 * @description 表示用户账户信息
 */
struct UserAccount: Identifiable, Codable {
    var id = UUID()
    var username: String
    var password: String
    var email: String?
    var createdAt: Date
    var lastLogin: Date
    
    init(username: String, password: String, email: String? = nil) {
        self.id = UUID()
        self.username = username
        self.password = password
        self.email = email
        self.createdAt = Date()
        self.lastLogin = Date()
    }
}

/**
 * @class FocusManager
 * @description 管理专注力状态和会话
 */
class FocusManager: ObservableObject {
    private var scoreTimeline = ScoreContextTimeline()

    /// Attach visible score context without changing detection, pauses, or session lifetime.
    func setScoreContext(_ context: ScorePracticeContext?, at date: Date = Date()) {
        if let interval = scoreTimeline.change(to: context, at: date, sessionStart: currentSession?.startTime) {
            appendScoreInterval(interval)
        }
    }

    private func appendScoreInterval(_ interval: ScorePracticeInterval) {
        guard var session = currentSession else { return }
        var intervals = session.scoreIntervals ?? []
        intervals.append(interval)
        session.scoreIntervals = intervals
        currentSession = session
    }

    @Published var currentSession: FocusSession?
    @Published var isActive: Bool = false
    @Published private(set) var isManuallyPaused = false
    @Published var currentDistraction: Distraction?
    @Published private(set) var pendingSilenceStart: Date?
    @Published var allSessions: [FocusSession] = [] {
        didSet {
            scoreHistoryRevision += 1
            guard historyLoaded else { return }
            historyReadFailed = false
            refreshPracticeStatistics()
            saveSessions()
        }
    }
    @Published private(set) var scoreHistoryRevision = 0
    let scoreSummaryCache = ScorePracticeSummaryCache()
    @Published private(set) var practiceStatistics = PracticeStatistics()
    private let historyDefaults: UserDefaults
    private let settingsDefaults: UserDefaults
    private let statisticsCalendarOverride: Calendar?
    private let statisticsClock: () -> Date
    private var historyLoaded = false
    private var historyReadFailed = false
    
    // 音频监测器
    let audioMonitor = AudioMonitor()
    @Published var enableAudioMonitoring: Bool = true
    var decibels: Float { audioMonitor.decibels }

    // 音频监测设置
    @Published var musicThreshold: Float = -42.0 // 音乐阈值（默认-42dB，减少语音误判）
    @Published var selectedInstrument: InstrumentType = .custom // 选择的乐器类型
    @Published var showExperimentalMode: Bool = false // 是否显示实验模式按钮（默认隐藏）
    @Published private(set) var practiceMode: PracticeMode = .focusedInstrument
    @Published private(set) var silenceConfirmationDelay = SilenceConfirmationSettings.defaultDelay

    func selectSilenceConfirmationDelay(_ delay: TimeInterval) {
        guard !isActive else { return }
        silenceConfirmationDelay = SilenceConfirmationSettings.normalized(delay)
        audioMonitor.updateSilenceConfirmationDelay(silenceConfirmationDelay)
        settingsDefaults.set(silenceConfirmationDelay, forKey: SilenceConfirmationSettings.storageKey)
    }

    func selectPracticeMode(_ mode: PracticeMode) {
        guard !isActive else { return }
        practiceMode = mode
        audioMonitor.updatePracticeMode(mode)
        UserDefaults.standard.set(mode.rawValue, forKey: "practiceMode")
    }

    // 六特征权重（默认值对应当前优化版本）
    @Published var pitchWeight: Float = 0.30        // Pitch Clarity 音高清晰度
    @Published var stabilityWeight: Float = 0.14    // Spectral Stability 频谱稳定性
    @Published var harmonicWeight: Float = 0.38     // Harmonic Ratio 谐波比
    @Published var flatnessWeight: Float = 0.00     // Spectral Flatness 频谱平坦度（已移除）
    @Published var lowFreqWeight: Float = 0.11      // Low Frequency Energy 低频能量
    @Published var rhythmicWeight: Float = 0.07     // Rhythmic Stability 节奏稳定性

    // 密码保护
    @Published var isPasswordProtected: Bool = false
    private var passwordHash: String = ""
    
    // 锁屏通知相关设置
    @Published var enableLockScreenDisplay: Bool = false // 默认关闭锁屏通知
    @Published var enableNotifications: Bool = true // 默认开启普通通知
    private var lockScreenNotificationTimer: Timer? // 锁屏通知定时器
    
    // 屏幕显示相关设置
    @Published var enableKeepScreenOn: Bool = true
    
    // AI is retired from this release. Legacy settings and saved conversations
    // remain on disk; no old preference may re-enable requests or mock scoring.
    static let aiFeaturesAvailable = false
    var isAIAnalysisEnabled: Bool { Self.aiFeaturesAvailable && enableAIAnalysis }

    // AI分析相关
    @Published var enableAIAnalysis: Bool = false
    @Published var aiAPIKey: String = ""
    @Published var aiAPIEndpoint: String = "https://api.deepseek.com"
    @Published var aiModelName: String = "deepseek-chat"
    
    private var aiAnalysisTimer: Timer?
    @Published var aiAnalysisResults: [String: Any] = [:]
    
    // AI对话相关
    @Published var conversationHistory: [Message] = []
    @Published var savedConversations: [Conversation] = []
    @Published var currentConversation: Conversation = Conversation()
    
    private var cancellables = Set<AnyCancellable>()
    private let sessionsKey = "focusSessions"
    private let settingsKey = "focusSettings"
    private let conversationsKey = "aiConversations"
    
    // 教师笔记/课堂要求
    @Published var teacherNotes: [TeacherNote] = []
    private let teacherNotesKey = "com.musicfocus.teachernotes"
    
    // 新增：后台模式设置
    @Published var enableBackgroundMode: Bool = false // 新增：后台模式开关，默认关闭
    
    // 用户账户相关属性
    @Published var currentAccount: UserAccount?
    private let userAccountKey = "com.musicfocus.useraccount"
    
    @Published private(set) var badgeManager: BadgeManager
    
    // 添加认证相关属性
    @Published var currentUser: User?
    private let tokenKey = "authToken"
    private let userKey = "currentUser"
    
    /**
     * @Published teacherNotesAnalyzing
     * @description 跟踪正在进行AI分析的教师笔记ID集合
     */
    @Published var teacherNotesAnalyzing: Set<UUID> = []
    
    /**
     * @Published enableAutoRefreshAnalysis
     * @description 是否启用自动后台刷新分析
     */
    @Published var enableAutoRefreshAnalysis: Bool = true
    
    init(historyDefaults: UserDefaults = .standard, settingsDefaults: UserDefaults = .standard, calendar: Calendar? = nil,
         now: @escaping () -> Date = Date.init) {
        self.historyDefaults = historyDefaults
        self.settingsDefaults = settingsDefaults
        self.statisticsCalendarOverride = calendar
        self.statisticsClock = now
        self.badgeManager = BadgeManager(defaults: historyDefaults)
        // 从UserDefaults加载设置
        loadSettings()
        
        // 从本地存储加载之前保存的会话
        loadSessions()
        historyLoaded = true
        refreshPracticeStatistics()
        for name in [NSNotification.Name.NSCalendarDayChanged,
                     NSNotification.Name.NSSystemTimeZoneDidChange,
                     UIApplication.significantTimeChangeNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(refreshPracticeStatistics),
                                                   name: name, object: nil)
        }
        
        // 设置观察应用状态的通知
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppStateChange),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppStateChange),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
        
        // Meter values are observed by the small audio panel. Forwarding them
        // here invalidates every tab and queues redundant main-run-loop work.
            
        // 设置音频中断回调
        audioMonitor.onMusicInterrupted = { [weak self] in
            self?.handleMusicInterruption()
        }
        
        // 设置音频恢复回调
        audioMonitor.onMusicResumed = { [weak self] in
            self?.handleMusicResumption()
        }
        audioMonitor.onSilencePending = { [weak self] date in
            guard let self, self.isActive, !self.isManuallyPaused, !self.isReviewingVoiceNote, self.currentDistraction == nil,
                  self.currentSession != nil, self.pendingSilenceStart == nil else { return }
            self.pendingSilenceStart = date
        }
        audioMonitor.onSilenceResumed = { [weak self] date in
            self?.finishPendingSilence(at: date)
        }
        
        // 监听阈值变化
        $musicThreshold
            .sink { [weak self] newValue in
                self?.saveSettings()
            }
            .store(in: &cancellables)
            
        // Legacy feature weights remain stored for compatibility; practice detection
        // now uses the shared on-device sound classifier.

        // 请求通知权限
        requestNotificationPermission()
        
        // 加载AI分析设置
        enableAIAnalysis = UserDefaults.standard.bool(forKey: "\(settingsKey).enableAIAnalysis")
        aiAPIKey = UserDefaults.standard.string(forKey: "\(settingsKey).aiAPIKey") ?? ""
        aiAPIEndpoint = UserDefaults.standard.string(forKey: "\(settingsKey).aiAPIEndpoint") ?? "https://api.deepseek.com"
        aiModelName = UserDefaults.standard.string(forKey: "\(settingsKey).aiModelName") ?? "deepseek-chat"
        
        // 加载历史对话记录
        loadConversations()
        
        // 加载教师笔记
        loadTeacherNotes()
        
        // 添加musicConfirmed和musicStopped通知监听
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMusicConfirmed),
            name: .musicConfirmed,
            object: audioMonitor
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMusicStopped),
            name: .musicStopped,
            object: audioMonitor
        )

        // 加载用户账户信息
        loadUserAccount()
        
        // 从 UserDefaults 加载已保存的用户信息
        if let userData = UserDefaults.standard.data(forKey: userKey),
           let user = try? JSONDecoder().decode(User.self, from: userData) {
            self.currentUser = user
        }
    }
    
    /**
     * @method startSession
     * @description 开始一个新的专注会话
     */
    func startSession() {
        // 如果已经有活跃会话，先结束它
        if isActive {
            endSession()
        }

        // 创建新会话
        currentSession = FocusSession(startTime: Date(), distractions: [], practiceMode: practiceMode)
        scoreTimeline.beginSession(at: currentSession!.startTime)
        currentSession?.silenceConfirmationDelay = silenceConfirmationDelay
        pendingSilenceStart = nil
        audioMonitor.updatePracticeMode(practiceMode)
        audioMonitor.updateSilenceConfirmationDelay(silenceConfirmationDelay)
        isManuallyPaused = false
        isActive = true
        print("开始专注会话")

        // 启用音频监控和常亮屏幕功能
        enableAudioMonitoring = true
        // Permission/setup failures must never be counted as confirmed practice.
        startDistraction(description: "未检测到练习声音")
        audioMonitor.requestPermission { [weak self] granted in
            guard let self, self.isActive else { return }
            if granted {
                self.audioMonitor.startMonitoring()
            } else {
                self.audioMonitor.showPermissionDenied()
            }
        }
        UIApplication.shared.isIdleTimerDisabled = true

        // 保存设置
        saveSettings()
    }
    
    /**
     * @method endSession
     * @description 结束当前专注会话
     * @param practiceContent 可选的练习内容记录
     */
    func endSession(practiceContent: PracticeContent? = nil) {
        // 确保有一个活跃的会话
        guard currentSession != nil, isActive else {
            return
        }

        let now = Date()
        if let interval = scoreTimeline.finish(at: now, sessionStart: currentSession?.startTime) {
            appendScoreInterval(interval)
        }
        finishPendingSilence(at: now)
        let session = currentSession!
        
        // 如果有正在记录的分心，结束它
        if let distraction = currentDistraction {
            // 创建一个分心记录副本并设置结束时间
            var updatedDistraction = distraction
            updatedDistraction.endTime = now
            
            // 创建会话的更新副本
            var updatedSession = session
            updatedSession.distractions.append(updatedDistraction)
            
            // 更新会话
            currentSession = updatedSession
            currentDistraction = nil
        }
        
        // 结束会话
        var finalSession = currentSession!
        finalSession.endTime = now
        
        // 添加练习内容记录
        if let content = practiceContent {
            finalSession.practiceContent = content
        }
        
        allSessions.append(finalSession)
        
        // 重置状态
        currentSession = nil
        isActive = false
        isManuallyPaused = false
        
        // 取消常亮屏幕
        UIApplication.shared.isIdleTimerDisabled = false
        
        // 停止音频监控
        audioMonitor.stopMonitoring()

        // 停止AI分析
        stopAIAnalysis()


        print("结束专注会话")
    }
    
    /**
     * @method generatePracticeReport
     * @description 为结束的练习会话生成练琴报告
     * @param session 已结束的练习会话
     */
    private func generatePracticeReport(for session: FocusSession) {
        guard isAIAnalysisEnabled else { return }
        // 获取练琴数据上下文
        let reportContext = generateSessionReportContext(for: session)
        
        // 在对话框中添加消息，提示正在生成报告
        addMessageToHistory(content: "您的练习会话已结束，正在为您生成练琴报告...", isFromUser: false)
        
        // 构建提示词
        let prompt = """
        作为音乐练习助手，请根据以下练习数据生成一份简洁的练习报告和专业建议。只关注最重要的几点，不要过长或重复内容。
        
        练习数据：
        \(reportContext)
        
        请生成：
        1. 简短的练习数据总结(50字以内)
        2. 练习质量评估(50字以内)
        3. 2-3条针对性的专业建议(每条40字以内，不要推荐番茄工作法)
        
        请直接给出内容，不要包含标题如"练习数据总结"等。
        """
        
        // 发送API请求
        sendReportGenerationRequest(prompt: prompt) { [weak self] response in
            // 将生成的报告添加到对话历史
            self?.addMessageToHistory(content: response, isFromUser: false)
        }
    }
    
    /**
     * @method generateSessionReportContext
     * @description 为特定会话生成练习数据上下文
     * @param session 练习会话
     * @return 包含练习数据的字符串
     */
    private func generateSessionReportContext(for session: FocusSession) -> String {
        var context = ""
        
        // 添加会话信息
        guard let sessionEndTime = session.endTime else {
            return "无法生成报告：会话结束时间缺失"
        }
        
        let duration = sessionEndTime.timeIntervalSince(session.startTime)
        context += """
        本次练习会话信息:
        - 开始时间: \(session.startTime)
        - 结束时间: \(sessionEndTime)
        - 练习时长: \(TimeFormatter.formatTimeInterval(duration))
        - 分心次数: \(session.distractions.count)
        - 总分心时间: \(TimeFormatter.formatTimeInterval(session.distractions.reduce(0) { $0 + $1.duration }))
        
        """
        
        // 计算专注度百分比
        let focusPercentage = (duration - session.distractionTime) / duration * 100
        context += "- 专注度: \(String(format: "%.1f", focusPercentage))%\n"
        
        // 添加分心原因分析
        if !session.distractions.isEmpty {
            context += "- 分心原因统计: "
            var distractionCauses: [String: Int] = [:]
            
            for distraction in session.distractions {
                distractionCauses[distraction.description, default: 0] += 1
            }
            
            let sortedCauses = distractionCauses.sorted { $0.value > $1.value }
            context += sortedCauses.map { "\($0.key)(\($0.value)次)" }.joined(separator: ", ") + "\n"
        }
        
        // 添加乐器信息
        context += "\n- 练习乐器: \(selectedInstrument.rawValue)\n"
        
        // 添加教师要求/课堂笔记
        if !teacherNotes.isEmpty {
            context += "\n练琴笔记:\n"
            
            // 按重要性排序，未完成的排在前面
            let sortedNotes = teacherNotes.sorted {
                if $0.isCompleted != $1.isCompleted {
                    return !$0.isCompleted // 未完成的优先
                }
                return $0.importance > $1.importance // 然后按重要性
            }
            
            // 显示最近的5条记录
            for note in sortedNotes.prefix(5) {
                let importanceMarker = String(repeating: "★", count: note.importance)
                let statusMarker = note.isCompleted ? "[已完成]" : "[待练习]"
                context += "- \(importanceMarker) \(note.title) \(statusMarker): \(note.content)\n"
            }
        }
        
        // 加入历史统计和进步情况
        context += "\n历史对比:\n"
        
        // 计算过去5次练习的平均专注度
        let recentSessions = Array(allSessions.sorted { $0.startTime > $1.startTime }.prefix(6).dropFirst())
        if !recentSessions.isEmpty {
            let avgFocusTime = recentSessions.reduce(0.0) { (sum, session) -> TimeInterval in
                guard let endTime = session.endTime else {
                    return sum
                }
                return sum + (endTime.timeIntervalSince(session.startTime) - session.distractionTime)
            } / Double(recentSessions.count)
            
            let avgTotalTime = recentSessions.reduce(0.0) { (sum, session) -> TimeInterval in
                guard let endTime = session.endTime else {
                    return sum
                }
                return sum + endTime.timeIntervalSince(session.startTime)
            } / Double(recentSessions.count)
            
            let avgFocusPercentage = avgFocusTime / avgTotalTime * 100
            
            // 比较当前专注度与平均专注度
            let focusDiff = focusPercentage - avgFocusPercentage
            
            context += "- 过去5次练习平均专注度: \(String(format: "%.1f", avgFocusPercentage))%\n"
            
            if focusDiff > 5 {
                context += "- 相比往常: 专注度显著提高 (+\(String(format: "%.1f", focusDiff))%)\n"
            } else if focusDiff < -5 {
                context += "- 相比往常: 专注度明显下降 (\(String(format: "%.1f", focusDiff))%)\n"
            } else {
                context += "- 相比往常: 专注度保持稳定\n"
            }
        }
        
        // 添加AI分析结果（如果有）
        if !aiAnalysisResults.isEmpty {
            context += "\nAI分析结果:\n"
            
            if let performanceScore = aiAnalysisResults["performanceScore"] as? Int {
                context += "- 练习质量评分: \(performanceScore)/10\n"
            }
            
            // 添加速度分析
            if let tempoAnalysis = aiAnalysisResults["tempoAnalysis"] as? [String: Any],
               let description = tempoAnalysis["description"] as? String {
                context += "- 速度分析: \(description)\n"
            }
            
            // 添加强弱对比分析
            if let dynamicsAnalysis = aiAnalysisResults["dynamicsAnalysis"] as? [String: Any],
               let description = dynamicsAnalysis["description"] as? String {
                context += "- 强弱对比: \(description)\n"
            }
        }
        
        return context
    }
    
    /**
     * @method sendReportGenerationRequest
     * @description 发送报告生成请求到AI API
     * @param prompt 提示词
     * @param completion 完成回调
     */
    private func sendReportGenerationRequest(prompt: String, completion: @escaping (String) -> Void) {
        guard isAIAnalysisEnabled else { completion("AI 功能暂未开放"); return }
        // 检查配置
        guard !aiAPIKey.isEmpty, !aiModelName.isEmpty else {
            completion("无法生成报告：请在设置中配置AI API密钥和模型名称。")
            return
        }
        
        // API端点
        guard let url = URL(string: "\(aiAPIEndpoint.trimmingCharacters(in: .whitespaces))/v1/chat/completions") else {
            completion("无法生成报告：无效的API端点。")
            return
        }
        
        // 请求参数
        let parameters: [String: Any] = [
            "model": aiModelName,
            "messages": [
                ["role": "system", "content": "你是一位专业的音乐教师和练习顾问，你的名字是'音乐助手'。你需要基于练习数据提供简洁专业的练习报告和针对性建议。避免泛泛而谈，直接给出具体、个性化的建议。不要推荐番茄工作法，因为音乐练习需要长时间专注。"],
                ["role": "user", "content": prompt]
            ],
            "temperature": 0.7,
            "max_tokens": 1000
        ]
        
        // 序列化请求参数
        guard let jsonData = try? JSONSerialization.data(withJSONObject: parameters) else {
            completion("无法构建API请求数据。")
            return
        }
        
        // 创建网络请求
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("Bearer \(aiAPIKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData
        
        // 发送请求
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            // 处理错误
            if let error = error {
                DispatchQueue.main.async {
                    completion("生成报告时发生错误: \(error.localizedDescription)")
                }
                return
            }
            
            // 检查响应
            guard let data = data else {
                DispatchQueue.main.async {
                    completion("没有收到服务器响应。")
                }
                return
            }
            
            // 解析响应
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let choices = json["choices"] as? [[String: Any]],
                   let firstChoice = choices.first,
                   let message = firstChoice["message"] as? [String: Any],
                   let content = message["content"] as? String {
                    
                    DispatchQueue.main.async {
                        completion(content)
                    }
                } else {
                    // 尝试获取错误信息
                    if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let error = json["error"] as? [String: Any],
                       let message = error["message"] as? String {
                        DispatchQueue.main.async {
                            completion("生成报告失败: \(message)")
                        }
                    } else {
                        DispatchQueue.main.async {
                            completion("无法解析AI的回复。")
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    completion("解析响应时出错: \(error.localizedDescription)")
                }
            }
        }
        
        task.resume()
    }
    
    /**
     * @method startDistraction
     * @description 开始记录分心时间
     */
    @Published private(set) var isReviewingVoiceNote = false
    private var voiceNoteOwners = Set<UUID>()

    func setVoiceNoteActive(_ active: Bool, owner: UUID, at date: Date = Date()) {
        if active { voiceNoteOwners.insert(owner) } else { voiceNoteOwners.remove(owner) }
        let next = !voiceNoteOwners.isEmpty
        guard next != isReviewingVoiceNote else { return }
        isReviewingVoiceNote = next
        finishPendingSilence(at: date)
        if isActive && !isManuallyPaused {
            endDistraction(at: date)
            startDistraction(description: next ? "score.voiceReviewPause" : "未检测到练习声音", at: date)
        }
        audioMonitor.setVoiceNoteSuspended(next)
        if !next, isActive, !audioMonitor.isMonitoring, UIApplication.shared.applicationState != .background { audioMonitor.startMonitoring() }
    }

    /// Manual pauses use the same persisted pause intervals as automatic detection.
    /// Keep the detector warm; its notifications cannot resume a user-paused timer.
    func pausePractice(at date: Date = Date()) {
        guard isActive, !isManuallyPaused else { return }
        finishPendingSilence(at: date)
        endDistraction(at: date)
        isManuallyPaused = true
        startDistraction(description: "practice.manualPause", at: date)
    }

    func resumePractice(at date: Date = Date()) {
        guard isActive, isManuallyPaused else { return }
        endDistraction(at: date)
        isManuallyPaused = false
        if !audioMonitor.isMonitoring || !audioMonitor.isPlayingMusic || audioMonitor.isWaitingForSilence {
            startDistraction(description: "未检测到练习声音", at: date)
        }
    }

    @discardableResult
    func updatePracticeContent(sessionID: UUID, pieceName: String, notes: String) -> Bool {
        guard let index = allSessions.firstIndex(where: { $0.id == sessionID }) else { return false }
        var content = allSessions[index].practiceContent ?? PracticeContent(pieceName: "", improvements: "", notes: "")
        content.pieceName = pieceName.trimmingCharacters(in: .whitespacesAndNewlines)
        content.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        allSessions[index].practiceContent = content
        return true
    }

    func startDistraction(description: String, at date: Date = Date()) {
        guard isActive, currentSession != nil, currentDistraction == nil else { return }
        currentDistraction = Distraction(
            startTime: pendingSilenceStart ?? date,
            description: description
        )
        pendingSilenceStart = nil
    }
    
    /**
     * @method endDistraction
     * @description 结束分心记录
     */
    func endDistraction(at date: Date = Date()) {
        guard let distraction = currentDistraction, let session = currentSession else { return }
        
        // 创建一个已结束的分心记录副本
        var updatedDistraction = distraction
        updatedDistraction.endTime = max(distraction.startTime, date)
        
        // 创建会话的更新副本并添加分心记录
        var updatedSession = session
        updatedSession.distractions.append(updatedDistraction)
        
        // 更新当前会话
        currentSession = updatedSession
        currentDistraction = nil
    }

    /// Preserve a short silent gap without creating a confirmed interruption.
    func finishPendingSilence(at date: Date) {
        guard let start = pendingSilenceStart else { return }
        if var session = currentSession, date > start {
            var gaps = session.unsegmentedSilences ?? []
            gaps.append(Distraction(startTime: start, endTime: date, description: "无声间隔（未切段）"))
            session.unsegmentedSilences = gaps
            currentSession = session
        }
        pendingSilenceStart = nil
    }
    
    /**
     * @method handleAppStateChange
     * @description 处理应用状态变化
     */
    @objc func handleAppStateChange(notification: NSNotification) {
        // 从通知中确定应用状态
        let newState: UIApplication.State
        
        if notification.name == UIApplication.didEnterBackgroundNotification {
            newState = .background
        } else if notification.name == UIApplication.willEnterForegroundNotification {
            newState = .active
        } else {
            return
        }
        
        // 处理状态变化逻辑
        switch newState {
        case .active:
            refreshPracticeStatistics()
            // 回到前台
            // 如果启用了后台模式，并且已经在监测，则不需要做任何特殊处理
            if enableBackgroundMode && audioMonitor.isMonitoring {
                print("从后台返回前台，后台模式已启用，继续保持音频监测")
            } else {
                // 结束由于应用切换导致的分心
                if let currentDistraction = currentDistraction, 
                   currentDistraction.description == DistractionType.appSwitch.rawValue {
                    endDistraction()
                }
                
                // 设置音频监测器的应用状态
                audioMonitor.setAppBackgroundState(false)
                
                // 恢复音频监测
                if enableAudioMonitoring && isActive {
                    // Startup/permission time is not playing time. Record the
                    // pause now; the first musical result ends it immediately.
                    if !audioMonitor.isPlayingMusic {
                        startDistraction(description: "未检测到练习声音")
                    }
                    audioMonitor.requestPermission { [weak self] granted in
                        guard let self, self.isActive else { return }
                        if granted {
                            self.audioMonitor.startMonitoring()
                        }
                    }
                }
            }
            
        case .background, .inactive:
            // 进入后台或非活跃状态
            
            // 如果开启了后台模式
            if enableBackgroundMode {
                // 开启后台模式：明确告诉AudioMonitor不要停止监测
                audioMonitor.setAppBackgroundState(true, shouldStopMonitoring: false)
                
                // 确保麦克风权限并启动监测（防止之前没有开始）
                audioMonitor.requestPermission { [weak self] granted in
                    guard let self = self else { return }
                    
                    if granted && self.isActive && !self.audioMonitor.isMonitoring {
                        self.audioMonitor.startMonitoring()
                        print("后台模式已启动音频监测")
                    }
                    
                    print("后台模式已开启：继续在后台监测练琴，不记录分心")
                }
                
                // 如果当前有分心记录，且原因是应用切换，结束该分心记录
                if let currentDistraction = currentDistraction,
                   currentDistraction.description == DistractionType.appSwitch.rawValue {
                    endDistraction()
                    print("后台模式：结束应用切换导致的分心记录")
                }
            } else {
                // 未开启后台模式：明确停止监测
                audioMonitor.setAppBackgroundState(true, shouldStopMonitoring: true)
                
                // 停止音频监测，因为在后台/锁屏状态下麦克风不可用或不应持续监测
                audioMonitor.stopMonitoring()
                
                // 开始记录分心时间
                startDistraction(description: DistractionType.appSwitch.rawValue)
                print("进入后台，开始记录应用切换分心")
            }
            
        @unknown default:
            break
        }
    }
    
    /**
     * @method handleMusicInterruption
     * @description 处理音乐中断事件
     * 注意：此方法现在只用于记录，不再直接控制分心记录，由musicConfirmed和musicStopped通知控制
     */
    private func handleMusicInterruption() {
        print("检测到乐器声音中断")
        // 不再直接创建分心记录，等待musicStopped通知
    }
    
    /**
     * @method handleMusicResumption
     * @description 处理音乐恢复事件
     * 注意：此方法现在只用于记录，不再直接控制分心记录，由musicConfirmed和musicStopped通知控制
     */
    private func handleMusicResumption() {
        print("检测到乐器声音恢复")
        // 不再直接结束分心记录，等待musicConfirmed通知
    }
    
    /**
     * @method toggleAudioMonitoring
     * @description 切换音频监测状态
     */
    func toggleAudioMonitoring() {
        // 确保enableAudioMonitoring保持为true
        enableAudioMonitoring = true
        
        if isActive {
            audioMonitor.requestPermission { [weak self] granted in
                if granted {
                    self?.audioMonitor.startMonitoring()
                }
            }
        }
        
        saveSettings()
    }
    
    /**
     * @method setPassword
     * @description 设置密码
     */
    func setPassword(_ password: String) {
        // 使用SHA-256哈希密码
        if let passwordData = password.data(using: .utf8) {
            let hash = SHA256.hash(data: passwordData)
            passwordHash = hash.compactMap { String(format: "%02x", $0) }.joined()
        }
    }
    
    /**
     * @method verifyPassword
     * @description 验证密码
     */
    func verifyPassword(_ password: String) -> Bool {
        if let passwordData = password.data(using: .utf8) {
            let hash = SHA256.hash(data: passwordData)
            let inputHash = hash.compactMap { String(format: "%02x", $0) }.joined()
            return inputHash == passwordHash
        }
        return false
    }
    
    /**
     * @method endCurrentSessionIfNeeded
     * @description 如果有必要，结束当前会话
     */
    private func endCurrentSessionIfNeeded() {
        if currentSession != nil {
            endSession()
        }
    }
    
    /**
     * @method loadSessions
     * @description 从持久化存储加载历史会话
     */
    private func loadSessions() {
        guard let data = historyDefaults.data(forKey: sessionsKey) else { return }
        guard let sessions = try? JSONDecoder().decode([FocusSession].self, from: data) else {
            // A failed read is not an intentional deletion of the history or its awards.
            historyReadFailed = true
            return
        }
        allSessions = sessions
    }
    
    /**
     * @method saveSessions
     * @description 保存会话到持久化存储
     */
    private func saveSessions() {
        if let data = try? JSONEncoder().encode(allSessions) {
            historyDefaults.set(data, forKey: sessionsKey)
        }
    }
    
    /**
     * @method clearAllSessions
     * @description 清空所有练习记录
     */
    func clearAllSessions() {
        // 确保没有进行中的会话
        if isActive {
            endSession()
        }
        
        // 清空所有会话记录
        allSessions.removeAll()
        
    }
    
    /**
     * @method deleteSessionsForDate
     * @description 删除指定日期的所有练习记录
     * @param date 要删除记录的日期
     * @return 删除的记录数量
     */
    func deleteSessionsForDate(_ date: Date) -> Int {
        let calendar = practiceStatistics.calendar
        guard let day = calendar.dateInterval(of: .day, for: date) else { return 0 }
        if isActive, let session = currentSession,
           session.startTime < day.end && Date() > day.start {
            endSession()
        }
        // Delete complete original sessions, including ones that cross midnight.
        let ids = Set(getSessionsForDate(date).map(\.id))
        guard !ids.isEmpty else { return 0 }
        allSessions.removeAll { ids.contains($0.id) }
        return ids.count
    }

    /**
     * @method loadSettings
     * @description 从UserDefaults加载设置
     */
    private func loadSettings() {
        let defaults = UserDefaults.standard
        
        // 加载音频监控设置
        enableAudioMonitoring = defaults.bool(forKey: "enableAudioMonitoring")
        practiceMode = PracticeMode(rawValue: defaults.string(forKey: "practiceMode") ?? "") ?? .focusedInstrument
        audioMonitor.updatePracticeMode(practiceMode)
        let savedDelay = settingsDefaults.object(forKey: SilenceConfirmationSettings.storageKey) as? NSNumber
        silenceConfirmationDelay = SilenceConfirmationSettings.normalized(
            savedDelay?.doubleValue ?? SilenceConfirmationSettings.defaultDelay)
        audioMonitor.updateSilenceConfirmationDelay(silenceConfirmationDelay)
        
        // 加载AI分析设置
        enableAIAnalysis = defaults.bool(forKey: "enableAIAnalysis")
        aiAPIKey = defaults.string(forKey: "aiAPIKey") ?? ""
        aiAPIEndpoint = defaults.string(forKey: "aiAPIEndpoint") ?? "https://api.deepseek.com"
        aiModelName = defaults.string(forKey: "aiModelName") ?? "deepseek-chat"
        
        // 加载音乐阈值设置
        musicThreshold = defaults.float(forKey: "musicThreshold")
        if musicThreshold == 0 { musicThreshold = -35.0 } // 设置默认值

        // Other legacy timing preferences remain on disk but do not affect detection.

        // 加载六特征权重
        let loadedPitch = defaults.float(forKey: "pitchWeight")
        let loadedStability = defaults.float(forKey: "stabilityWeight")
        let loadedHarmonic = defaults.float(forKey: "harmonicWeight")
        let loadedFlatness = defaults.float(forKey: "flatnessWeight")
        let loadedLowFreq = defaults.float(forKey: "lowFreqWeight")
        let loadedRhythmic = defaults.float(forKey: "rhythmicWeight")

        // 如果所有权重都为0（首次启动），使用默认值
        if loadedPitch + loadedStability + loadedHarmonic + loadedFlatness + loadedLowFreq + loadedRhythmic < 0.01 {
            pitchWeight = 0.30
            stabilityWeight = 0.14
            harmonicWeight = 0.38
            flatnessWeight = 0.00
            lowFreqWeight = 0.11
            rhythmicWeight = 0.07
        } else {
            pitchWeight = loadedPitch
            stabilityWeight = loadedStability
            harmonicWeight = loadedHarmonic
            flatnessWeight = loadedFlatness
            lowFreqWeight = loadedLowFreq
            rhythmicWeight = loadedRhythmic
        }

        // 加载乐器选择
        if let instrumentString = defaults.string(forKey: "selectedInstrument"),
           let instrument = InstrumentType(rawValue: instrumentString) {
            selectedInstrument = instrument
        }
        
        // 加载锁屏通知设置
        enableLockScreenDisplay = defaults.bool(forKey: "enableLockScreenDisplay")
        let lockScreenValue = defaults.object(forKey: "enableLockScreenDisplay")
        if lockScreenValue == nil {
            enableLockScreenDisplay = true // 默认为开启
        }
        
        // 加载密码保护设置
        isPasswordProtected = defaults.bool(forKey: "isPasswordProtected")
        passwordHash = defaults.string(forKey: "passwordHash") ?? ""
        
        // 加载屏幕常亮设置
        let keepScreenOnValue = defaults.object(forKey: "enableKeepScreenOn")
        if keepScreenOnValue == nil {
            enableKeepScreenOn = true // 默认为开启
        } else {
            enableKeepScreenOn = defaults.bool(forKey: "enableKeepScreenOn")
        }
        
        // 加载后台模式设置
        enableBackgroundMode = defaults.bool(forKey: "enableBackgroundMode")
        
        // 加载自动后台刷新分析设置
        enableAutoRefreshAnalysis = UserDefaults.standard.bool(forKey: "\(settingsKey).enableAutoRefreshAnalysis")
    }

    /**
     * @method normalizeWeights
     * @description 从上往下逐级归一化权重（上面调好的锁定，只调整下面的）
     * @param changedWeight 改变的权重名称（pitch/stability/harmonic/flatness/lowFreq/rhythmic）
     * @param newValue 新的权重值
     *
     * 逻辑：
     * 1. Pitch调到50% → 剩余50%由下面5个分配
     * 2. Stability调到20% → 剩余30%由下面4个分配
     * 3. 以此类推，上面的权重锁定不动
     */
    func normalizeWeights(changedWeight: String, newValue: Float) {
        // 限制新值在0.0-1.0范围内
        let clampedValue = max(0.0, min(1.0, newValue))

        // 权重顺序（从上到下）
        let weightOrder = ["pitch", "stability", "harmonic", "flatness", "lowFreq", "rhythmic"]

        // 找到当前调整的权重位置
        guard let changedIndex = weightOrder.firstIndex(of: changedWeight) else { return }

        // 计算上面已经锁定的权重总和
        var lockedWeightSum: Float = 0.0
        for i in 0..<changedIndex {
            switch weightOrder[i] {
            case "pitch": lockedWeightSum += pitchWeight
            case "stability": lockedWeightSum += stabilityWeight
            case "harmonic": lockedWeightSum += harmonicWeight
            case "flatness": lockedWeightSum += flatnessWeight
            case "lowFreq": lockedWeightSum += lowFreqWeight
            case "rhythmic": lockedWeightSum += rhythmicWeight
            default: break
            }
        }

        // 可用的最大权重 = 1.0 - 上面锁定的总和
        let maxAvailable = 1.0 - lockedWeightSum
        let finalValue = min(clampedValue, maxAvailable)

        // 设置当前权重
        switch changedWeight {
        case "pitch": pitchWeight = finalValue
        case "stability": stabilityWeight = finalValue
        case "harmonic": harmonicWeight = finalValue
        case "flatness": flatnessWeight = finalValue
        case "lowFreq": lowFreqWeight = finalValue
        case "rhythmic": rhythmicWeight = finalValue
        default: break
        }

        // 计算剩余可分配权重
        let remainingWeight = 1.0 - lockedWeightSum - finalValue

        // 收集下面需要调整的权重
        var belowWeights: [(name: String, value: Float)] = []
        for i in (changedIndex + 1)..<weightOrder.count {
            let name = weightOrder[i]
            var value: Float = 0.0
            switch name {
            case "pitch": value = pitchWeight
            case "stability": value = stabilityWeight
            case "harmonic": value = harmonicWeight
            case "flatness": value = flatnessWeight
            case "lowFreq": value = lowFreqWeight
            case "rhythmic": value = rhythmicWeight
            default: break
            }
            belowWeights.append((name, value))
        }

        // 计算下面权重的总和
        let belowWeightSum = belowWeights.reduce(0.0) { $0 + $1.value }

        // 重新分配下面的权重
        if belowWeightSum <= 0.001 {
            // 如果下面权重都是0，平均分配
            let count = Float(belowWeights.count)
            if count > 0 {
                let averageWeight = remainingWeight / count
                for (name, _) in belowWeights {
                    switch name {
                    case "pitch": pitchWeight = averageWeight
                    case "stability": stabilityWeight = averageWeight
                    case "harmonic": harmonicWeight = averageWeight
                    case "flatness": flatnessWeight = averageWeight
                    case "lowFreq": lowFreqWeight = averageWeight
                    case "rhythmic": rhythmicWeight = averageWeight
                    default: break
                    }
                }
            }
        } else {
            // 按比例缩放下面的权重
            let scaleFactor = remainingWeight / belowWeightSum
            for (name, value) in belowWeights {
                let newValue = value * scaleFactor
                switch name {
                case "pitch": pitchWeight = newValue
                case "stability": stabilityWeight = newValue
                case "harmonic": harmonicWeight = newValue
                case "flatness": flatnessWeight = newValue
                case "lowFreq": lowFreqWeight = newValue
                case "rhythmic": rhythmicWeight = newValue
                default: break
                }
            }
        }

        // 计算总和并打印
        let totalWeight = pitchWeight + stabilityWeight + harmonicWeight + flatnessWeight + lowFreqWeight + rhythmicWeight
        let weightPercent = Int(finalValue * 100)
        let totalPercent = Int(totalWeight * 100)
        print("🎛️ 权重已调整: \(changedWeight)=\(weightPercent)% (锁定前\(changedIndex)项), 总和=\(totalPercent)%")
    }

    /**
     * @method saveSettings
     * @description 保存设置到UserDefaults
     */
    func saveSettings() {
        let defaults = UserDefaults.standard
        
        // 保存音频监控设置
        defaults.set(enableAudioMonitoring, forKey: "enableAudioMonitoring")
        
        // Preserve retired AI preferences verbatim; this release does not edit them.

        // 保存音乐阈值设置
        defaults.set(musicThreshold, forKey: "musicThreshold")

        // 保存六特征权重
        defaults.set(pitchWeight, forKey: "pitchWeight")
        defaults.set(stabilityWeight, forKey: "stabilityWeight")
        defaults.set(harmonicWeight, forKey: "harmonicWeight")
        defaults.set(flatnessWeight, forKey: "flatnessWeight")
        defaults.set(lowFreqWeight, forKey: "lowFreqWeight")
        defaults.set(rhythmicWeight, forKey: "rhythmicWeight")

        // 保存乐器选择
        defaults.set(selectedInstrument.rawValue, forKey: "selectedInstrument")
        
        // 保存锁屏通知设置
        defaults.set(enableLockScreenDisplay, forKey: "enableLockScreenDisplay")
        
        // 保存密码保护设置
        defaults.set(isPasswordProtected, forKey: "isPasswordProtected")
        defaults.set(passwordHash, forKey: "passwordHash")
        
        // 保存屏幕常亮设置
        defaults.set(enableKeepScreenOn, forKey: "enableKeepScreenOn")
        
        // 保存后台模式设置
        defaults.set(enableBackgroundMode, forKey: "enableBackgroundMode")
        
        // 保存自动后台刷新分析设置
        UserDefaults.standard.set(enableAutoRefreshAnalysis, forKey: "\(settingsKey).enableAutoRefreshAnalysis")

        // Retired heart-rate preferences and historical samples stay on disk.
    }
    
    /**
     * @method getSessionsForDate
     * @description 获取指定日期的所有练习会话
     * @param date 指定日期
     * @return 该日期的所有练习会话
     */
    func getSessionsForDate(_ date: Date) -> [FocusSession] {
        practiceStatistics.day(date).sessions
    }
    
    /**
     * @method getSessionsForWeek
     * @description 获取指定日期所在周的练习会话
     * @param date 要查询的日期
     * @return 该周的所有练习会话
     */
    func getSessionsForWeek(_ date: Date) -> [FocusSession] {
        let calendar = practiceStatistics.calendar
        let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        
        guard let startOfWeek = calendar.date(from: components) else { return [] }
        guard let endOfWeek = calendar.date(byAdding: .day, value: 7, to: startOfWeek) else { return [] }
        
        return allSessions.filter { session in
            guard let end = session.endTime else { return false }
            return session.startTime < endOfWeek && end > startOfWeek && session.startTime < practiceStatistics.asOf
        }
    }
    
    /**
     * @method getTotalFocusTimeForDate
     * @description 获取指定日期的总专注时间
     * @param date 指定日期
     * @return 该日期的总专注时间（秒）
     */
    func getTotalFocusTimeForDate(_ date: Date) -> TimeInterval {
        practiceStatistics.day(date).focusTime
    }
    
    /**
     * @method getTotalDistractionTimeForDate
     * @description 获取指定日期的总分心时间
     * @param date 指定日期
     * @return 该日期的总分心时间（秒）
     */
    func getTotalDistractionTimeForDate(_ date: Date) -> TimeInterval {
        practiceStatistics.day(date).pauseTime
    }
    
    /**
     * @method getFullSessionStats
     * @description 获取当前会话的所有统计数据
     */
    func getFullSessionStats(at now: Date = Date()) -> (totalFocusTime: TimeInterval, totalDistractionTime: TimeInterval, distractions: [Distraction]) {
        guard var session = currentSession else {
            return (0, 0, [])
        }
        
        var distractions = session.distractions
        
        // 如果有当前正在进行的分心记录，添加临时副本
        if let current = currentDistraction {
            var tempDistraction = current
            tempDistraction.endTime = now
            distractions.append(tempDistraction)
        }
        
        session.distractions = distractions
        if let start = pendingSilenceStart {
            var gaps = session.unsegmentedSilences ?? []
            gaps.append(Distraction(startTime: start, endTime: now, description: "无声等待"))
            session.unsegmentedSilences = gaps
        }
        let totals = PracticeTimeAccounting.totals(session, asOf: now)
        return (totals.focus, totals.pause, distractions)
    }
    
    /**
     * @method requestNotificationPermission
     * @description 请求通知权限
     */
    private func requestNotificationPermission() {
        // 已禁用通知功能
    }
    
    /**
     * @method startLockScreenUpdates
     * @description 开始锁屏信息更新
     */
    private func startLockScreenUpdates() {
        // 已禁用锁屏更新功能
    }
    
    /**
     * @method stopLockScreenUpdates
     * @description 停止锁屏信息更新
     */
    private func stopLockScreenUpdates() {
        if let timer = lockScreenNotificationTimer {
            timer.invalidate()
            lockScreenNotificationTimer = nil
        }
    }
    
    /**
     * @method updateLockScreenNotification
     * @description 更新锁屏通知内容
     */
    private func updateLockScreenNotification() {
        // 此功能已禁用
        return
    }
    
    /**
     * @method adjustStatsForLockScreen
     * @description 调整锁屏状态下的统计数据，避免错误记录分心时间
     */
    private func adjustStatsForLockScreen(_ stats: (totalFocusTime: TimeInterval, totalDistractionTime: TimeInterval, distractions: [Distraction])) -> (totalFocusTime: TimeInterval, totalDistractionTime: TimeInterval) {
        var adjustedDistractTime = stats.totalDistractionTime
        
        // 如果当前有因为进入后台/锁屏产生的分心记录，不计入总分心时间
        if let current = currentDistraction, current.description == DistractionType.appSwitch.rawValue {
            adjustedDistractTime -= current.duration
        }
        
        // 调整专注时间
        let now = Date()
        let totalSessionTime = now.timeIntervalSince(currentSession!.startTime)
        let adjustedFocusTime = totalSessionTime - adjustedDistractTime
        
        return (adjustedFocusTime, adjustedDistractTime)
    }
    
    /**
     * @method removeLockScreenNotification
     * @description 移除锁屏通知
     */
    private func removeLockScreenNotification() {
        // 已禁用锁屏通知功能
    }
    
    /**
     * @method toggleLockScreenDisplay
     * @description 切换锁屏显示功能
     */
    func toggleLockScreenDisplay() {
        enableLockScreenDisplay.toggle()
        
        // 锁屏通知功能已禁用
        if enableLockScreenDisplay {
            // 不执行任何操作
        } else {
            stopLockScreenUpdates()
            removeLockScreenNotification()
        }
        
        saveSettings()
    }
    
    /**
     * @method toggleKeepScreenOn
     * @description 切换屏幕常亮功能
     */
    func toggleKeepScreenOn() {
        enableKeepScreenOn.toggle()
        
        // 如果当前有活跃会话，立即应用新设置
        if isActive {
            setIdleTimerDisabled(enableKeepScreenOn)
        }
        
        saveSettings()
    }
    
    /**
     * @method setIdleTimerDisabled
     * @description 设置设备是否禁用自动锁屏
     * @param disabled 是否禁用自动锁屏
     */
    private func setIdleTimerDisabled(_ disabled: Bool) {
        DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = disabled
        }
    }
    
    /**
     * @method setInstrument
     * @description 设置乐器类型并更新推荐阈值
     * @param instrument 乐器类型
     * @param applyRecommendedValue 是否应用推荐的阈值设置
     */
    func setInstrument(_ instrument: InstrumentType, applyRecommendedValue: Bool = true) {
        selectedInstrument = instrument
        
        if applyRecommendedValue && instrument != .custom {
            musicThreshold = instrument.recommendedThreshold
        }
        
        // 将乐器类型和阈值设置传递给AudioMonitor
        audioMonitor.updateConfiguration(threshold: musicThreshold, instrumentType: instrument)
        
        print("乐器设置已更新：\(instrument.rawValue)，阈值：\(musicThreshold)")
    }
    
    /**
     * @method testAIConnection
     * @description 测试与AI API的连接
     */
    func testAIConnection(completion: @escaping (Bool, String) -> Void) {
        guard Self.aiFeaturesAvailable else { completion(false, "AI 功能暂未开放"); return }
        // 检查API密钥不为空
        guard !aiAPIKey.isEmpty else {
            completion(false, "API密钥不能为空")
            return
        }
        
        // 检查模型名称不为空
        guard !aiModelName.isEmpty else {
            completion(false, "模型名称不能为空")
            return
        }
        
        // 是否为火山方舟模型
        let isVolcengineModel = aiAPIEndpoint.contains("volces.com")
        // 是否为DeepSeek Reasoner模型
        let isReasonerModel = aiModelName.lowercased() == "deepseek-reasoner"
        
        // 根据不同服务商构建不同的端点
        let endpoint: String
        if isVolcengineModel {
            endpoint = "\(aiAPIEndpoint.trimmingCharacters(in: .whitespaces))/api/v3/chat/completions"
        } else if isReasonerModel {
            endpoint = "\(aiAPIEndpoint.trimmingCharacters(in: .whitespaces))/chat/completions"
        } else if aiAPIEndpoint.contains("siliconflow.cn") {
            // 硅基流动API需要使用chat格式的端点
            endpoint = "\(aiAPIEndpoint.trimmingCharacters(in: .whitespaces))/v1/chat/completions"
        } else {
            endpoint = "\(aiAPIEndpoint.trimmingCharacters(in: .whitespaces))/v1/completions"
        }
        
        guard let url = URL(string: endpoint) else {
            completion(false, "无效的API端点地址: \(endpoint)")
            return
        }
        
        // 创建请求
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("Bearer \(aiAPIKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        // 根据不同的模型创建不同的请求体
        let requestBody: [String: Any]
        
        if isVolcengineModel && (aiModelName.contains("deepseek") || aiModelName.contains("doubao")) {
            // 火山方舟模型 - 启用思考过程显示（对于deepseek系列）
            var parameters: [String: Any] = [
                "model": aiModelName,
                "messages": [
                    ["role": "user", "content": "解决这个数学问题：如果一个圆的半径是6厘米，它的面积是多少？展示你的思考过程。"]
                ],
                "temperature": 0.7,
                "max_tokens": 2000,
                "top_p": 0.95
            ]
            
            // 为DeepSeek系列模型添加推理过程参数
            if aiModelName.contains("deepseek") {
                parameters["show_reasoning"] = true
            }
            
            requestBody = parameters
        } else if isReasonerModel {
            // deepseek-reasoner模型使用chat格式
            requestBody = [
                "model": aiModelName,
                "messages": [
                    ["role": "user", "content": "简单测试连接"]
                ],
                "max_tokens": 5
            ]
        } else if isVolcengineModel {
            // 其他火山方舟模型使用chat格式
            requestBody = [
                "model": aiModelName,
                "messages": [
                    ["role": "user", "content": "简单测试连接"]
                ],
                "max_tokens": 5
            ]
        } else if aiAPIEndpoint.contains("siliconflow.cn") {
            // 硅基流动API模型
            requestBody = [
                "model": aiModelName,
                "messages": [
                    ["role": "user", "content": "简单测试连接"]
                ],
                "max_tokens": 20,  // 对于测试连接，较小的token数足够
                "top_p": 0.95,     // 添加top_p参数
                "stream": false    // 显式设置为非流式请求
            ]
        } else {
            // 其他模型使用标准completion格式
            requestBody = [
                "model": aiModelName,
                "prompt": "简单测试连接",
                "max_tokens": 5
            ]
        }
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        } catch {
            completion(false, "无法创建请求: \(error.localizedDescription)")
            return
        }
        
        // 发送请求
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            
            // 处理网络错误
            if let error = error {
                DispatchQueue.main.async {
                    completion(false, "网络错误: \(error.localizedDescription)")
                }
                return
            }
            
            // 检查HTTP响应
            guard let httpResponse = response as? HTTPURLResponse else {
                DispatchQueue.main.async {
                    completion(false, "无效的服务器响应")
                }
                return
            }
            
            // 检查状态码
            if httpResponse.statusCode == 200 {
                // 用于火山方舟模型的特殊处理
                if isVolcengineModel && (self.aiModelName.contains("deepseek") || self.aiModelName.contains("doubao")) {
                    if let data = data,
                       let responseJSON = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let choices = responseJSON["choices"] as? [[String: Any]],
                       let firstChoice = choices.first {
                        
                        // 检查是否有推理过程（主要是deepseek系列）
                        if let reasoning = firstChoice["reasoning"] as? String,
                           !reasoning.isEmpty {
                            // 有推理过程，显示推理过程
                            DispatchQueue.main.async {
                                if let message = firstChoice["message"] as? [String: Any],
                                   let content = message["content"] as? String {
                                    // 将推理过程与内容合并
                                    let combinedResponse = """
                                    思考过程：
                                    \(reasoning)
                                    
                                    回答：
                                    \(content)
                                    """
                                    completion(true, combinedResponse)
                                } else {
                                    completion(true, reasoning)
                                }
                            }
                            return
                        }
                    }
                }
                
                // 标准成功响应
                DispatchQueue.main.async {
                    completion(true, "连接成功")
                }
            } else {
                // 尝试解析错误消息
                if let data = data {
                    do {
                        if let jsonString = String(data: data, encoding: .utf8) {
                            print("API响应内容: \(jsonString)")
                        }
                        
                        if let errorJSON = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                            // 处理不同格式的错误响应
                            if let errorMessage = errorJSON["error"] as? [String: Any],
                               let message = errorMessage["message"] as? String {
                                DispatchQueue.main.async {
                                    completion(false, "API错误 (\(httpResponse.statusCode)): \(message)")
                                }
                            } else if let errorMsg = errorJSON["error"] as? String {
                                DispatchQueue.main.async {
                                    completion(false, "API错误 (\(httpResponse.statusCode)): \(errorMsg)")
                                }
                            } else {
                                DispatchQueue.main.async {
                                    completion(false, "API错误 (状态码: \(httpResponse.statusCode)), 详情: \(errorJSON)")
                                }
                            }
                        } else {
                            DispatchQueue.main.async {
                                completion(false, "API错误 (状态码: \(httpResponse.statusCode))")
                            }
                        }
                    } catch {
                        DispatchQueue.main.async {
                            completion(false, "API错误 (状态码: \(httpResponse.statusCode)), 无法解析响应: \(error.localizedDescription)")
                        }
                    }
                } else {
                    DispatchQueue.main.async {
                        completion(false, "API错误 (状态码: \(httpResponse.statusCode))")
                    }
                }
            }
        }
        
        task.resume()
    }
    
    /**
     * @method generateMockAIAnalysisResults
     * @description 生成模拟的AI分析结果数据，根据实际练习情况生成
     */
    func generateMockAIAnalysisResults() {
        // 确保AI分析已启用
        guard isAIAnalysisEnabled else { return }
        
        // 创建模拟结果
        var mockResults: [String: Any] = [:]
        
        // 获取当前会话数据
        var practiceTimeHours: Double = 0
        var focusRate: Double = 0.8
        var distractionCount: Int = 0

        if let session = currentSession {
            let currentTime = Date().timeIntervalSince(session.startTime)
            practiceTimeHours = currentTime / 3600.0
            distractionCount = session.distractions.count
            
            // 计算专注率
            if currentTime > 0 {
                focusRate = (currentTime - session.distractionTime) / currentTime
            }
            
            // 如果练习时间不足5分钟，不生成分析结果
            if currentTime < 300 { // 5分钟 = 300秒
                // 只设置时间戳，其他数据留空
                mockResults["timestamp"] = Date().timeIntervalSince1970
                mockResults["message"] = "练习时间不足，继续练习以获取分析"
                self.aiAnalysisResults = mockResults
                return
            }
        } else {
            // 没有活跃会话，不生成分析结果
            return
        }
        
        // 重新设计评分系统 - 总分100分
        var performanceScore = 0 // 从0开始计算
        
        // 1. 专注时间: 每两分钟1分，上限75分
        let focusTimeMinutes = practiceTimeHours * 60
        let focusTimeScore = min(Int(focusTimeMinutes / 2), 75)
        performanceScore += focusTimeScore
        
        // 2. 节奏稳定性: 最高15分
        let rhythmStabilityRaw = min(0.5 + (focusRate * 0.5), 0.95) // 基础节奏稳定性，与专注率相关
        let rhythmAdjustment = (distractionCount <= 5) ? 0.1 : (distractionCount <= 10 ? 0.0 : -0.1) // 分心次数调整
        let rhythmStability = min(max(rhythmStabilityRaw + rhythmAdjustment, 0.0), 1.0)
        let rhythmScore = Int(rhythmStability * 15)
        performanceScore += rhythmScore
        
        // 3. 快慢练习比例: 最高10分
        var tempoVariationScore = 0
        
        // 基于练习时长和专注率评估快慢练习比例
        if practiceTimeHours > 3 && focusRate > 0.85 {
            // 长时间高专注度练习，假设有理想的快慢练习比例
            tempoVariationScore = 10
        } else if practiceTimeHours > 2 && focusRate > 0.8 {
            // 中等时长高专注度
            tempoVariationScore = 8
        } else if practiceTimeHours > 1 && focusRate > 0.7 {
            // 较短时长中等专注度
            tempoVariationScore = 6
        } else if practiceTimeHours > 0.5 {
            // 短时练习
            tempoVariationScore = 4
        } else {
            // 极短练习，难以形成有效的快慢练习比例
            tempoVariationScore = 2
        }
        
        // 针对特定情况进行调整
        if audioMonitor.isPlayingMusic && audioMonitor.musicProbability > 0.8 {
            // 检测到良好音乐信号，小幅提升
            tempoVariationScore = min(tempoVariationScore + 1, 10)
        }
        
        performanceScore += tempoVariationScore
        
        // 存储各项得分明细，便于UI展示
        mockResults["focusTimeScore"] = focusTimeScore
        mockResults["rhythmScore"] = rhythmScore
        mockResults["tempoVariationScore"] = tempoVariationScore
        
        // 确保分数在0-100范围内
        performanceScore = min(max(performanceScore, 0), 100)
        mockResults["performanceScore"] = performanceScore
        
        // 保存计算细节，用于显示
        mockResults["scoreDetail"] = [
            "focusTimeScore": [
                "score": focusTimeScore,
                "description": "专注时间: \(Int(focusTimeMinutes))分钟，每两分钟1分(上限75分)"
            ],
            "rhythmScore": [
                "score": rhythmScore,
                "description": "节奏稳定性: \(Int(rhythmStability * 100))%(最高15分)"
            ],
            "tempoVariationScore": [
                "score": tempoVariationScore,
                "description": "快慢练习比例: \(tempoVariationScore)分(最高10分)"
            ]
        ]
        
        // 2. 速度分析结果 - 根据练习时长和专注率模拟不同的练习模式
        let hasTempoVariation = practiceTimeHours > 1 && focusRate > 0.8
        let tempoStability = rhythmStability // 使用上面计算的节奏稳定性
        let avgTempo = Int.random(in: 70...110)
        
        // 根据练习时长和专注率选择合适的模式描述
        var tempoPattern = ""
        var tempoDescription = ""
        
        if practiceTimeHours > 3 && focusRate > 0.9 {
            tempoPattern = "系统化的快慢交替练习"
            tempoDescription = "练习中包含了充分的慢速练习和适当的快速练习交替，体现了专业的练习方法，有助于技巧巩固和流畅性提升。"
        } else if practiceTimeHours > 2 && focusRate > 0.8 {
            tempoPattern = "以慢练为主偶有快练"
            tempoDescription = "练习以慢速为主，偶尔尝试目标速度，这是良好的练习习惯，有助于打好基础。"
        } else if practiceTimeHours > 1 {
            tempoPattern = "速度变化不够明显"
            tempoDescription = "练习速度较为单一，建议增加快慢交替练习以提高学习效率。特别是对技术难点部分，应当放慢速度重点练习。"
        } else {
            tempoPattern = "速度略不稳定"
            tempoDescription = "练习时间较短，速度控制不够稳定，建议延长练习时间并使用节拍器辅助练习。"
        }
        
        mockResults["tempoAnalysis"] = [
            "stability": tempoStability,
            "hasVariation": hasTempoVariation,
            "averageTempo": avgTempo,
            "pattern": tempoPattern,
            "description": tempoDescription
        ]
        
        // 3. 强弱对比分析 - 同样基于练习时长和专注率
        let dynamicsRange = min(10 + (practiceTimeHours * 3), 30) // 练习时间越长，强弱范围越大
        let expressiveness = min(0.5 + (focusRate * 0.3) + (practiceTimeHours * 0.05), 0.95) // 专注率和时长共同影响表现力
        
        var emotion = ""
        var dynamicsDescription = ""
        
        if practiceTimeHours > 3 && focusRate > 0.9 {
            emotion = "层次分明"
            dynamicsDescription = "强弱对比明显，情感表达丰富，音乐层次感突出，体现了对作品的深入理解。"
        } else if practiceTimeHours > 2 && focusRate > 0.8 {
            emotion = "丰富"
            dynamicsDescription = "强弱变化适当，情感表达较为丰富，音乐表现力良好。"
        } else if practiceTimeHours > 1 {
            emotion = "起伏有限"
            dynamicsDescription = "强弱变化较小，情感表达有限，建议加强音乐表现力训练，尝试更大的强弱对比。"
        } else {
            emotion = "平淡"
            dynamicsDescription = "强弱变化不足，情感表达较为平淡，建议在基本技术练习的同时，也关注音乐表现力的培养。"
        }
        
        mockResults["dynamicsAnalysis"] = [
            "range": dynamicsRange,
            "expressiveness": expressiveness,
            "emotion": emotion,
            "description": dynamicsDescription
        ]
        
        // 4. 节奏稳定性和音高准确性 - 基于专注率
        mockResults["rhythmStability"] = min(0.5 + (focusRate * 0.5), 0.95)
        mockResults["pitchAccuracy"] = min(0.6 + (focusRate * 0.4), 0.95)
        
        // 5. 练习建议 - 根据练习情况提供针对性建议
        var selectedSuggestions: [String] = []
        
        // 基于实际数据的具体建议
        if practiceTimeHours < 1 {
            selectedSuggestions.append("当前练习时长仅为\(String(format: "%.1f", practiceTimeHours * 60))分钟，专业音乐家通常每天练习6-8小时，建议至少延长到1-2小时以获得更好效果。")
        }
        
        if distractionCount > 10 {
            selectedSuggestions.append("在\(String(format: "%.1f", practiceTimeHours * 60))分钟的练习中出现了\(distractionCount)次分心，平均每\(String(format: "%.1f", practiceTimeHours * 60 / Double(distractionCount)))分钟分心一次，建议使用番茄工作法（25分钟专注+5分钟休息）提高专注度。")
        }
        
        if focusRate < 0.7 {
            selectedSuggestions.append("当前专注率仅为\(String(format: "%.1f", focusRate * 100))%，分心时间占总练习时间的\(String(format: "%.1f", (1-focusRate) * 100))%，建议减少外部干扰，创造更安静的练习环境。")
        }
        
        if !hasTempoVariation && practiceTimeHours > 0.5 {
            selectedSuggestions.append("在\(String(format: "%.1f", practiceTimeHours * 60))分钟的练习中，未检测到明显的速度变化，建议采用慢练（原速度的50%）-中速（75%）-快速（100%）的三段式练习法，特别是对技术难点部分。")
        }
        
        if audioMonitor.decibels < -50 && practiceTimeHours > 0.3 {
            selectedSuggestions.append("检测到音量较低（\(String(format: "%.1f", audioMonitor.decibels))dB），可能是练习强度不够或距离麦克风较远，建议调整位置或增加练习力度。")
        }
        
        // 根据乐器类型提供针对性建议
        switch selectedInstrument {
        case .piano:
            if practiceTimeHours > 0.5 {
                selectedSuggestions.append("钢琴练习建议：对于技术难点段落，尝试分手练习，先掌握左右手各自的部分，再逐步合并，这样可以更有效地解决复杂段落。")
            }
        case .violin, .erhu:
            if practiceTimeHours > 0.5 {
                selectedSuggestions.append("\(selectedInstrument.rawValue)练习建议：注意检查音准，可以使用调音器辅助练习，特别是在高把位或快速换把时。")
            }
        case .guitar, .ukulele:
            if practiceTimeHours > 0.5 {
                selectedSuggestions.append("\(selectedInstrument.rawValue)练习建议：注意左手指法的清晰度和右手的节奏感，可以先慢速练习以确保每个音符的清晰度。")
            }
        case .flute, .saxophone, .trumpet:
            if practiceTimeHours > 0.5 {
                selectedSuggestions.append("\(selectedInstrument.rawValue)练习建议：注意呼吸控制，每次练习前进行5-10分钟的长音练习，以稳定气息和音色。")
            }
        default:
            break
        }
        
        // 确保至少有3条建议
        if selectedSuggestions.count < 3 {
            // 通用建议，但仍然基于实际数据
            if practiceTimeHours > 1 {
                selectedSuggestions.append("建议将当前\(String(format: "%.1f", practiceTimeHours))小时的练习分成3-4个段落，每个段落专注于不同的技术或表现力方面，这样可以更全面地提高演奏水平。")
            }
            
            if audioMonitor.musicProbability > 0.7 {
                selectedSuggestions.append("检测到较好的乐器声音信号，建议尝试录制自己的练习并回听，客观评估演奏中的优点和不足，这是提高演奏质量的有效方法。")
            }
        }
        
        mockResults["suggestions"] = selectedSuggestions
        
        // 6. 乐器识别
        mockResults["instrumentDetection"] = [
            "instrument": selectedInstrument.rawValue,
            "confidence": 0.95
        ]
        
        // 7. 时间戳
        mockResults["timestamp"] = Date().timeIntervalSince1970
        
        // 8. 练习进度评估
        let progressDescription: String
        if performanceScore >= 85 {
            progressDescription = "专业水平：你的练习方法和专注度达到了专业水准，继续保持！"
        } else if performanceScore >= 70 {
            progressDescription = "良好水平：你的练习质量良好，有一些小的改进空间。"
        } else if performanceScore >= 50 {
            progressDescription = "中等水平：你的练习有一定效果，但仍有较大提升空间。"
        } else {
            progressDescription = "初级水平：你的练习方法和专注度需要显著改进。"
        }
        mockResults["progressDescription"] = progressDescription
        
        // 更新分析结果
        self.aiAnalysisResults = mockResults
    }
    
    /**
     * @method startAIAnalysis
     * @description 开始AI分析
     */
    func startAIAnalysis() {
        // 检查AI分析是否已启用
        guard isAIAnalysisEnabled else { return }
        
        // 创建定时器，定期执行分析
        aiAnalysisTimer?.invalidate()
        aiAnalysisTimer = Timer.scheduledTimer(withTimeInterval: 300.0, repeats: true) { [weak self] _ in
            self?.performAIAnalysis()
        }
        
        // 立即执行一次分析
        performAIAnalysis()
    }
    
    /**
     * @method stopAIAnalysis
     * @description 停止AI分析
     */
    func stopAIAnalysis() {
        aiAnalysisTimer?.invalidate()
        aiAnalysisTimer = nil
    }
    
    /**
     * @method performAIAnalysis
     * @description 执行AI分析
     */
    private func performAIAnalysis() {
        guard isAIAnalysisEnabled else { return }
        // 确保有足够的数据用于分析
        guard isActive, let session = currentSession, !aiAPIKey.isEmpty, !aiModelName.isEmpty else {
            return
        }
        
        // 获取当前音频特征数据
        let audioFeatures = getAudioFeaturesForAnalysis()

        // 计算当前练习时长
        let currentPracticeTime = Date().timeIntervalSince(session.startTime)

        // 获取当前分心次数和总分心时间
        let distractionCount = session.distractions.count
        let distractionTimeMinutes = session.distractionTime / 60.0
        
        // 计算专注率
        let focusRate = currentPracticeTime > 0 ? (currentPracticeTime - session.distractionTime) / currentPracticeTime : 0
        
        // 构建请求内容
        let prompt = """
        作为专业音乐教师，请分析以下练琴数据，提供专业的练习质量评估和建议：
        
        【基本信息】
        - 乐器类型: \(selectedInstrument.rawValue)
        - 练习时长: \(TimeFormatter.formatTimeInterval(currentPracticeTime))
        - 有效专注时间: \(TimeFormatter.formatTimeInterval(currentPracticeTime - session.distractionTime))
        - 专注率: \(String(format: "%.1f%%", focusRate * 100))
        - 分心次数: \(distractionCount)次
        - 分心总时间: \(String(format: "%.1f", distractionTimeMinutes))分钟
        
        【音频特征】
        - 平均分贝: \(String(format: "%.1f", audioMonitor.decibels)) dB
        - 音量变化: \(audioFeatures["volumeChanges"] ?? "数据不足")
        - 速度估计: \(audioFeatures["tempoEstimates"] ?? "数据不足")
        - 节奏稳定性: \(audioFeatures["rhythmStability"] ?? "数据不足")
        - 强弱范围: \(audioFeatures["dynamicsRange"] ?? "数据不足")
        
        【评估要点】
        1. 练习时长评估：专业音乐家通常每天练习6-8小时，评估当前练习时长是否充足。
        2. 练习质量评估：基于专注率、分心情况和音频特征，评估练习的专注度和有效性。
        3. 速度变化分析：评估是否有慢速练习和快速练习的合理交替，慢练是否足够。
        4. 节奏稳定性：评估节奏是否稳定，是否有急躁或不规律的现象。
        5. 表现力分析：评估强弱对比和音乐表现力。
        
        【输出要求】
        请提供以下分析结果（JSON格式）：
        1. performanceScore: 练习质量总体评分(1-10分)，考虑练习时长、专注度和练习方法
        2. rhythmStability: 节奏稳定性评分(0-1)
        3. pitchAccuracy: 音高准确性评分(0-1)，基于音频特征估计
        4. tempoAnalysis: 速度分析对象，包含stability(稳定性)、hasVariation(是否有变化)、averageTempo(平均速度)、pattern(模式描述)、description(详细描述)
        5. dynamicsAnalysis: 强弱分析对象，包含range(范围)、expressiveness(表现力)、emotion(情感描述)、description(详细描述)
        6. suggestions: 针对性练习建议数组，至少5条具体可行的提升方法
        7. instrumentDetection: 乐器识别对象，包含instrument(乐器名称)、confidence(置信度)
        8. timestamp: 当前时间戳
        
        注意：如果练习时间少于1小时，评分不应超过7分；如果练习时间超过3小时且专注率高，评分应至少为8分；如果练习时间超过6小时且有良好的慢练和节奏稳定性，评分应至少为9分。
        """
        
        // 创建API请求
        var endpoint = ""
        var parameters: [String: Any] = [:]
        let isVolcengineModel = aiAPIEndpoint.contains("volces.com")
        let isDeepSeekModel = aiModelName.lowercased().contains("deepseek")

        if isVolcengineModel {
            // 火山方舟API
            endpoint = "\(aiAPIEndpoint)/v1/chat/completions"
            parameters = [
                "model": aiModelName,
                "messages": [
                    ["role": "system", "content": "你是一位专业的音乐教师，擅长分析练琴数据并提供专业建议。"],
                    ["role": "user", "content": prompt]
                ],
                "temperature": 0.3,
                "max_tokens": 2000
            ]
            
            // 为DeepSeek系列模型添加推理过程参数
            if isDeepSeekModel {
                parameters["show_reasoning"] = true
            }
        } else if aiAPIEndpoint.contains("siliconflow.cn") {
            // 硅基流动API
            endpoint = "\(aiAPIEndpoint)/v1/chat/completions"
            parameters = [
                "model": aiModelName,
                "messages": [
                    ["role": "system", "content": "你是一位专业的音乐教师，擅长分析练琴数据并提供专业建议。"],
                    ["role": "user", "content": prompt]
                ],
                "temperature": 0.3,
                "max_tokens": 4000  // 增加max_tokens，确保DeepSeek模型返回更完整的回答
            ]
        } else {
            // 其他API（默认格式）
            endpoint = "\(aiAPIEndpoint)/v1/completions"
            parameters = [
                "model": aiModelName,
                "prompt": prompt,
                "max_tokens": 2000,
                "temperature": 0.3
            ]
        }
        
        // 序列化请求参数
        guard let jsonData = try? JSONSerialization.data(withJSONObject: parameters) else {
            return
        }
        
        // 创建请求
        guard let url = URL(string: endpoint) else {
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("Bearer \(aiAPIKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData
        
        // 发送请求
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            
            // 处理错误
            if let error = error {
                print("AI分析请求失败: \(error.localizedDescription)")
                return
            }
            
            // 处理响应
            if let data = data {
                do {
                    if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        // 处理不同API的响应格式
                        if let choices = json["choices"] as? [[String: Any]] {
                            if let firstChoice = choices.first {
                                // 处理chat格式响应
                                if let message = firstChoice["message"] as? [String: Any],
                                   let content = message["content"] as? String {
                                    self.processAIResponse(content)
                                }
                                // 处理completion格式响应
                                else if let text = firstChoice["text"] as? String {
                                    self.processAIResponse(text)
                                }
                                // 处理火山方舟DeepSeek模型的推理过程
                                else if let _ = firstChoice["reasoning"] as? String,
                                        let message = firstChoice["message"] as? [String: Any],
                                        let content = message["content"] as? String {
                                    // 使用content作为主要响应
                                    self.processAIResponse(content)
                                }
                            }
                        }
                    }
                } catch {
                    print("无法解析AI分析响应: \(error.localizedDescription)")
                }
            }
        }
        
        task.resume()
    }
    
    /**
     * @method processAIResponse
     * @description 处理AI响应，提取JSON数据
     */
    private func processAIResponse(_ response: String) {
        // 尝试从响应中提取JSON
        let jsonPattern = "\\{[\\s\\S]*\\}"
        if let regex = try? NSRegularExpression(pattern: jsonPattern),
           let match = regex.firstMatch(in: response, range: NSRange(response.startIndex..., in: response)) {
            let jsonString = (response as NSString).substring(with: match.range)
            
            if let jsonData = jsonString.data(using: .utf8),
               let resultJSON = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                // 更新分析结果
                DispatchQueue.main.async {
                    // 保留之前的performanceScore，用于比较变化
                    let previousScore = self.aiAnalysisResults["performanceScore"] as? Int ?? 0
                    let newScore = resultJSON["performanceScore"] as? Int ?? 0
                    
                    // 更新结果
                    self.aiAnalysisResults = resultJSON
                    
                    // 如果分数有变化，可以在这里添加通知或其他反馈
                    if previousScore != newScore {
                        // 例如：显示分数变化的通知
                        if newScore > previousScore {
                            self.showNotification(title: "练习进步", body: "你的练习质量评分提高到了\(newScore)分！")
                        } else if newScore < previousScore {
                            self.showNotification(title: "练习提醒", body: "你的练习质量评分降低到了\(newScore)分，请检查练习方法。")
                        }
                    }
                }
            }
        } else {
            print("无法从响应中提取JSON数据")
        }
    }
    
    /**
     * @method showNotification
     * @description 显示本地通知
     */
    private func showNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = UNNotificationSound.default
        
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("无法发送通知: \(error.localizedDescription)")
            }
        }
    }
    
    /**
     * @method getAudioFeaturesForAnalysis
     * @description 获取当前音频特征用于分析
     */
    private func getAudioFeaturesForAnalysis() -> [String: String] {
        var features: [String: String] = [:]
        
        // 音量变化历史 - 收集最近20秒的音量变化，用于分析情感表达
        var volumeValues: [Float] = []
        let samples = audioMonitor.getRecentVolumeHistory(count: 20)
        if !samples.isEmpty {
            volumeValues = samples
        } else {
            volumeValues = (0..<20).map { _ in Float.random(in: -50 ... -10) }
        }
        features["volumeChanges"] = "[\(volumeValues.map { String($0) }.joined(separator: ", "))]"
        
        // 速度估计 (BPM变化) - 分析演奏速度的变化
        var tempoValues: [Int] = []
        let recentTempos = audioMonitor.getRecentTempoEstimates(count: 10)
        if !recentTempos.isEmpty {
            tempoValues = recentTempos
        } else {
            tempoValues = (0..<10).map { _ in Int.random(in: 60...120) }
        }
        features["tempoEstimates"] = "[\(tempoValues.map { String($0) }.joined(separator: ", "))]"
        
        // 强弱对比范围 - 分析情感表达
        var minVolume: Float = -50
        var maxVolume: Float = -10
        
        if !volumeValues.isEmpty {
            minVolume = volumeValues.min() ?? -50
            maxVolume = volumeValues.max() ?? -10
        }
        
        features["dynamicsRange"] = """
        { 
            "min": \(minVolume), 
            "max": \(maxVolume), 
            "range": \(maxVolume - minVolume),
            "variability": \(calculateVolumeVariability(volumes: volumeValues))
        }
        """
        
        return features
    }
    
    /**
     * @method calculateVolumeVariability
     * @description 计算音量变化的多样性指数
     */
    private func calculateVolumeVariability(volumes: [Float]) -> Float {
        guard volumes.count >= 2 else { return 0 }
        
        var changes: [Float] = []
        for i in 1..<volumes.count {
            changes.append(abs(volumes[i] - volumes[i-1]))
        }
        
        return changes.reduce(0, +) / Float(changes.count)
    }
    
    /**
     * @method sendMessageToAI
     * @description 发送消息到AI并获取回复
     */
    func sendMessageToAI(_ message: String, completion: @escaping (String) -> Void) {
        guard Self.aiFeaturesAvailable else { completion("AI 功能暂未开放"); return }
        // 检查API密钥和模型名称不为空
        guard !aiAPIKey.isEmpty, !aiModelName.isEmpty else {
            let reply = "请在设置中配置AI API密钥和模型名称"
            addAIMessageToHistory(reply)
            completion(reply)
            return
        }
        
        // 生成练琴上下文
        let context = generatePracticeContext()
        
        // 添加用户消息到历史
        addUserMessageToHistory(message)
        
        // 准备提示语
        let prompt = """
        你是一位专业的音乐练习助手，可以根据用户的练习记录和问题，给出专业的音乐练习建议。
        以下是用户的练习记录数据：

        \(context)

        请根据这些数据和用户的问题，给出专业、有帮助的建议。
        用户问题: \(message)
        """
        
        // 是否使用deepseek-reasoner模型
        let isReasonerModel = aiModelName.lowercased() == "deepseek-reasoner"
        
        // 是否为火山方舟模型
        let isVolcengineModel = aiAPIEndpoint.contains("volces.com")
        
        // 构建正确的API端点
        let endpoint: String
        if isVolcengineModel {
            endpoint = "\(aiAPIEndpoint.trimmingCharacters(in: .whitespaces))/api/v3/chat/completions"
        } else if isReasonerModel {
            endpoint = "\(aiAPIEndpoint.trimmingCharacters(in: .whitespaces))/chat/completions"
        } else {
            endpoint = "\(aiAPIEndpoint.trimmingCharacters(in: .whitespaces))/v1/chat/completions"
        }
        
        guard let url = URL(string: endpoint) else {
            let errorMessage = "无效的API端点地址: \(endpoint)"
            addAIMessageToHistory(errorMessage)
            completion(errorMessage)
            return
        }
        
        // 创建请求
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("Bearer \(aiAPIKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        // 准备请求参数
        let messagesArray: [[String: String]] = [
            ["role": "system", "content": "你是一位专业的音乐练习助手，可以提供有关音乐练习的专业建议。"],
            ["role": "user", "content": prompt]
        ]
        
        // 根据不同模型创建不同的请求体
        let requestBody: [String: Any]
        
        if isVolcengineModel && aiModelName.contains("deepseek") {
            // 火山方舟 DeepSeek-R1 模型 - 启用思考过程显示
            requestBody = [
                "model": aiModelName,
                "messages": messagesArray,
                "temperature": 0.7,
                "max_tokens": 2000,
                "top_p": 0.95,
                "frequency_penalty": 0.0,
                "presence_penalty": 0.0,
                "show_reasoning": true, // 启用思考过程显示
                "stream": false
            ]
        } else if isReasonerModel || isVolcengineModel {
            // 其他Chat格式模型
            requestBody = [
                "model": aiModelName,
                "messages": messagesArray,
                "temperature": 0.7,
                "max_tokens": 1000
            ]
        } else if aiAPIEndpoint.contains("siliconflow.cn") {
            // 硅基流动API
            requestBody = [
                "model": aiModelName,
                "messages": messagesArray,
                "temperature": 0.7,
                "max_tokens": 4000  // 增加token限制，确保DeepSeek返回完整回答
            ]
        } else {
            // 标准模型
            requestBody = [
                "model": aiModelName,
                "messages": messagesArray,
                "temperature": 0.7,
                "max_tokens": 1000
            ]
        }
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        } catch {
            let errorMessage = "请求创建失败: \(error.localizedDescription)"
            addAIMessageToHistory(errorMessage)
            completion(errorMessage)
            return
        }
        
        // 发送请求
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            
            DispatchQueue.main.async {
                if let error = error {
                    let errorMessage = "网络错误: \(error.localizedDescription)"
                    self.addAIMessageToHistory(errorMessage)
                    completion(errorMessage)
                    return
                }
                
                guard let data = data else {
                    let errorMessage = "无响应数据"
                    self.addAIMessageToHistory(errorMessage)
                    completion(errorMessage)
                    return
                }
                
                do {
                    // 解析响应
                    if let jsonResponse = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        if let errorInfo = jsonResponse["error"] as? [String: Any],
                           let errorMessage = errorInfo["message"] as? String {
                            self.addAIMessageToHistory("API错误: \(errorMessage)")
                            completion("API错误: \(errorMessage)")
                            return
                        }
                        
                        var aiResponse = ""
                        
                        // 根据不同的模型和API响应结构解析结果
                        if isReasonerModel || isVolcengineModel {
                            if let choices = jsonResponse["choices"] as? [[String: Any]],
                               let firstChoice = choices.first {
                                
                                // 获取基本回复内容
                                var responseContent = ""
                                if let message = firstChoice["message"] as? [String: Any],
                                   let content = message["content"] as? String {
                                    responseContent = content
                                }
                                
                                // 检查是否有推理过程（火山方舟专有）
                                if let reasoningText = firstChoice["reasoning"] as? String, !reasoningText.isEmpty {
                                    // 添加推理过程到回答前面
                                    aiResponse = "【思考过程】:\n\(reasoningText)\n\n【回答】:\n\(responseContent)"
                                } else {
                                    aiResponse = responseContent
                                }
                            }
                        } else {
                            if let choices = jsonResponse["choices"] as? [[String: Any]],
                               let firstChoice = choices.first,
                               let message = firstChoice["message"] as? [String: Any],
                               let content = message["content"] as? String {
                                aiResponse = content
                            }
                        }
                        
                        if aiResponse.isEmpty {
                            aiResponse = "无法解析AI回复"
                        }
                        
                        self.addAIMessageToHistory(aiResponse)
                        completion(aiResponse)
                    } else {
                        let errorMessage = "无法解析响应"
                        self.addAIMessageToHistory(errorMessage)
                        completion(errorMessage)
                    }
                } catch {
                    let errorMessage = "响应解析错误: \(error.localizedDescription)"
                    self.addAIMessageToHistory(errorMessage)
                    completion(errorMessage)
                }
            }
        }.resume()
    }
    
    /**
     * @method generatePracticeContext
     * @description 生成练琴数据上下文，用于AI助手提供针对性建议
     * @return 生成的上下文字符串
     */
    func generatePracticeContext() -> String {
        // 这个方法保持与原来的generatePracticeDataContext功能相同
        // 但做了命名简化以符合新的API设计
        
        // 统计数据
        let totalSessions = allSessions.count
        let totalPracticeTime = allSessions.reduce(0) { $0 + $1.totalFocusTime + $1.distractionTime }
        let totalFocusTime = allSessions.reduce(0) { $0 + $1.totalFocusTime }
        let averageFocusRate = totalPracticeTime > 0 ? (totalFocusTime / totalPracticeTime) * 100 : 0
        
        // 最近的练习会话
        let recentSessions = allSessions.sorted { $0.startTime > $1.startTime }.prefix(5)
        
        // 过去7天的练琴数据
        var weeklyStats = "过去7天的练琴情况:\n"
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        
        for dayOffset in 0..<7 {
            if let date = calendar.date(byAdding: .day, value: -dayOffset, to: today) {
                let sessionsForDate = getSessionsForDate(date)
                let focusTime = getTotalFocusTimeForDate(date)
                let distractionTime = getTotalDistractionTimeForDate(date)
                let totalTime = focusTime + distractionTime
                let dateFormatter = DateFormatter()
                dateFormatter.dateFormat = "MM/dd"
                let dateString = dateFormatter.string(from: date)
                
                if sessionsForDate.isEmpty {
                    weeklyStats += "- \(dateString): 未练习\n"
                } else {
                    let focusRate = totalTime > 0 ? (focusTime / totalTime) * 100 : 0
                    weeklyStats += "- \(dateString): 练习\(sessionsForDate.count)次, 总时长\(TimeFormatter.formatTimeInterval(totalTime)), 专注率\(String(format: "%.1f%%", focusRate))\n"
                }
            }
        }
        
        // 教师要求/课堂笔记
        var teacherNotesContext = ""
        if !teacherNotes.isEmpty {
            teacherNotesContext = "\n练琴笔记:\n"
            
            // 按重要性排序，未完成的排在前面
            let sortedNotes = teacherNotes.sorted {
                if $0.isCompleted != $1.isCompleted {
                    return !$0.isCompleted // 未完成的优先
                }
                return $0.importance > $1.importance // 然后按重要性
            }
            
            // 显示最近的5条记录
            for note in sortedNotes.prefix(5) {
                let importanceMarker = String(repeating: "★", count: note.importance)
                let statusMarker = note.isCompleted ? "[已完成]" : "[待练习]"
                teacherNotesContext += "- \(importanceMarker) \(note.title) \(statusMarker): \(note.content)\n"
            }
        }
        
        // 组合所有数据
        let context = """
        练习统计总览:
        - 总练习次数: \(totalSessions)次
        - 总练习时长: \(TimeFormatter.formatTimeInterval(totalPracticeTime))
        - 平均专注率: \(String(format: "%.1f%%", averageFocusRate))
        
        最近练习记录:
        \(recentSessions.map { session -> String in
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "MM/dd HH:mm"
            let startTimeString = dateFormatter.string(from: session.startTime)
            let focusRate = (session.totalFocusTime + session.distractionTime) > 0 ? 
                (session.totalFocusTime / (session.totalFocusTime + session.distractionTime)) * 100 : 0
            
            return "- \(startTimeString): 练习\(TimeFormatter.formatTimeInterval(session.totalFocusTime + session.distractionTime)), 专注率\(String(format: "%.1f%%", focusRate)), 分心\(session.distractions.count)次"
        }.joined(separator: "\n"))
        
        \(weeklyStats)
        \(teacherNotesContext)
        """
        
        return context
    }
    
    /**
     * @method addUserMessageToHistory
     * @description 将用户消息添加到对话历史
     * @param message 用户消息内容
     */
    private func addUserMessageToHistory(_ message: String) {
        let newMessage = Message(content: message, isFromUser: true)
        conversationHistory.append(newMessage)
        currentConversation.messages.append(newMessage)
        saveConversations()
    }
    
    /**
     * @method addAIMessageToHistory
     * @description 将AI回复添加到对话历史
     * @param message AI回复内容
     */
    private func addAIMessageToHistory(_ message: String) {
        let newMessage = Message(content: message, isFromUser: false)
        conversationHistory.append(newMessage)
        currentConversation.messages.append(newMessage)
        saveConversations()
    }
    
    /**
     * @method analyzeUserPracticePatterns
     * @description 分析用户练习模式并提供洞察
     * @return 包含练习模式分析的字符串
     */
    private func analyzeUserPracticePatterns() -> String {
        var analysis = "\n练习模式分析:\n"
        
        // 如果没有足够的会话数据，返回提示信息
        if allSessions.count < 3 {
            return analysis + "- 数据不足，需要更多练习记录来进行分析。\n"
        }
        
        // 计算最佳练习时段
        var hourDistribution: [Int: TimeInterval] = [:]
        
        for session in allSessions {
            let hour = Calendar.current.component(.hour, from: session.startTime)
            hourDistribution[hour, default: 0] += session.totalFocusTime
        }
        
        let bestHour = hourDistribution.max { $0.value < $1.value }?.key ?? 0
        let bestTimeRange = "\(bestHour):00-\(bestHour + 1):00"
        analysis += "- 最佳练习时段: \(bestTimeRange)\n"
        
        // 计算平均每次练习时长
        let totalFocusTime = allSessions.reduce(0) { $0 + $1.totalFocusTime }
        let averageSessionTime = totalFocusTime / Double(allSessions.count)
        analysis += "- 平均每次练习时长: \(TimeFormatter.formatTimeInterval(averageSessionTime))\n"
        
        // 计算连续练习的最长天数
        let sessionDays = Set(allSessions.map { Calendar.current.startOfDay(for: $0.startTime) })
        let sortedDays = sessionDays.sorted()
        
        var currentStreak = 1
        var longestStreak = 1
        
        for i in 1..<sortedDays.count {
            let previousDay = sortedDays[i-1]
            let currentDay = sortedDays[i]
            
            if let dayDifference = Calendar.current.dateComponents([.day], from: previousDay, to: currentDay).day, dayDifference == 1 {
                currentStreak += 1
                longestStreak = max(longestStreak, currentStreak)
            } else {
                currentStreak = 1
            }
        }
        
        analysis += "- 最长连续练习天数: \(longestStreak)天\n"
        
        // 检查最近的趋势
        if allSessions.count >= 5 {
            let recentSessions = Array(allSessions.sorted { $0.startTime > $1.startTime }.prefix(5))
            let newestOfRecent = recentSessions.first!
            
            let averageRecentFocusTime = recentSessions.reduce(0) { $0 + $1.totalFocusTime } / Double(recentSessions.count)
            
            if newestOfRecent.totalFocusTime > averageRecentFocusTime * 1.1 {
                analysis += "- 近期趋势: 练习时长有所增加\n"
            } else if newestOfRecent.totalFocusTime < averageRecentFocusTime * 0.9 {
                analysis += "- 近期趋势: 练习时长有所减少\n"
            } else {
                analysis += "- 近期趋势: 练习时长保持稳定\n"
            }
        }
        
        return analysis
    }
    
    /**
     * @method formatDateToWeekday
     * @description 将日期格式化为星期几
     * @param date 要格式化的日期
     * @return 格式化后的星期几字符串
     */
    private func formatDateToWeekday(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE" // 星期几的全称
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter.string(from: date)
    }
    
    /**
     * @method addMessageToHistory
     * @description 将消息添加到对话历史
     * @param content 消息内容
     * @param isFromUser 是否是用户发送的消息
     */
    func addMessageToHistory(content: String, isFromUser: Bool) {
        let message = Message(content: content, isFromUser: isFromUser)
        conversationHistory.append(message)
        
        // 更新当前对话
        currentConversation.messages = conversationHistory
        currentConversation.updatedAt = Date()
        
        // 如果是新对话且有足够的内容，自动生成标题
        if currentConversation.title == "新对话" && conversationHistory.count >= 2 {
            currentConversation.generateTitle()
        }
        
        // 限制历史记录长度，避免提示词过长
        if conversationHistory.count > 50 {
            conversationHistory.removeFirst(conversationHistory.count - 50)
        }
        
        // 自动保存当前对话
        saveCurrentConversation()
    }
    
    /**
     * @method saveCurrentConversation
     * @description 保存当前对话到持久化存储
     */
    func saveCurrentConversation() {
        // 如果当前对话为空，不保存
        if conversationHistory.isEmpty {
            return
        }
        
        // 更新当前对话
        currentConversation.messages = conversationHistory
        currentConversation.updatedAt = Date()
        
        // 如果当前对话没有标题，生成一个
        if currentConversation.title == "新对话" {
            currentConversation.generateTitle()
        }
        
        // 检查是否需要更新或新增
        if let index = savedConversations.firstIndex(where: { $0.id == currentConversation.id }) {
            // 更新已存在的对话
            savedConversations[index] = currentConversation
        } else {
            // 添加新对话
            savedConversations.append(currentConversation)
        }
        
        // 保存到持久化存储
        saveConversations()
    }
    
    /**
     * @method newConversation
     * @description 创建新对话
     */
    func newConversation() {
        // 保存当前对话
        saveCurrentConversation()
        
        // 创建新对话
        currentConversation = Conversation()
        conversationHistory = []
    }
    
    /**
     * @method loadConversation
     * @description 加载指定的对话
     * @param conversationId 要加载的对话ID
     */
    func loadConversation(conversationId: UUID) {
        // 保存当前对话
        saveCurrentConversation()
        
        // 加载指定对话
        if let conversation = savedConversations.first(where: { $0.id == conversationId }) {
            currentConversation = conversation
            conversationHistory = conversation.messages
        }
    }
    
    /**
     * @method deleteConversation
     * @description 删除指定的对话
     * @param conversationId 要删除的对话ID
     */
    func deleteConversation(conversationId: UUID) {
        savedConversations.removeAll(where: { $0.id == conversationId })
        
        // 如果删除的是当前对话，则创建新对话
        if currentConversation.id == conversationId {
            currentConversation = Conversation()
            conversationHistory = []
        }
        
        // 保存到持久化存储
        saveConversations()
    }
    
    /**
     * @method renameConversation
     * @description 重命名指定的对话
     * @param conversationId 要重命名的对话ID
     * @param newTitle 新标题
     */
    func renameConversation(conversationId: UUID, newTitle: String) {
        // 更新已保存的对话
        if let index = savedConversations.firstIndex(where: { $0.id == conversationId }) {
            savedConversations[index].title = newTitle
        }
        
        // 如果是当前对话，也更新当前对话
        if currentConversation.id == conversationId {
            currentConversation.title = newTitle
        }
        
        // 保存到持久化存储
        saveConversations()
    }
    
    /**
     * @method loadConversations
     * @description 从持久化存储加载所有对话
     */
    private func loadConversations() {
        if let data = historyDefaults.data(forKey: conversationsKey),
           let conversations = try? JSONDecoder().decode([Conversation].self, from: data) {
            savedConversations = conversations
            
            // 如果有对话，选择最近的一个作为当前对话
            if let mostRecent = conversations.sorted(by: { $0.updatedAt > $1.updatedAt }).first {
                currentConversation = mostRecent
            } else {
                currentConversation = Conversation()
            }
        }
    }
    
    /**
     * @method saveConversations
     * @description 保存所有对话到持久化存储
     */
    private func saveConversations() {
        if let data = try? JSONEncoder().encode(savedConversations) {
            historyDefaults.set(data, forKey: conversationsKey)
        }
    }
    
    /**
     * @method loadTeacherNotes
     * @description 从持久化存储加载教师笔记
     */
    private func loadTeacherNotes() {
        if let data = historyDefaults.data(forKey: teacherNotesKey),
           let notes = try? JSONDecoder().decode([TeacherNote].self, from: data) {
            teacherNotes = notes
        }
    }
    
    /**
     * @method saveTeacherNotes
     * @description 将教师笔记保存到持久存储
     * @public 允许外部调用，强制保存数据
     */
    func saveTeacherNotes() {
        if let data = try? JSONEncoder().encode(teacherNotes) {
            historyDefaults.set(data, forKey: teacherNotesKey)
            print("教师笔记数据已保存，包含 \(teacherNotes.count) 条笔记")
        } else {
            print("错误：无法编码教师笔记数据")
        }
    }
    
    /**
     * @method addTeacherNote
     * @description 添加新的教师笔记
     * @param title 笔记标题
     * @param content 笔记内容
     * @param importance 重要性等级(1-3)
     * @param autoAnalyze 是否自动分析(默认为false)
     * @return 新添加的笔记ID
     */
    func addTeacherNote(title: String, content: String, importance: Int = 1, autoAnalyze: Bool = false) -> UUID {
        let newNote = TeacherNote(
            title: title,
            content: content,
            date: Date(),
            importance: min(3, max(1, importance))
        )
        
        teacherNotes.append(newNote)
        saveTeacherNotes()
        
        // 如果启用了自动分析，则在后台进行分析
        if autoAnalyze && isAIAnalysisEnabled {
            updateTeacherNoteAnalysis(id: newNote.id)
        }
        
        return newNote.id
    }
    
    /**
     * @method updateTeacherNote
     * @description 更新教师笔记
     * @param id 笔记ID
     * @param title 笔记标题（可选）
     * @param content 笔记内容（可选）
     * @param importance 重要性（可选）
     * @param isCompleted 是否完成（可选）
     * @param metadata 元数据（可选）
     * @param aiAnalysisResult AI分析结果（可选）
     * @return 更新是否成功
     */
    func updateTeacherNote(id: UUID, title: String? = nil, content: String? = nil, importance: Int? = nil, isCompleted: Bool? = nil, metadata: [String: String]? = nil, aiAnalysisResult: String? = nil) -> Bool {
        if let index = teacherNotes.firstIndex(where: { $0.id == id }) {
            var note = teacherNotes[index]
            
            // 记录变化
            var changes: [String] = []
            if let title = title, title != note.title {
                changes.append("标题")
                note.title = title
            }
            if let content = content, content != note.content {
                changes.append("内容")
                print("更新笔记内容：旧长度 \(note.content.count) -> 新长度 \(content.count)")
                note.content = content
            }
            if let importance = importance, importance != note.importance {
                changes.append("重要性")
                note.importance = importance
            }
            if let isCompleted = isCompleted, isCompleted != note.isCompleted {
                changes.append(isCompleted ? "标记完成" : "标记未完成")
                note.isCompleted = isCompleted
            }
            if let metadata = metadata {
                changes.append("元数据")
                // 更新或添加元数据
                if note.metadata == nil {
                    note.metadata = metadata
                } else {
                    for (key, value) in metadata {
                        note.metadata?[key] = value
                        print("更新元数据: \(key) -> \(value.prefix(50))...")
                    }
                }
            }
            if let aiAnalysisResult = aiAnalysisResult {
                changes.append("AI分析结果")
                note.aiAnalysisResult = aiAnalysisResult
            }
            
            // 如果有变化，添加编辑记录
            if !changes.isEmpty {
                note.editHistory.append(TeacherNote.EditRecord(
                    date: Date(),
                    content: note.content,
                    changes: "修改了" + changes.joined(separator: "、")
                ))
                
                teacherNotes[index] = note
                saveTeacherNotes()
                
                // 检查更新是否成功
                print("成功更新笔记 \(id): \(changes.joined(separator: "、"))")
                return true
            } else {
                print("没有检测到笔记变化，跳过更新")
                return false
            }
        } else {
            print("未找到ID为 \(id) 的笔记")
            return false
        }
    }
    
    /**
     * @method deleteTeacherNote
     * @description 删除教师笔记
     * @param id 笔记ID
     */
    func deleteTeacherNote(id: UUID) {
        teacherNotes.removeAll(where: { $0.id == id })
        saveTeacherNotes()
    }
    
    /**
     * @method addTeacherNoteWithMedia
     * @description 添加带有媒体文件的教师笔记
     * @param title 笔记标题
     * @param content 笔记内容
     * @param mediaType 媒体类型
     * @param mediaURL 媒体文件URL
     * @param importance 重要性等级(1-3)
     */
    func addTeacherNoteWithMedia(title: String, content: String, mediaType: TeacherNote.MediaType, mediaURL: String, importance: Int = 1) {
        var newNote = TeacherNote(
            title: title,
            content: content,
            date: Date(),
            importance: min(3, max(1, importance))
        )
        
        // 添加媒体信息
        newNote.hasMedia = true
        newNote.mediaType = mediaType
        newNote.mediaURL = mediaURL
        
        teacherNotes.append(newNote)
        saveTeacherNotes()
    }
    
    /**
     * @method updateNoteWithTranscription
     * @description 更新笔记的转写内容
     * @param id 笔记ID
     * @param transcription 转写文本
     */
    func updateNoteWithTranscription(id: UUID, transcription: String) {
        if let index = teacherNotes.firstIndex(where: { $0.id == id }) {
            teacherNotes[index].transcription = transcription
            
            // 如果内容为空，使用转写的前100个字符作为内容概要
            if teacherNotes[index].content.isEmpty {
                let summary = String(transcription.prefix(100))
                teacherNotes[index].content = summary + (transcription.count > 100 ? "..." : "")
            }
            
            saveTeacherNotes()
        }
    }
    
    /**
     * @method extractKeyPointsFromTranscription
     * @description 从转写中提取要点并添加到笔记中
     * @param id 笔记ID
     * @return 提取的要点数组
     */
    func extractKeyPointsFromTranscription(id: UUID) -> [String] {
        // 在实际应用中，可能会调用AI API来提取要点
        // 这里使用简化的实现，根据标点符号和关键词提取
        
        guard let index = teacherNotes.firstIndex(where: { $0.id == id }),
              !teacherNotes[index].transcription.isEmpty else {
            return []
        }
        
        let transcription = teacherNotes[index].transcription
        
        // 简单的要点提取算法（在实际应用中可以使用NLP或AI）
        // 1. 按句子分割
        let sentences = transcription.components(separatedBy: [".", "。", "!", "！", "?", "？"])
                                    .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        
        // 2. 查找包含关键词的句子
        let keywordPatterns = ["注意", "重要", "要求", "请", "建议", "练习", "强调", "记得", "需要"]
        var keyPoints: [String] = []
        
        for sentence in sentences {
            let trimmedSentence = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            // 检查是否包含关键词
            if keywordPatterns.contains(where: { trimmedSentence.contains($0) }) && 
               trimmedSentence.count >= 5 && trimmedSentence.count <= 100 {
                keyPoints.append(trimmedSentence)
            }
        }
        
        // 如果提取的要点太少，直接取前几个句子
        if keyPoints.count < 3 && sentences.count > 0 {
            let additionalPoints = sentences.prefix(min(5, sentences.count))
                                  .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                                  .filter { !keyPoints.contains($0) && $0.count >= 5 && $0.count <= 100 }
            keyPoints.append(contentsOf: additionalPoints)
        }
        
        // 更新笔记中的要点
        if !keyPoints.isEmpty {
            teacherNotes[index].keyPoints = keyPoints
            saveTeacherNotes()
        }
        
        return keyPoints
    }
    
    /**
     * @method generateTeacherNoteFromTranscription
     * @description 根据转写内容自动生成教师要求笔记
     * @param id 笔记ID
     * @return 是否成功更新
     */
    func generateTeacherNoteFromTranscription(id: UUID) -> Bool {
        guard let index = teacherNotes.firstIndex(where: { $0.id == id }),
              !teacherNotes[index].transcription.isEmpty else {
            return false
        }
        
        // 提取要点
        let keyPoints = extractKeyPointsFromTranscription(id: id)
        if keyPoints.isEmpty {
            return false
        }
        
        // 使用要点生成更好的内容
        let formattedContent = keyPoints.enumerated().map { index, point in
            return "• \(point)"
        }.joined(separator: "\n")
        
        // 更新笔记内容
        teacherNotes[index].content = formattedContent
        
        // 如果标题为空，使用第一个要点作为标题
        if teacherNotes[index].title.isEmpty && !keyPoints.isEmpty {
            let firstPoint = keyPoints[0]
            let titleLength = min(firstPoint.count, 30)
            teacherNotes[index].title = String(firstPoint.prefix(titleLength)) + (firstPoint.count > titleLength ? "..." : "")
        }
        
        saveTeacherNotes()
        return true
    }
    
    /**
     * @method showReminderNotification
     * @description 显示提醒通知，带有特定的标识符
     */
    private func showReminderNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = UNNotificationSound.default
        
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: "musicInterruption", content: content, trigger: trigger)
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("显示通知失败: \(error.localizedDescription)")
            }
        }
    }
    
    /**
     * @method handleMusicConfirmed
     * @description 处理音乐确认通知
     */
    @objc private func handleMusicConfirmed(_ notification: Notification) {
        // AudioMonitor posts on the main thread. Keep timing changes here;
        // views must not install duplicate observers or alter session accounting.
        guard isActive, !isManuallyPaused, !isReviewingVoiceNote, audioMonitor.isPlayingMusic else { return }
        endDistraction(at: notification.userInfo?["date"] as? Date ?? Date())
    }
    
    /**
     * @method handleMusicStopped
     * @description 处理音乐停止通知（包括正常中断和噪音阀触发）
     */
    @objc private func handleMusicStopped(_ notification: Notification) {
        guard isActive, !isManuallyPaused, !isReviewingVoiceNote, !audioMonitor.isPlayingMusic else { return }
        startDistraction(description: "未检测到练习声音", at: notification.userInfo?["date"] as? Date ?? Date())
    }

    // 用户是否已登录
    func isLoggedIn() -> Bool {
        return currentUser != nil
    }
    
    // 用户登录
    func login(username: String, password: String) -> Bool {
        // 在实际应用中，这里应该进行真正的身份验证
        // 简单演示实现
        let savedData = UserDefaults.standard.data(forKey: userAccountKey)
        if let data = savedData,
           let savedAccount = try? JSONDecoder().decode(UserAccount.self, from: data),
           savedAccount.username == username,
           savedAccount.password == password {
            var updatedAccount = savedAccount
            updatedAccount.lastLogin = Date()
            currentAccount = updatedAccount
            
            // 保存更新后的账户信息
            if let encodedData = try? JSONEncoder().encode(updatedAccount) {
                UserDefaults.standard.set(encodedData, forKey: userAccountKey)
            }
            
            return true
        }
        return false
    }
    
    // 创建新账户
    func createAccount(username: String, password: String, email: String? = nil) -> Bool {
        // 检查用户名是否已存在
        let savedData = UserDefaults.standard.data(forKey: userAccountKey)
        if let data = savedData,
           let savedAccount = try? JSONDecoder().decode(UserAccount.self, from: data),
           savedAccount.username == username {
            return false // 用户名已存在
        }
        
        // 创建新账户
        let newAccount = UserAccount(username: username, password: password, email: email)
        currentAccount = newAccount
        
        // 保存账户信息
        if let encodedData = try? JSONEncoder().encode(newAccount) {
            UserDefaults.standard.set(encodedData, forKey: userAccountKey)
            return true
        }
        
        return false
    }
    
    // 加载用户账户信息
    private func loadUserAccount() {
        if let data = UserDefaults.standard.data(forKey: userAccountKey),
           let savedAccount = try? JSONDecoder().decode(UserAccount.self, from: data) {
            currentAccount = savedAccount
        }
    }
    
    // 登出
    func logout() {
        currentAccount = nil
        KeychainWrapper.standard.removeObject(forKey: tokenKey)
        UserDefaults.standard.removeObject(forKey: userKey)
    }
    
    /// Rebuild only on history/date/time-zone changes, never on audio-meter ticks.
    @objc func refreshPracticeStatistics() {
        let updated = PracticeStatistics(sessions: allSessions,
            calendar: statisticsCalendarOverride ?? .current, asOf: statisticsClock())
        if !historyReadFailed { badgeManager.reconcile(with: updated) }
        practiceStatistics = updated
    }

    func updateHistoricalBadges() {
        refreshPracticeStatistics()
    }

    /**
     * 保存认证数据
     * @param authData 认证响应数据
     */
    func saveAuthData(_ authData: AuthData) {
        self.currentUser = authData.user
        
        // 保存 token 到钥匙串
        KeychainWrapper.standard.set(authData.token, forKey: tokenKey)
        
        // 保存用户信息到 UserDefaults
        if let userData = try? JSONEncoder().encode(authData.user) {
            UserDefaults.standard.set(userData, forKey: userKey)
        }
    }
    
    /**
     * 获取保存的 token
     * @return 认证 token
     */
    func getToken() -> String? {
        return KeychainWrapper.standard.string(forKey: tokenKey)
    }
    
    /**
     * @method updateTeacherNoteAnalysis
     * @description 在后台更新教师笔记的AI分析结果
     * @param id 笔记ID
     */
    func updateTeacherNoteAnalysis(id: UUID) {
        guard isAIAnalysisEnabled else { return }
        
        // 获取笔记
        guard let index = teacherNotes.firstIndex(where: { $0.id == id }) else { return }
        
        // 更新分析状态
        teacherNotes[index].isAnalyzing = true
        teacherNotesAnalyzing.insert(id)
        objectWillChange.send()
        
        // 构建分析消息
        var messageToAI = "我是一名音乐学习者，我的老师给了我以下要求，请帮我分析这些要求，并提供一些思考和学习建议：\n\n"
        messageToAI += "\(teacherNotes[index].title)\n\n"
        
        // 添加要点内容
        messageToAI += teacherNotes[index].content
        
        // 发送消息给AI进行分析，并在后台更新笔记
        sendMessageToAI(messageToAI) { [weak self] response in
            guard let self = self else { return }
            
            // 更新分析结果
            if let noteIndex = self.teacherNotes.firstIndex(where: { $0.id == id }) {
                self.teacherNotes[noteIndex].aiAnalysisResult = response
                self.teacherNotes[noteIndex].isAnalyzing = false
                self.teacherNotesAnalyzing.remove(id)
                self.objectWillChange.send()
                self.saveTeacherNotes()
            }
        }
    }
    
    /**
     * @method toggleAutoRefreshAnalysis
     * @description 切换指定笔记的自动刷新分析状态
     * @param id 笔记ID
     * @param autoRefresh 是否自动刷新(可选)
     */
    func toggleAutoRefreshAnalysis(id: UUID, autoRefresh: Bool? = nil) {
        if let index = teacherNotes.firstIndex(where: { $0.id == id }) {
            if let autoRefresh = autoRefresh {
                teacherNotes[index].autoRefreshAnalysis = autoRefresh
            } else {
                teacherNotes[index].autoRefreshAnalysis = !teacherNotes[index].autoRefreshAnalysis
            }
            
            // 如果开启了自动刷新且AI分析内容为空，立即开始分析
            if teacherNotes[index].autoRefreshAnalysis && 
               teacherNotes[index].aiAnalysisResult.isEmpty && 
               !teacherNotes[index].isAnalyzing {
                updateTeacherNoteAnalysis(id: id)
            }
            
            saveTeacherNotes()
        }
    }
    
    /**
     * @method addScoreFileToNote
     * @description 向教师笔记中添加乐谱文件
     * @param id 笔记ID
     * @param fileName 文件名
     * @param fileURL 文件URL路径
     * @param fileType 文件类型
     * @param description 文件描述
     * @return 是否成功添加
     */
    func addScoreFileToNote(id: UUID, fileName: String, fileURL: String, fileType: TeacherNote.MediaType, description: String = "") -> Bool {
        if let index = teacherNotes.firstIndex(where: { $0.id == id }) {
            let newScoreFile = TeacherNote.ScoreFile(
                fileName: fileName,
                fileURL: fileURL,
                fileType: fileType,
                uploadDate: Date(),
                description: description
            )
            
            // 添加乐谱文件
            teacherNotes[index].scoreFiles.append(newScoreFile)
            teacherNotes[index].hasScoreFiles = true
            
            // 记录编辑历史
            teacherNotes[index].editHistory.append(TeacherNote.EditRecord(
                date: Date(),
                content: teacherNotes[index].content,
                changes: "添加了乐谱文件：\(fileName)"
            ))
            
            saveTeacherNotes()
            return true
        }
        return false
    }
    
    /**
     * @method removeScoreFileFromNote
     * @description 从教师笔记中删除指定的乐谱文件
     * @param noteId 笔记ID
     * @param fileId 乐谱文件ID
     * @return 是否成功删除
     */
    func removeScoreFileFromNote(noteId: UUID, fileId: UUID) -> Bool {
        if let noteIndex = teacherNotes.firstIndex(where: { $0.id == noteId }) {
            teacherNotes[noteIndex].scoreFiles.removeAll { $0.id == fileId }
            
            // 如果没有乐谱文件了，更新hasScoreFiles标志
            if teacherNotes[noteIndex].scoreFiles.isEmpty {
                teacherNotes[noteIndex].hasScoreFiles = false
            }
            
            // 记录编辑历史
            teacherNotes[noteIndex].editHistory.append(TeacherNote.EditRecord(
                date: Date(),
                content: teacherNotes[noteIndex].content,
                changes: "删除了乐谱文件"
            ))
            
            saveTeacherNotes()
            return true
        }
        return false
    }
    
    /**
     * @method updateScoreFileNotes
     * @description 更新指定笔记中指定文件的笔记内容
     * @param noteId 笔记ID
     * @param fileId 文件ID
     * @param notes 笔记内容
     * @return 是否成功更新
     */
    func updateScoreFileNotes(noteId: UUID, fileId: UUID, notes: String) -> Bool {
        if let noteIndex = teacherNotes.firstIndex(where: { $0.id == noteId }),
           let fileIndex = teacherNotes[noteIndex].scoreFiles.firstIndex(where: { $0.id == fileId }) {
            
            // 更新文件描述（用作笔记）
            teacherNotes[noteIndex].scoreFiles[fileIndex].description = notes
            
            // 记录编辑历史
            teacherNotes[noteIndex].editHistory.append(TeacherNote.EditRecord(
                date: Date(),
                content: teacherNotes[noteIndex].content,
                changes: "更新了视频笔记"
            ))
            
            saveTeacherNotes()
            return true
        }
        return false
    }
} 
