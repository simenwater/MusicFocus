import Foundation

/**
 * @enum BadgeLevel
 * @description 勋章等级枚举
 */
enum BadgeLevel: String, CaseIterable, Codable {
    case bronze
    case silver
    case gold
    case platinum
    case diamond
    case master
    case king

    /**
     * @property displayName
     * @description 勋章显示名称（本地化）
     */
    var displayName: String {
        switch self {
        case .bronze: return "Bronze Badge".localized
        case .silver: return "Silver Badge".localized
        case .gold: return "Gold Badge".localized
        case .platinum: return "Platinum Badge".localized
        case .diamond: return "Diamond Badge".localized
        case .master: return "Master Badge".localized
        case .king: return "King Badge".localized
        }
    }

    /**
     * @property iconName
     * @description 勋章图标名称
     */
    var iconName: String {
        switch self {
        case .bronze: return "medal.fill"
        case .silver: return "medal.fill"
        case .gold: return "medal.fill"
        case .platinum: return "medal.fill"
        case .diamond: return "medal.fill"
        case .master: return "medal.fill"
        case .king: return "medal.fill"
        }
    }

    /**
     * @property color
     * @description 勋章颜色
     */
    var color: String {
        switch self {
        case .bronze: return "bronze"
        case .silver: return "silver"
        case .gold: return "gold"
        case .platinum: return "platinum"
        case .diamond: return "diamond"
        case .master: return "master"
        case .king: return "king"
        }
    }

    /**
     * @property timeRange
     * @description 勋章门槛（分钟），达到上界时升级到下一等级
     */
    var timeRange: ClosedRange<Double> {
        switch self {
        case .bronze: return 30...60
        case .silver: return 60...90
        case .gold: return 90...120
        case .platinum: return 120...180
        case .diamond: return 180...240
        case .master: return 240...360
        case .king: return 360...Double.infinity
        }
    }
}

/**
 * @struct Badge
 * @description 勋章数据结构
 */
struct Badge: Identifiable, Codable, Equatable {
    let id: UUID
    let level: BadgeLevel
    let date: Date
    
    init(level: BadgeLevel, date: Date = Date()) {
        self.id = UUID()
        self.level = level
        self.date = date
    }
    
    // 添加编码和解码方法
    enum CodingKeys: String, CodingKey {
        case id
        case level
        case date
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        level = try container.decode(BadgeLevel.self, forKey: .level)
        date = try container.decode(Date.self, forKey: .date)
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(level, forKey: .level)
        try container.encode(date, forKey: .date)
    }
}

/**
 * @struct BadgeManager
 * @description 勋章管理器
 */
class BadgeManager: ObservableObject {
    @Published private(set) var badges: [Badge] = [] {
        didSet {
            saveBadges()
        }
    }
    
    private let badgesKey = "com.musicfocus.badges"
    private let defaults: UserDefaults
    
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        loadBadges()
    }
    
    /**
     * @method calculateBadge
     * @description 根据练习时长计算勋章等级
     * @param practiceTime 练习时长（分钟）
     * @return 勋章等级
     */
    func calculateBadge(practiceTime: Double) -> BadgeLevel? {
        guard practiceTime.isFinite else { return nil }
        return BadgeLevel.allCases.reversed().first { practiceTime >= $0.timeRange.lowerBound }
    }

    /// Awards are derived from the same per-day totals as the charts. Rebuilding
    /// also removes or downgrades awards after edits/deletion, without changing stable IDs.
    func reconcile(with statistics: PracticeStatistics) {
        var existing: [Date: Badge] = [:]
        for badge in badges {
            existing[statistics.calendar.startOfDay(for: badge.date)] = badge
        }
        let updated = statistics.days.keys.sorted().compactMap { date -> Badge? in
            guard let day = statistics.days[date],
                  let level = calculateBadge(practiceTime: day.focusTime / 60) else { return nil }
            if let badge = existing[date], badge.level == level { return badge }
            return Badge(level: level, date: date)
        }
        if updated != badges { badges = updated }
    }
    
    /**
     * @method addBadge
     * @description 添加新勋章
     * @param badge 勋章对象
     */
    func addBadge(_ badge: Badge) {
        // 检查同一天是否已有勋章
        let calendar = Calendar.current
        let existingBadgeIndex = badges.firstIndex { existingBadge in
            calendar.isDate(existingBadge.date, inSameDayAs: badge.date)
        }
        
        if let index = existingBadgeIndex {
            // 如果已有勋章，且新勋章等级更高，则更新
            if badge.level.timeRange.upperBound > badges[index].level.timeRange.upperBound {
                badges[index] = badge
            }
        } else {
            badges.append(badge)
        }
    }
    
    /**
     * @method getBadgeForDate
     * @description 获取指定日期的勋章
     * @param date 日期
     * @return 勋章对象（如果有）
     */
    func getBadgeForDate(_ date: Date) -> Badge? {
        let calendar = Calendar.current
        return badges.first { calendar.isDate($0.date, inSameDayAs: date) }
    }
    
    /**
     * @method saveBadges
     * @description 保存勋章数据到本地存储
     */
    private func saveBadges() {
        if let encoded = try? JSONEncoder().encode(badges) {
            defaults.set(encoded, forKey: badgesKey)
        }
    }
    
    /**
     * @method loadBadges
     * @description 从本地存储加载勋章数据
     */
    private func loadBadges() {
        if let data = defaults.data(forKey: badgesKey),
           let decoded = try? JSONDecoder().decode([Badge].self, from: data) {
            badges = decoded
        }
    }
}
