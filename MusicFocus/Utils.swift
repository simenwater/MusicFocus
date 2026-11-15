//
//  Utils.swift
//  MusicFocus
//
//  Created by 姜伯龙 on 2025/3/7.
//

import Foundation

/**
 * @class TimeFormatter
 * @description 时间格式化工具
 */
struct TimeFormatter {
    /**
     * @method formatTimeInterval
     * @description 将时间间隔格式化为可读的字符串
     * @param interval 时间间隔（秒）
     * @return 格式化后的时间字符串（例如：1小时23分钟 / 1h 23m）
     */
    static func formatTimeInterval(_ interval: TimeInterval) -> String {
        let hours = Int(interval) / 3600
        let minutes = Int(interval) % 3600 / 60
        let seconds = Int(interval) % 60

        if hours > 0 {
            return "duration.hoursMinutes".localizedFormat(hours, minutes)
        } else if minutes > 0 {
            return "duration.minutesSeconds".localizedFormat(minutes, seconds)
        } else {
            return "duration.seconds".localizedFormat(seconds)
        }
    }
    
    /**
     * @method formatTimeIntervalShort
     * @description 将时间间隔格式化为简短可读的字符串
     * @param interval 时间间隔（秒）
     * @return 格式化后的简短时间字符串（例如：1h 23m / 1小时23分）
     */
    static func formatTimeIntervalShort(_ interval: TimeInterval) -> String {
        let hours = Int(interval) / 3600
        let minutes = Int(interval) % 3600 / 60
        let seconds = Int(interval) % 60

        if hours > 0 {
            return "duration.shortHoursMinutes".localizedFormat(hours, minutes)
        } else if minutes > 0 {
            return "duration.shortMinutesSeconds".localizedFormat(minutes, seconds)
        } else {
            return "duration.seconds".localizedFormat(seconds)
        }
    }
    
    static func formatBadgeRange(_ range: ClosedRange<Double>) -> String {
        func label(_ totalMinutes: Double) -> String {
            let hours = Int(totalMinutes) / 60
            let minutes = Int(totalMinutes) % 60
            if hours == 0 { return "duration.minutes".localizedFormat(minutes) }
            if minutes == 0 { return "duration.hours".localizedFormat(hours) }
            return "duration.hoursMinutes".localizedFormat(hours, minutes)
        }
        let lower = label(range.lowerBound)
        guard range.upperBound.isFinite else { return "badge.rangeAtLeast".localizedFormat(lower) }
        return "badge.rangeBelow".localizedFormat(lower, label(range.upperBound))
    }

    /**
     * @method formatTime
     * @description 将Date格式化为时间字符串
     * @param date 需要格式化的日期
     * @return 格式化后的时间字符串（例如：14:30）
     */
    static func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = AppLocalization.locale
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
    
    /**
     * @method formatDate
     * @description 将Date格式化为日期字符串
     * @param date 需要格式化的日期
     * @return 格式化后的日期字符串（例如：2025年3月7日 / Mar 7, 2025）
     */
    static func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.locale = AppLocalization.locale
        return formatter.string(from: date)
    }
    
    /**
     * @method dateRange
     * @description 获取日期的开始和结束时间
     * @param date 需要处理的日期
     * @return 包含日期开始和结束时间的元组
     */
    static func dateRange(for date: Date) -> (start: Date, end: Date) {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!.addingTimeInterval(-1)
        return (startOfDay, endOfDay)
    }
}
