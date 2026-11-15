import SwiftUI

/**
 * @struct AccountView
 * @description 用户账户视图
 */
struct AccountView: View {
    @EnvironmentObject var focusManager: FocusManager
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var email: String = ""
    @State private var verificationCode: String = ""
    @State private var showLoginView = false
    @State private var showRegisterView = false
    @State private var isLoading = false
    @State private var errorMessage = ""
    @State private var isVerificationCodeSent = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if focusManager.currentUser != nil {
                // 已登录状态 - 显示账户信息
                loggedInView
            } else {
                // 未登录状态 - 显示登录选项
                loggedOutView
            }
        }
        .sheet(isPresented: $showLoginView) {
            loginView
        }
        .sheet(isPresented: $showRegisterView) {
            registerView
        }
        .navigationTitle("账号信息")
        .padding()
    }
    
    // 已登录视图
    var loggedInView: some View {
        VStack(alignment: .leading) {
            // 账户信息
            HStack(alignment: .center, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("账户信息")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                    
                    HStack {
                        Text("用户名:")
                            .fontWeight(.medium)
                        Text(focusManager.currentUser?.username ?? "未知")
                    }
                    
                    HStack {
                        Text("邮箱:")
                            .fontWeight(.medium)
                        Text(focusManager.currentUser?.email ?? "未知")
                    }
                    
                    HStack {
                        Text("账户创建时间:")
                            .fontWeight(.medium)
                        Text(focusManager.currentUser?.createdAt.formatted() ?? "未知")
                    }
                    
                    if let lastLoginAt = focusManager.currentUser?.lastLoginAt {
                        HStack {
                            Text("上次登录时间:")
                                .fontWeight(.medium)
                            Text(lastLoginAt)
                        }
                    }
                }
                
                Spacer()
            }
            .padding()
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)
            
            Spacer()
            
            // 登出按钮
            Button(action: {
                focusManager.logout()
            }) {
                HStack {
                    Image(systemName: "arrow.right.circle")
                    Text("退出登录")
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.red.opacity(0.8))
                .foregroundColor(.white)
                .cornerRadius(10)
            }
        }
    }
    
    // 未登录视图
    var loggedOutView: some View {
        VStack(spacing: 20) {
            Spacer()
            
            Text("您尚未登录")
                .font(.title)
                .fontWeight(.bold)
            
            Text("登录账号可以同步您的练习记录和设置")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .padding(.horizontal)
            
            Spacer()
            
            Button(action: {
                showLoginView = true
            }) {
                HStack {
                    Image(systemName: "person.fill")
                    Text("登录")
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.blue)
                .foregroundColor(.white)
                .cornerRadius(10)
            }
            
            Button(action: {
                showRegisterView = true
            }) {
                HStack {
                    Image(systemName: "person.badge.plus")
                    Text("创建新账号")
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.green)
                .foregroundColor(.white)
                .cornerRadius(10)
            }
        }
        .padding()
    }
    
    // 登录视图
    var loginView: some View {
        VStack(spacing: 20) {
            Text("登录账号")
                .font(.title)
                .fontWeight(.bold)
            
            TextField("邮箱", text: $email)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .autocapitalization(.none)
                .padding()
                .background(Color(.secondarySystemBackground))
                .cornerRadius(8)
            
            SecureField("密码", text: $password)
                .padding()
                .background(Color(.secondarySystemBackground))
                .cornerRadius(8)
            
            if !errorMessage.isEmpty {
                Text(errorMessage)
                    .foregroundColor(.red)
            }
            
            Button(action: loginUser) {
                if isLoading {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                } else {
                    Text("登录")
                }
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(Color.blue)
            .foregroundColor(.white)
            .cornerRadius(10)
            .disabled(isLoading)
            
            Button(action: {
                showLoginView = false
                email = ""
                password = ""
                errorMessage = ""
            }) {
                Text("取消")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.gray.opacity(0.3))
                    .foregroundColor(.primary)
                    .cornerRadius(10)
            }
        }
        .padding()
    }
    
    // 注册视图
    var registerView: some View {
        VStack(spacing: 20) {
            Text("创建新账号")
                .font(.title)
                .fontWeight(.bold)
            
            TextField("用户名", text: $username)
                .textContentType(.username)
                .autocapitalization(.none)
                .padding()
                .background(Color(.secondarySystemBackground))
                .cornerRadius(8)
            
            TextField("邮箱", text: $email)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .autocapitalization(.none)
                .padding()
                .background(Color(.secondarySystemBackground))
                .cornerRadius(8)
            
            HStack {
                TextField("验证码", text: $verificationCode)
                    .keyboardType(.numberPad)
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(8)
                
                Button(action: sendVerificationCode) {
                    if isLoading {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    } else {
                        Text(isVerificationCodeSent ? "重新发送" : "发送验证码")
                    }
                }
                .padding()
                .background(Color.blue)
                .foregroundColor(.white)
                .cornerRadius(8)
                .disabled(isLoading)
            }
            
            SecureField("密码", text: $password)
                .textContentType(.newPassword)
                .padding()
                .background(Color(.secondarySystemBackground))
                .cornerRadius(8)
            
            if !errorMessage.isEmpty {
                Text(errorMessage)
                    .foregroundColor(.red)
            }
            
            Button(action: registerUser) {
                if isLoading {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                } else {
                    Text("注册")
                }
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(Color.green)
            .foregroundColor(.white)
            .cornerRadius(10)
            .disabled(isLoading)
            
            Button(action: {
                showRegisterView = false
                username = ""
                email = ""
                password = ""
                verificationCode = ""
                errorMessage = ""
            }) {
                Text("取消")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.gray.opacity(0.3))
                    .foregroundColor(.primary)
                    .cornerRadius(10)
            }
        }
        .padding()
    }
    
    // 登录方法
    private func loginUser() {
        guard !email.isEmpty, !password.isEmpty else {
            errorMessage = "请填写所有必填项"
            return
        }
        
        isLoading = true
        Task {
            do {
                let response = try await AuthService.shared.login(email: email, password: password)
                await MainActor.run {
                    isLoading = false
                    if response.success {
                        focusManager.saveAuthData(response.data)
                        showLoginView = false
                        email = ""
                        password = ""
                        errorMessage = ""
                    }
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                    errorMessage = "登录失败：\(error.localizedDescription)"
                }
            }
        }
    }
    
    // 发送验证码方法
    private func sendVerificationCode() {
        guard !email.isEmpty else {
            errorMessage = "请输入邮箱"
            return
        }
        
        isLoading = true
        Task {
            do {
                let success = try await AuthService.shared.sendVerificationCode(email: email)
                await MainActor.run {
                    isLoading = false
                    if success {
                        isVerificationCodeSent = true
                        errorMessage = "验证码已发送到邮箱"
                    } else {
                        errorMessage = "验证码发送失败"
                    }
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                    errorMessage = "验证码发送失败：\(error.localizedDescription)"
                }
            }
        }
    }
    
    // 注册方法
    private func registerUser() {
        guard !username.isEmpty, !email.isEmpty, !password.isEmpty, !verificationCode.isEmpty else {
            errorMessage = "请填写所有必填项"
            return
        }
        
        isLoading = true
        Task {
            do {
                let response = try await AuthService.shared.register(
                    username: username,
                    email: email,
                    password: password,
                    code: verificationCode
                )
                await MainActor.run {
                    isLoading = false
                    if response.success {
                        focusManager.saveAuthData(response.data)
                        showRegisterView = false
                        username = ""
                        email = ""
                        password = ""
                        verificationCode = ""
                        errorMessage = ""
                    }
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                    errorMessage = "注册失败：\(error.localizedDescription)"
                }
            }
        }
    }
}

#Preview {
    let manager = FocusManager()
    return AccountView()
        .environmentObject(manager)
} 