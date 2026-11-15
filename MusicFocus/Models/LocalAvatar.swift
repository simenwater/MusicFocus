//
//  LocalAvatar.swift
//  MusicFocus
//
//  本地虚拟形象系统（无需网络）
//

import SwiftUI

/**
 * @struct LocalAvatar
 * @description 本地虚拟形象数据模型
 */
struct LocalAvatar: Identifiable, Codable, Equatable {
    let id: String
    let displayName: String
    let iconName: String  // SF Symbols图标名
    let backgroundColor: String  // 背景色
    let category: AvatarCategory

    enum AvatarCategory: String, Codable, CaseIterable {
        case musician = "音乐家"
        case performer = "表演者"
        case composer = "作曲家"
        case conductor = "指挥家"
        case student = "学生"
    }

    // 预设头像库
    static let presets: [LocalAvatar] = [
        // 音乐家系列
        LocalAvatar(id: "musician_1", displayName: "钢琴大师", iconName: "piano", backgroundColor: "blue", category: .musician),
        LocalAvatar(id: "musician_2", displayName: "吉他手", iconName: "guitars", backgroundColor: "orange", category: .musician),
        LocalAvatar(id: "musician_3", displayName: "小提琴家", iconName: "music.note", backgroundColor: "purple", category: .musician),
        LocalAvatar(id: "musician_4", displayName: "萨克斯演奏家", iconName: "music.mic", backgroundColor: "red", category: .musician),

        // 表演者系列
        LocalAvatar(id: "performer_1", displayName: "摇滚之星", iconName: "star.fill", backgroundColor: "black", category: .performer),
        LocalAvatar(id: "performer_2", displayName: "爵士乐手", iconName: "music.quarternote.3", backgroundColor: "brown", category: .performer),
        LocalAvatar(id: "performer_3", displayName: "古典演奏家", iconName: "music.note.list", backgroundColor: "indigo", category: .performer),

        // 作曲家系列
        LocalAvatar(id: "composer_1", displayName: "作曲大师", iconName: "pencil.and.list.clipboard", backgroundColor: "green", category: .composer),
        LocalAvatar(id: "composer_2", displayName: "编曲师", iconName: "waveform", backgroundColor: "teal", category: .composer),

        // 指挥家系列
        LocalAvatar(id: "conductor_1", displayName: "交响乐指挥", iconName: "wand.and.stars", backgroundColor: "yellow", category: .conductor),

        // 学生系列
        LocalAvatar(id: "student_1", displayName: "练习生", iconName: "person.fill", backgroundColor: "gray", category: .student),
        LocalAvatar(id: "student_2", displayName: "音乐学徒", iconName: "graduationcap.fill", backgroundColor: "cyan", category: .student),
    ]

    // 根据勋章等级推荐头像
    static func recommendedForBadge(_ level: BadgeLevel) -> LocalAvatar {
        switch level {
        case .bronze:
            return presets[10]  // 练习生
        case .silver:
            return presets[11]  // 音乐学徒
        case .gold:
            return presets[0]   // 钢琴大师
        case .platinum:
            return presets[6]   // 古典演奏家
        case .diamond:
            return presets[4]   // 摇滚之星
        case .master:
            return presets[7]   // 作曲大师
        case .king:
            return presets[9]   // 交响乐指挥
        }
    }

    // 获取颜色
    var color: Color {
        switch backgroundColor {
        case "blue": return .blue
        case "orange": return .orange
        case "purple": return .purple
        case "red": return .red
        case "black": return .black
        case "brown": return .brown
        case "indigo": return .indigo
        case "green": return .green
        case "teal": return .teal
        case "yellow": return .yellow
        case "gray": return .gray
        case "cyan": return .cyan
        default: return .blue
        }
    }
}

/**
 * @class LocalAvatarManager
 * @description 本地头像管理器
 */
class LocalAvatarManager: ObservableObject {
    @Published var currentAvatar: LocalAvatar

    private let avatarKey = "com.musicfocus.localavatar"

    init() {
        // 从本地加载已保存的头像
        if let data = UserDefaults.standard.data(forKey: avatarKey),
           let avatar = try? JSONDecoder().decode(LocalAvatar.self, from: data) {
            self.currentAvatar = avatar
        } else {
            // 默认头像
            self.currentAvatar = LocalAvatar.presets[10]  // 练习生
        }
    }

    // 保存头像
    func saveAvatar(_ avatar: LocalAvatar) {
        currentAvatar = avatar
        if let data = try? JSONEncoder().encode(avatar) {
            UserDefaults.standard.set(data, forKey: avatarKey)
        }
    }

    // 根据最高勋章自动推荐头像
    func autoSelectByHighestBadge(_ badges: [Badge]) {
        guard let highest = badges.max(by: { $0.level.timeRange.lowerBound < $1.level.timeRange.lowerBound }) else {
            return
        }

        let recommended = LocalAvatar.recommendedForBadge(highest.level)
        saveAvatar(recommended)
    }
}
