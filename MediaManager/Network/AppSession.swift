import Foundation

// MARK: - 会话状态
// 持有服务器地址 + 登录态 + APIClient 实例，驱动 App 的登录 / 主界面切换。
final class AppSession: ObservableObject {
    static let shared = AppSession()

    @Published var client: APIClient?
    @Published var user: User?
    @Published var baseURL: URL?
    @Published var isConnecting = false
    /// 启动时正在用旧 cookie 静默校验登录态（此时不该闪登录页）
    @Published var isRestoring = false
    @Published var errorMessage: String?

    var isLoggedIn: Bool { client != nil }

    private static let keyBaseURL = "serverBaseURL"
    private static let keySessionValue = "sessionCookieValue"
    private static let keySessionHost = "sessionCookieHost"
    /// 每次启动只尝试恢复一次
    private var didRestore = false

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
            // remember=true → 后端给 30 天 cookie（否则只有 24h）
            let u = try await c.login(username: username, password: password, remember: true)
            self.client = c
            self.user = u
            self.baseURL = url
            UserDefaults.standard.set(url.absoluteString, forKey: Self.keyBaseURL)
            persistSessionCookie()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func logout() {
        if let url = baseURL { clearCookies(for: url) }
        UserDefaults.standard.removeObject(forKey: Self.keySessionValue)
        UserDefaults.standard.removeObject(forKey: Self.keySessionHost)
        client = nil
        user = nil
        errorMessage = nil
        // 服务器地址保留，登录页会预填；下次登录即可
    }

    // MARK: - 启动恢复（杀掉 App 后免登录）

    /// 用上次的服务器地址 + 残留的 session cookie，静默校验一次登录态。
    ///
    /// 后端 `setSessionCookie` 写的 cookie 带 `Max-Age`（默认 24h / remember 30 天），
    /// 服务端这边「杀 App」并不会让 session 失效 —— 真正缺的是启动时**拿 cookie 去
    /// /api/auth/me 校验一次**并据此恢复 client。以前只恢复地址，于是每次都要重登。
    @MainActor
    func restoreSession() async {
        guard !didRestore, client == nil else { return }
        guard let str = UserDefaults.standard.string(forKey: Self.keyBaseURL),
              let url = URL(string: str), url.host != nil else {
            didRestore = true
            return
        }
        didRestore = true
        self.baseURL = url
        isRestoring = true
        defer { isRestoring = false }

        let c = APIClient(baseURL: url)
        if let u = try? await c.fetchCurrentUser() {
            self.client = c
            self.user = u
            persistSessionCookie()
            return
        }
        // 系统 cookie 没保住时，用自己存的那份再试一次
        if injectPersistedCookie(for: url), let u = try? await c.fetchCurrentUser() {
            self.client = c
            self.user = u
            persistSessionCookie()
            return
        }
        // 确实失效了：清掉残留，留在登录页（地址已预填）
        clearCookies(for: url)
        UserDefaults.standard.removeObject(forKey: Self.keySessionValue)
        UserDefaults.standard.removeObject(forKey: Self.keySessionHost)
        self.client = nil
        self.user = nil
    }

    // MARK: - cookie 兜底

    /// 把当前 session cookie 的值自己存一份。
    /// iOS 的 `httpCookieAcceptPolicy` 默认是 `.onlyFromMainDocumentDomain`，
    /// URLSession 这种非主文档请求拿到的 Set-Cookie **不保证会写盘**，
    /// 光指望系统的话，冷启动能不能拿到全看运气 —— 所以自己落一份。
    private func persistSessionCookie() {
        guard let url = baseURL else { return }
        let cookies = HTTPCookieStorage.shared.cookies(for: url) ?? []
        guard let cookie = cookies.first(where: { $0.name == "session" }) else { return }
        UserDefaults.standard.set(cookie.value, forKey: Self.keySessionValue)
        UserDefaults.standard.set(url.host ?? "", forKey: Self.keySessionHost)
    }

    /// 把存下来的 session cookie 写回 cookie storage，再试一次请求
    @discardableResult
    private func injectPersistedCookie(for url: URL) -> Bool {
        guard let value = UserDefaults.standard.string(forKey: Self.keySessionValue),
              !value.isEmpty,
              let host = url.host,
              UserDefaults.standard.string(forKey: Self.keySessionHost) == host else { return false }
        var props: [HTTPCookiePropertyKey: Any] = [
            .domain: host,
            .path: "/",
            .name: "session",
            .value: value
        ]
        if url.scheme == "https" { props[.secure] = "TRUE" }
        guard let cookie = HTTPCookie(properties: props) else { return false }
        HTTPCookieStorage.shared.setCookie(cookie)
        return true
    }

    private func clearCookies(for url: URL) {
        let storage = HTTPCookieStorage.shared
        (storage.cookies(for: url) ?? [])
            .filter { $0.name == "session" }
            .forEach { storage.deleteCookie($0) }
    }
}
