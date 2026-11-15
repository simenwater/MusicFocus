import Foundation

/**
 * @struct Student
 * @description 学生模型
 */
struct Student: Identifiable, Codable {
    let id: String
    let name: String
    let email: String
    var weeklyPracticeDays: Int
    var weeklyPracticeTime: TimeInterval
    var weeklyFocusRate: Double
    var practiceRecords: [FocusSession]
    var lastPracticeDate: Date?
    
    // 计算属性：本周练习记录
    var weeklyRecords: [FocusSession] {
        let calendar = Calendar.current
        let weekStart = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date()))!
        return practiceRecords.filter { session in
            calendar.isDate(session.startTime, equalTo: weekStart, toGranularity: .weekOfYear)
        }
    }
    
    // 计算属性：本月练习记录
    var monthlyRecords: [FocusSession] {
        let calendar = Calendar.current
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: Date()))!
        return practiceRecords.filter { session in
            calendar.isDate(session.startTime, equalTo: monthStart, toGranularity: .month)
        }
    }
} 