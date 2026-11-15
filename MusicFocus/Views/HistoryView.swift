//
//  HistoryView.swift
//  MusicFocus
//
//  Created by 姜伯龙 on 2025/3/7.
//

import SwiftUI

/**
 * @struct SessionListItem
 * @description 会话列表项视图
 */
struct SessionListItem: View {
    let session: FocusSession
    var accountingDay: Date? = nil
    @EnvironmentObject private var focusManager: FocusManager

    private var dayInterval: DateInterval? {
        accountingDay.flatMap { focusManager.practiceStatistics.calendar.dateInterval(of: .day, for: $0) }
    }
    private var totals: (focus: TimeInterval, pause: TimeInterval) {
        PracticeTimeAccounting.totals(session, in: dayInterval)
    }
    private var displayedStart: Date { max(session.startTime, dayInterval?.start ?? session.startTime) }
    private var displayedEnd: Date? {
        session.endTime.map { min($0, dayInterval?.end ?? $0) }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(TimeFormatter.formatTime(displayedStart)) - \(displayedEnd != nil ? TimeFormatter.formatTime(displayedEnd!) : "In Progress".localized)")
                    .font(.headline)
                Spacer()
                Text("Total time: %@".localizedFormat(TimeFormatter.formatTimeInterval(totals.focus + totals.pause)))
                    .font(.subheadline)
            }
            
            HStack {
                Text("Focus: %@".localizedFormat(TimeFormatter.formatTimeInterval(totals.focus)))
                    .foregroundColor(.green)
                Spacer()
                Text("Paused: %@".localizedFormat(TimeFormatter.formatTimeInterval(totals.pause)))
                    .foregroundColor(.red)
            }
            
            // 显示练习曲目
            if let practiceContent = session.practiceContent, !practiceContent.pieceName.isEmpty {
                HStack {
                    Image(systemName: "music.note")
                        .foregroundColor(.blue)
                    Text("Piece: %@".localizedFormat(practiceContent.pieceName))
                        .font(.subheadline)
                        .foregroundColor(.blue)
                }
                .padding(.top, 4)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(10)
    }
}

/**
 * @struct DistractionListItem
 * @description 分心记录列表项视图
 */
struct DistractionListItem: View {
    let distraction: Distraction
    
    // 根据分心描述获取图标
    private var iconName: String {
        if distraction.description == DistractionType.appSwitch.rawValue {
            return "iphone.and.arrow.forward"
        } else if distraction.description == DistractionType.silence.rawValue || distraction.description == "未检测到练习声音" {
            return "speaker.slash"
        } else if distraction.description == "practice.manualPause" {
            return "pause.circle"
        } else if distraction.description == DistractionType.manual.rawValue {
            return "hand.raised"
        } else {
            return "questionmark.circle"
        }
    }
    
    var body: some View {
        HStack {
            Image(systemName: iconName)
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
            
            VStack(alignment: .leading) {
                Text("\(TimeFormatter.formatTime(distraction.startTime)) - \(distraction.endTime != nil ? TimeFormatter.formatTime(distraction.endTime!) : "In Progress".localized)")
                    .font(.subheadline)
                Text(distraction.description.localized)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Text("\(TimeFormatter.formatTimeInterval(distraction.duration))")
                .foregroundColor(.red)
        }
        .padding(.vertical, 8)
    }
}

/**
 * @struct SessionDetailView
 * @description 会话详情视图
 */
struct SessionDetailView: View {
    let session: FocusSession
    @State private var isEditing = false
    @State private var editedPieceName = ""
    @State private var editedImprovements = ""
    @State private var editedNotes = ""
    @EnvironmentObject var focusManager: FocusManager
    @Environment(\.dismiss) private var dismiss
    
    // 计算分心类型统计
    private var distractionStats: [(type: String, count: Int, duration: TimeInterval)] {
        let types = session.distractions.map { $0.description }
        let uniqueTypes = Array(Set(types))
        
        return uniqueTypes.map { type in
            let typeDistractions = session.distractions.filter { $0.description == type }
            let count = typeDistractions.count
            let duration = typeDistractions.reduce(0) { $0 + $1.duration }
            return (type, count, duration)
        }.sorted { $0.duration > $1.duration }
    }
    
    var body: some View {
        List {
            Section(header: Text("会话信息".localized)) {
                HStack {
                    Text("开始时间".localized)
                    Spacer()
                    Text(TimeFormatter.formatTime(session.startTime))
                }
                
                HStack {
                    Text("结束时间".localized)
                    Spacer()
                    Text(session.endTime != nil ? TimeFormatter.formatTime(session.endTime!) : "In Progress".localized)
                }
                
                HStack {
                    Text("总专注时间".localized)
                    Spacer()
                    Text(TimeFormatter.formatTimeInterval(session.totalFocusTime))
                        .foregroundColor(.green)
                }
                
                HStack {
                    Text("总分心时间".localized)
                    Spacer()
                    Text(TimeFormatter.formatTimeInterval(session.distractionTime))
                        .foregroundColor(.red)
                }
                if let gaps = session.unsegmentedSilences, !gaps.isEmpty {
                    HStack {
                        Text("其中未切段无声间隔".localized)
                        Spacer()
                        Text(TimeFormatter.formatTimeInterval(gaps.reduce(0) { $0 + $1.duration }))
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            // 添加练习内容部分
            Section(header: HStack {
                Text("练习内容".localized)
                Spacer()
                Button(action: {
                    // 初始化编辑字段
                    editedPieceName = session.practiceContent?.pieceName ?? ""
                    editedImprovements = session.practiceContent?.improvements ?? ""
                    editedNotes = session.practiceContent?.notes ?? ""
                    isEditing = true
                }) {
                    Text("编辑".localized)
                        .font(.subheadline)
                        .foregroundColor(.blue)
                }
            }) {
                if isEditing {
                    // 编辑模式
                    VStack(alignment: .leading) {
                        Text("练习曲目".localized)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        TextField("输入练习曲目".localized, text: $editedPieceName)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .padding(.vertical, 4)
                        
                        Text("本次改进".localized)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .padding(.top, 8)
                        TextEditor(text: $editedImprovements)
                            .frame(height: 80)
                            .padding(4)
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                            )
                        
                        Text("备注".localized)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .padding(.top, 8)
                        TextEditor(text: $editedNotes)
                            .frame(height: 80)
                            .padding(4)
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                            )
                        
                        HStack {
                            Button("取消".localized) {
                                isEditing = false
                            }
                            .buttonStyle(.bordered)
                            
                            Spacer()
                            
                            Button("保存".localized) {
                                saveChanges()
                                isEditing = false
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .padding(.top, 10)
                    }
                    .padding(.vertical, 4)
                } else {
                    // 查看模式
                    if let practiceContent = session.practiceContent, 
                       (!practiceContent.pieceName.isEmpty || 
                        !practiceContent.improvements.isEmpty || 
                        !practiceContent.notes.isEmpty) {
                        
                        if !practiceContent.pieceName.isEmpty {
                            VStack(alignment: .leading) {
                                Text("练习曲目".localized)
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                Text(practiceContent.pieceName)
                                    .padding(.top, 2)
                            }
                            .padding(.vertical, 4)
                        }
                        
                        if !practiceContent.improvements.isEmpty {
                            VStack(alignment: .leading) {
                                Text("本次改进".localized)
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                Text(practiceContent.improvements)
                                    .padding(.top, 2)
                            }
                            .padding(.vertical, 4)
                        }
                        
                        if !practiceContent.notes.isEmpty {
                            VStack(alignment: .leading) {
                                Text("备注".localized)
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                Text(practiceContent.notes)
                                    .padding(.top, 2)
                            }
                            .padding(.vertical, 4)
                        }
                    } else {
                        Text("暂无练习内容记录".localized)
                            .foregroundColor(.secondary)
                            .italic()
                    }
                }
            }
            
            if !distractionStats.isEmpty {
                Section(header: Text("分心类型统计".localized)) {
                    ForEach(distractionStats, id: \.type) { stat in
                        HStack {
                            Text(stat.type.localized)
                            Spacer()
                            Text("%d interruptions · %@".localizedFormat(stat.count, TimeFormatter.formatTimeInterval(stat.duration)))
                                .foregroundColor(.red)
                        }
                    }
                }
            }
            
            Section(header: Text("分心记录".localized)) {
                if session.distractions.isEmpty {
                    Text("没有分心记录".localized)
                        .foregroundColor(.secondary)
                        .italic()
                } else {
                    ForEach(session.distractions) { distraction in
                        DistractionListItem(distraction: distraction)
                    }
                }
            }

        }
        .navigationTitle("会话详情".localized)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: {
                    // 删除该会话
                    deleteSession()
                    dismiss()
                }) {
                    Image(systemName: "trash")
                        .foregroundColor(.red)
                }
            }
        }
    }
    
    // 保存更改
    private func saveChanges() {
        // 查找session在FocusManager中的索引
        if let index = focusManager.allSessions.firstIndex(where: { $0.id == session.id }) {
            // 创建新的PracticeContent
            let updatedContent = PracticeContent(
                pieceName: editedPieceName,
                improvements: editedImprovements,
                notes: editedNotes
            )
            
            // 创建会话的可变副本
            var updatedSession = session
            updatedSession.practiceContent = updatedContent
            
            // 更新FocusManager中的会话
            var updatedSessions = focusManager.allSessions
            updatedSessions[index] = updatedSession
            focusManager.allSessions = updatedSessions
        }
    }
    
    // 删除会话
    private func deleteSession() {
        // 从FocusManager中移除该会话
        focusManager.allSessions.removeAll(where: { $0.id == session.id })
    }
}

/**
 * @struct DailyStatsView
 * @description 每日统计视图
 */
struct DailyStatsView: View {
    let date: Date
    @EnvironmentObject var focusManager: FocusManager
    
    var sessions: [FocusSession] {
        focusManager.getSessionsForDate(date)
    }
    
    var totalFocusTime: TimeInterval {
        focusManager.getTotalFocusTimeForDate(date)
    }
    
    var totalDistractionTime: TimeInterval {
        focusManager.getTotalDistractionTimeForDate(date)
    }
    
    // 计算专注率
    var focusRate: Double {
        let totalTime = totalFocusTime + totalDistractionTime
        return totalTime > 0 ? (totalFocusTime / totalTime) * 100 : 0
    }
    
    var body: some View {
        VStack(spacing: 20) {
            Text(TimeFormatter.formatDate(date))
                .font(.headline)
                .padding(.top)
            
            HStack(spacing: 20) {
                VStack {
                    Text("专注时间".localized)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Text(TimeFormatter.formatTimeInterval(totalFocusTime))
                        .font(.headline)
                        .foregroundColor(.green)
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color(.secondarySystemBackground))
                .cornerRadius(10)
                
                VStack {
                    Text("分心时间".localized)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Text(TimeFormatter.formatTimeInterval(totalDistractionTime))
                        .font(.headline)
                        .foregroundColor(.red)
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color(.secondarySystemBackground))
                .cornerRadius(10)
            }
            .padding(.horizontal)
            
            // 专注率显示
            VStack {
                Text("专注率".localized)
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                HStack(spacing: 4) {
                    Text(String(format: "%.1f%%", focusRate))
                        .font(.headline)
                    
                    Image(systemName: focusRate >= 80 ? "star.fill" : 
                          focusRate >= 60 ? "star" : "exclamationmark.triangle")
                        .foregroundColor(focusRate >= 80 ? .yellow : 
                                        focusRate >= 60 ? .orange : .red)
                }
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(Color(.secondarySystemBackground))
            .cornerRadius(10)
            .padding(.horizontal)
            
            if sessions.isEmpty {
                Text("今天还没有专注记录".localized)
                    .foregroundColor(.secondary)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(10)
                    .padding(.horizontal)
            } else {
                List {
                    ForEach(sessions) { session in
                        NavigationLink(destination: SessionDetailView(session: session)) {
                            SessionListItem(session: session, accountingDay: date)
                        }
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    }
                }
                .listStyle(.plain)
            }
        }
    }
}

/**
 * @struct HistoryView
 * @description 历史记录视图
 */
struct HistoryView: View {
    @EnvironmentObject var focusManager: FocusManager
    @State private var selectedDate = Date()
    
    // 检测当前视图是否嵌入在另一个NavigationView中
    @Environment(\.presentationMode) var presentationMode
    
    var body: some View {
        VStack {
            HStack {
                Text("练琴历史".localized)
                    .font(.title)
                    .fontWeight(.bold)
                    .padding(.horizontal)
                
                Spacer()
            }
            .padding(.top)
            
            DatePicker(
                "选择日期".localized,
                selection: $selectedDate,
                displayedComponents: .date
            )
            .datePickerStyle(.graphical)
            .padding()
            
            DailyStatsView(date: selectedDate)
                .environmentObject(focusManager)
        }
    }
}
