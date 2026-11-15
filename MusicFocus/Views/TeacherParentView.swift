import SwiftUI

/**
 * @struct TeacherParentView
 * @description 教师/家长视图，显示学生练习情况
 */
struct TeacherParentView: View {
    @EnvironmentObject var focusManager: FocusManager
    @State private var students: [Student] = [] // 暂时使用本地数据
    @State private var showBindingSheet = false
    
    var body: some View {
        VStack(spacing: 0) {
            // 顶部标题
            HStack {
                Text("学生练习情况")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .padding(.horizontal)
                
                Spacer()
                
                Button(action: {
                    showBindingSheet = true
                }) {
                    Image(systemName: "person.badge.plus")
                        .font(.title2)
                }
                .padding(.horizontal)
            }
            .padding(.top)
            .padding(.bottom, 8)
            
            Divider()
                .padding(.horizontal)
                .padding(.bottom, 8)
            
            if students.isEmpty {
                VStack(spacing: 20) {
                    Image(systemName: "person.2")
                        .font(.system(size: 50))
                        .foregroundColor(.gray)
                    Text("暂无绑定学生")
                        .font(.headline)
                        .foregroundColor(.gray)
                    Button(action: {
                        showBindingSheet = true
                    }) {
                        Text("添加学生")
                            .font(.headline)
                            .foregroundColor(.white)
                            .padding(.horizontal, 30)
                            .padding(.vertical, 12)
                            .background(Color.blue)
                            .cornerRadius(25)
                    }
                }
                .frame(maxHeight: .infinity)
            } else {
                // 学生列表
                ScrollView {
                    VStack(spacing: 16) {
                        ForEach(students) { student in
                            StudentCardView(student: student)
                        }
                    }
                    .padding()
                }
            }
        }
        .sheet(isPresented: $showBindingSheet) {
            BindStudentView()
        }
    }
}

/**
 * @struct StudentCardView
 * @description 学生卡片视图，显示学生练习概况
 */
struct StudentCardView: View {
    let student: Student
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 学生基本信息
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(student.name)
                        .font(.headline)
                    Text(student.email)
                        .font(.subheadline)
                        .foregroundColor(.gray)
                }
                Spacer()
                NavigationLink(destination: StudentDetailView(student: student)) {
                    Text("查看详情")
                        .font(.subheadline)
                        .foregroundColor(.blue)
                }
            }
            
            Divider()
            
            // 本周练习统计
            HStack(spacing: 20) {
                StatisticItem(
                    title: "本周练琴",
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
 * @struct StatisticItem
 * @description 统计项视图
 */
struct StatisticItem: View {
    let title: String
    let value: String
    let icon: String
    let color: Color
    
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(color)
                .font(.title3)
            Text(value)
                .font(.headline)
            Text(title)
                .font(.caption)
                .foregroundColor(.gray)
        }
        .frame(maxWidth: .infinity)
    }
}

/**
 * @struct BindStudentView
 * @description 绑定学生视图
 */
struct BindStudentView: View {
    @Environment(\.presentationMode) var presentationMode
    @State private var bindCode = ""
    @State private var showAlert = false
    @State private var alertMessage = ""
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("输入绑定码")) {
                    TextField("学生的绑定码", text: $bindCode)
                        .keyboardType(.numberPad)
                }
                
                Section {
                    Button(action: {
                        // TODO: 实现绑定逻辑
                        alertMessage = "绑定功能暂未实现"
                        showAlert = true
                    }) {
                        Text("确认绑定")
                            .frame(maxWidth: .infinity)
                            .foregroundColor(.blue)
                    }
                }
            }
            .navigationTitle("绑定学生")
            .navigationBarItems(
                leading: Button("取消") {
                    presentationMode.wrappedValue.dismiss()
                }
            )
            .alert(isPresented: $showAlert) {
                Alert(
                    title: Text("提示"),
                    message: Text(alertMessage),
                    dismissButton: .default(Text("确定"))
                )
            }
        }
    }
}

// 预览
struct TeacherParentView_Previews: PreviewProvider {
    static var previews: some View {
        TeacherParentView()
            .environmentObject(FocusManager())
    }
} 