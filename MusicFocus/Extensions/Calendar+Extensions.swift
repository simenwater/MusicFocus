import Foundation

/**
 * @extension Calendar
 * @description Calendar扩展，添加获取一天结束时间的方法
 */
extension Calendar {
    func endOfDay(for date: Date) -> Date {
        var components = DateComponents()
        components.day = 1
        components.second = -1
        return self.date(byAdding: components, to: startOfDay(for: date))!
    }
} 