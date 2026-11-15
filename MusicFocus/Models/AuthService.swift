import Foundation

/**
 * @class AuthService
 * @description 处理与认证相关的网络请求
 */
class AuthService {
    static let shared = AuthService()
    private let baseURL = "https://feuxfollets.top"
    
    enum AuthError: LocalizedError {
        case invalidURL
        case networkError(Error)
        case serverError(String)
        case decodingError(Error)
        
        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "无效的URL"
            case .networkError(let error):
                return "网络错误：\(error.localizedDescription)"
            case .serverError(let message):
                return "服务器错误：\(message)"
            case .decodingError(let error):
                return "数据解析错误：\(error.localizedDescription)"
            }
        }
    }
    
    /**
     * 发送验证码
     * @param email 用户邮箱
     * @return 是否发送成功
     */
    func sendVerificationCode(email: String) async throws -> Bool {
        guard let url = URL(string: "\(baseURL)/api/auth/send-verification-code") else {
            print("❌ URL 无效：\(baseURL)/api/auth/send-verification-code")
            throw AuthError.invalidURL
        }
        
        print("📤 准备发送验证码请求到：\(url)")
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body = ["email": email]
        request.httpBody = try JSONEncoder().encode(body)
        
        print("📝 请求数据：\(body)")
        
        do {
            print("⏳ 开始网络请求...")
            let (data, response) = try await URLSession.shared.data(for: request)
            
            if let httpResponse = response as? HTTPURLResponse {
                print("📥 收到响应，状态码：\(httpResponse.statusCode)")
                print("📍 响应头：\(httpResponse.allHeaderFields)")
            }
            
            let responseString = String(data: data, encoding: .utf8) ?? "无法解码的数据"
            print("📄 响应数据：\(responseString)")
            
            do {
                let apiResponse = try JSONDecoder().decode(BaseResponse<EmptyData>.self, from: data)
                
                if apiResponse.success {
                    print("✅ 验证码发送成功")
                    return true
                } else {
                    print("❌ 验证码发送失败：\(apiResponse.message ?? "未知错误")")
                    throw AuthError.serverError(apiResponse.message ?? "未知错误")
                }
            } catch {
                print("❌ JSON解析错误：\(error)")
                throw AuthError.decodingError(error)
            }
        } catch let error as AuthError {
            print("❌ 认证错误：\(error.localizedDescription)")
            throw error
        } catch {
            print("❌ 网络错误：\(error)")
            throw AuthError.networkError(error)
        }
    }
    
    /**
     * 用户注册
     * @param username 用户名
     * @param email 邮箱
     * @param password 密码
     * @param code 验证码
     * @return 注册响应
     */
    func register(username: String, email: String, password: String, code: String) async throws -> AuthResponse {
        guard let url = URL(string: "\(baseURL)/api/auth/register") else {
            throw AuthError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body = [
            "username": username,
            "email": email,
            "password": password,
            "code": code,
            "role": "student"
        ]
        request.httpBody = try JSONEncoder().encode(body)
        
        print("📤 发送注册请求：\(url)")
        print("📝 注册数据：\(body)")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            if let httpResponse = response as? HTTPURLResponse {
                print("📥 收到响应，状态码：\(httpResponse.statusCode)")
            }
            
            let responseString = String(data: data, encoding: .utf8) ?? "无法解码的数据"
            print("📄 响应数据：\(responseString)")
            
            return try JSONDecoder().decode(AuthResponse.self, from: data)
        } catch {
            print("❌ 注册失败：\(error)")
            throw error
        }
    }
    
    /**
     * 用户登录
     * @param email 邮箱
     * @param password 密码
     * @return 登录响应
     */
    func login(email: String, password: String) async throws -> AuthResponse {
        guard let url = URL(string: "\(baseURL)/api/auth/login") else {
            throw AuthError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body = ["email": email, "password": password]
        request.httpBody = try JSONEncoder().encode(body)
        
        print("📤 发送登录请求：\(url)")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            if let httpResponse = response as? HTTPURLResponse {
                print("📥 收到响应，状态码：\(httpResponse.statusCode)")
            }
            
            let responseString = String(data: data, encoding: .utf8) ?? "无法解码的数据"
            print("📄 响应数据：\(responseString)")
            
            return try JSONDecoder().decode(AuthResponse.self, from: data)
        } catch {
            print("❌ 登录失败：\(error)")
            throw error
        }
    }
}

// Response models
struct BaseResponse<T: Codable>: Codable {
    let success: Bool
    let message: String?
    let data: T?
}

struct EmptyData: Codable {}

struct AuthResponse: Codable {
    let success: Bool
    let data: AuthData
}

struct AuthData: Codable {
    let user: User
    let token: String
}

struct User: Codable {
    let _id: String
    let username: String
    let email: String
    let role: String
    let lastLoginAt: String?
    
    var createdAt: Date {
        // 从 _id 中提取创建时间
        let timestamp = Int(_id.prefix(8), radix: 16) ?? 0
        return Date(timeIntervalSince1970: TimeInterval(timestamp))
    }
} 