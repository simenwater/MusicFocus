//
//  String+Localization.swift
//  MusicFocus
//
//  Created for internationalization support
//  支持中英双语国际化
//

import Foundation

enum AppLocalization {
    /// Follow the language selected by iOS, including an app-specific language.
    /// Keep the user's region; this only affects presentation, never day boundaries.
    static var locale: Locale { locale(for: Bundle.main, region: Locale.autoupdatingCurrent.region?.identifier) }

    static func locale(for bundle: Bundle, region: String?) -> Locale {
        let language = bundle.preferredLocalizations.first ?? "en"
        return Locale(identifier: language + (region.map { "_" + $0 } ?? ""))
    }
}

extension String {
    /// 返回本地化的字符串
    /// Returns localized string based on system language
    var localized: String {
        return NSLocalizedString(self, bundle: .main, comment: "")
    }

    /// 返回带参数的本地化字符串
    /// Returns localized string with arguments
    /// - Parameter arguments: 格式化参数 / Format arguments
    /// - Returns: 本地化后的字符串 / Localized formatted string
    func localizedFormat(_ arguments: CVarArg...) -> String {
        let format = self.localized
        // 使用withVaList来正确处理可变参数
        return withVaList(arguments) { (pointer) -> String in
            return NSString(format: format, locale: AppLocalization.locale as NSLocale, arguments: pointer) as String
        }
    }

    /// 返回本地化字符串，带注释
    /// Returns localized string with custom comment
    /// - Parameter comment: 注释，帮助翻译理解上下文 / Comment for translation context
    /// - Returns: 本地化字符串 / Localized string
    func localized(comment: String) -> String {
        return NSLocalizedString(self, bundle: .main, comment: comment)
    }
}

// MARK: - Common Localization Keys
// 常用本地化键，避免拼写错误 / Common keys to avoid typos

extension String {
    // MARK: - Navigation
    static let focusTimer = "Focus Timer"
    static let practiceRecord = "Practice Record"
    static let statistics = "Statistics"
    static let settings = "Settings"

    // MARK: - Actions
    static let start = "Start"
    static let stop = "Stop"
    static let pause = "Pause"
    static let resume = "Resume"
    static let save = "Save"
    static let cancel = "Cancel"
    static let confirm = "Confirm"
    static let delete = "Delete"

    // MARK: - Status
    static let focused = "Focused"
    static let distracted = "Distracted"
    static let musicDetected = "Music Detected"
    static let noMusicDetected = "No Music Detected"
}
