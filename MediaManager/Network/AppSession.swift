import Foundation

// MARK: - 会话状态
// 持有服务器地址 + 登录态 + APIClient 实例，驱动 App 的登录 / 主界面切换。
final class AppSession: ObservableObject {
    static let shared = AppSession()

    @Published var client: APIClient?
    @Published var user: User?
    @Published var baseURL: URL?
    @Published var isConnecting = false
    @Published var errorMessage: String?

    var isLoggedIn: Bool { client != nil }

    /// 规范化服务器地址：补 http:// 前缀、去尾部斜杠
    static func normalizeBaseURL(_ input: String) -> URL? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.hasPrefix("http://"), !s.hasPrefix("https://") {
            s = "http://" + s
        }
        while s.hasSuffix("/") { s.removeLast() }
        return URL(string: s)
    }

    @MainActor
    func connect(server: String, username: String, password: String) async {
        isConnecting = true
        errorMessage = nil
        defer { isConnecting = false }
        guard let url = Self.normalizeBaseURL(server) else {
            errorMessage = "服务器地址无效"
            return
        }
        do {
            let c = APIClient(baseURL: url)
            let u = try await c.login(username: username, password: password)
            self.client = c
            self.user = u
            self.baseURL = url
            UserDefaults.standard.set(url.absoluteString, forKey: "serverBaseURL")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func logout() {
        client = nil
        user = nil
        errorMessage = nil
    }

    /// 启动时恢复上次的服务器地址（登录态由 cookie 自动保留，重新登录即可）
    func restoreBaseURL() {
        if let str = UserDefaults.standard.string(forKey: "serverBaseURL"),
           let url = URL(string: str) {
            self.baseURL = url
        }
    }
}
