import Foundation

// MARK: - 会话状态
// 持有服务器地址 + 登录态 + APIClient 实例，驱动 App 的登录 / 主界面切换。
//
// 2026-11-07：支持「动态切换服务器 IP + 客户端记忆」：
//   · `servers` 是记住的地址列表（最近使用在前），UserDefaults 持久化；
//   · `switchServer(to:)` 一键切，目标服务器存过登录态就免密直接切过去；
//   · session cookie 按 host 存字典，切走不丢、切回来还能免密；
//   · `sessionEpoch` 让 App 根重建 RootView，避免首页残留上一台服务器的数据。
final class AppSession: ObservableObject {
    static let shared = AppSession()

    @Published var client: APIClient?
    @Published var user: User?
    @Published var baseURL: URL?
    @Published var isConnecting = false
    /// 启动时正在用旧 cookie 静默校验登录态（此时不该闪登录页）
    @Published var isRestoring = false
    @Published var errorMessage: String?
    /// 记住连过的服务器地址（规范化后的 absoluteString，最近使用在前）
    @Published var servers: [String] = []
    /// 每次成功换服务器 +1：App 根拿它给 RootView 换 id，强制所有 ViewModel 重建
    @Published var sessionEpoch: Int = 0

    var isLoggedIn: Bool { client != nil }

    /// 上次登录的用户名（只存用户名，**不存密码**）：换 IP 后登录页预填，少输一遍
    var lastUsername: String? {
        UserDefaults.standard.string(forKey: Self.keyLastUsername)
    }

    /// 当前 session 值（登录态）。
    ///
    /// 用途只有一个：拼进「外部播放器会自己去拉」的 URL 的 ?token= 上。
    /// 后端 AuthMiddleware 认三种身份（cookie / Authorization / query token），
    /// 而 VidHub 拉字幕时带不上我们的 cookie，只能把 session 值放进 query。
    /// ⚠️ 必须取**当前服务器**的 cookie：换 IP 后若还拿上一台的值，外播会 401。
    /// 优先读 cookie storage（切换时会注入目标服务器的 cookie），回退按 host 的字典。
    var sessionToken: String? {
        guard let url = baseURL, let host = url.host else { return nil }
        if let c = (HTTPCookieStorage.shared.cookies(for: url) ?? [])
            .first(where: { $0.name == "session" })?.value, !c.isEmpty { return c }
        let v = Self.sessionMap()[host] ?? ""
        return v.isEmpty ? nil : v
    }

    private static let keyBaseURL = "serverBaseURL"
    private static let keyServerList = "serverBaseURLList"
    private static let keyLastUsername = "lastUsername"
    /// 旧版单份 cookie，保留作迁移 / 回滚兜底
    private static let keySessionValue = "sessionCookieValue"
    private static let keySessionHost = "sessionCookieHost"
    /// [host: session cookie value]：每台服务器各存各的，切回来免密
    private static let keySessionMap = "sessionCookieMap"
    /// 每次启动只尝试恢复一次
    private var didRestore = false

    private init() {
        var list = UserDefaults.standard.stringArray(forKey: Self.keyServerList) ?? []
        // 兼容老版本：只存了一个 serverBaseURL，列表里没有 → 补进去
        if let cur = UserDefaults.standard.string(forKey: Self.keyBaseURL),
           !cur.isEmpty, !list.contains(cur) {
            list.insert(cur, at: 0)
        }
        self.servers = list
        UserDefaults.standard.set(list, forKey: Self.keyServerList)
        // 旧版单份 cookie 迁进按 host 的字典（不覆盖已有的）
        if let v = UserDefaults.standard.string(forKey: Self.keySessionValue), !v.isEmpty,
           let h = UserDefaults.standard.string(forKey: Self.keySessionHost), !h.isEmpty {
            var m = Self.sessionMap()
            if m[h] == nil {
                m[h] = v
                Self.setSessionMap(m)
            }
        }
    }

    /// 规范化服务器地址：补协议前缀、去尾部斜杠。
    /// 没写协议时按「域名 vs IP」猜：域名（外网）默认 https，IP / localhost（局域网）默认 http。
    /// 显式写了 http:// 或 https:// 的一律尊重用户输入。
    static func normalizeBaseURL(_ input: String) -> URL? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.hasPrefix("http://"), !s.hasPrefix("https://") {
            s = (Self.looksLikeDomain(s) ? "https://" : "http://") + s
        }
        while s.hasSuffix("/") { s.removeLast() }
        return URL(string: s)
    }

    /// 是否像域名（而不是 IPv4 / localhost）：决定默认补 https 还是 http。
    /// 例：nas.example.com:8443 → true；192.168.1.100:19876 / localhost:19876 → false。
    private static func looksLikeDomain(_ input: String) -> Bool {
        let hostPort = input.split(separator: "/").first.map(String.init) ?? input
        let host = hostPort.split(separator: ":").first.map(String.init) ?? hostPort
        if host == "localhost" || host.hasPrefix("127.") { return false }
        guard host.contains(".") else { return false }
        // 纯数字点分 = IPv4（含局域网 / 公网 IP），按局域网处理
        if let last = host.split(separator: ".").last, last.allSatisfy({ $0.isNumber }) {
            return false
        }
        return true
    }

    /// 把网络错误翻译成能照着排查的提示。
    /// ⚠️ 系统 localizedDescription 对外网 HTTPS 经常只给 "TLS error" / "could not be completed"，
    ///    看不出是「对端根本没开 TLS」还是「证书不被信任」，两者修法完全不同。
    static func describe(_ error: Error) -> String {
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return error.localizedDescription }
        // NSURLError 的 SSL 段：-1200 握手失败，-1201~-1206 证书问题
        let tlsCodes: Set<Int> = [-1200, -1201, -1202, -1203, -1204, -1205, -1206]
        if tlsCodes.contains(ns.code) {
            return "HTTPS/TLS 失败（\(ns.code)）。-1200 通常是服务端没开 TLS：Go 网关 19876 只有 HTTP，直接把地址里的 http 改成 https 会握手失败，需要在前面加一层 HTTPS 反向代理；-1201~-1206 是证书不被信任：自签/私有 CA 请把根证书装进设备并在「设置 → 通用 → 关于本机 → 证书信任设置」开启完全信任，公网证书请核对域名是否匹配、证书链是否完整。"
        }
        return "\(error.localizedDescription)（错误码 \(ns.code)）"
    }

    /// 网络层（含 TLS）失败：这时不该把当前已连上的服务器踢掉
    static func isNetworkFailure(_ error: Error) -> Bool {
        (error as NSError).domain == NSURLErrorDomain
    }

    // MARK: - 地址列表（客户端记忆）

    /// 记住一个地址：去重、最近使用排最前。只管列表，**不改当前地址**。
    func rememberServer(_ url: URL) {
        let s = url.absoluteString
        var list = servers.filter { $0 != s }
        list.insert(s, at: 0)
        servers = list
        UserDefaults.standard.set(list, forKey: Self.keyServerList)
    }

    func removeServer(_ address: String) {
        let list = servers.filter { $0 != address }
        servers = list
        UserDefaults.standard.set(list, forKey: Self.keyServerList)
    }

    private func setCurrent(_ url: URL) {
        UserDefaults.standard.set(url.absoluteString, forKey: Self.keyBaseURL)
        rememberServer(url)
    }

    // MARK: - 登录 / 退出

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
            setCurrent(url)
            UserDefaults.standard.set(username, forKey: Self.keyLastUsername)
            persistSessionCookie()
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    /// 退出登录：只退当前这台，地址列表和**其它服务器**的登录态都保留
    func logout() {
        if let url = baseURL {
            clearCookies(for: url)
            removePersistedCookie(for: url)
        }
        client = nil
        user = nil
        errorMessage = nil
    }

    // MARK: - 动态切换服务器

    /// 切到另一台服务器，返回是否完成了切换流程（YES = 已换过去 / 已回登录页）。
    /// - 目标 host 存过有效登录态 → 直接换 client，免密、无缝；
    /// - 没登录态（401）→ 回登录页，地址与用户名已预填，只需输密码；
    /// - 网络 / HTTPS TLS 连不上 → **保持当前这台不动**，只给可排查的提示，返回 NO。
    ///   ⚠️ 关键：TLS 错误绝不能被当成「登录态失效」，否则一换外网 https 地址
    ///   就把当前能用的会话踢掉、还删掉 cookie，用户会以为 App 掉线了。
    @discardableResult
    @MainActor
    func switchServer(to input: String) async -> Bool {
        guard let url = Self.normalizeBaseURL(input) else {
            errorMessage = "服务器地址无效"
            return false
        }
        let target = url.absoluteString
        if target == baseURL?.absoluteString, client != nil {
            errorMessage = nil
            return true
        }
        isConnecting = true
        errorMessage = nil
        defer { isConnecting = false }

        rememberServer(url)
        // 切走前把当前这台 cookie 落盘，之后切回来还能免密
        persistSessionCookie()

        let c = APIClient(baseURL: url)
        // 注入这台存过的 cookie（系统 cookie storage 里可能也已有，双保险）
        _ = injectPersistedCookie(for: url)
        do {
            let u = try await c.fetchCurrentUser()
            self.client = c
            self.user = u
            self.baseURL = url
            UserDefaults.standard.set(target, forKey: Self.keyBaseURL)
            persistSessionCookie()
            // 旧服务器的数据缓存必须失效，否则首页还显示上一台的影片
            sessionEpoch += 1
            return true
        } catch {
            if Self.isNetworkFailure(error) {
                // DNS / 连不上 / TLS 握手或证书失败：当前会话原样保留，别删 cookie
                errorMessage = Self.describe(error)
                return false
            }
        }

        // 确实没有可用登录态（401 等）：清残留，回登录页（地址 + 用户名已预填）
        clearCookies(for: url)
        removePersistedCookie(for: url)
        self.client = nil
        self.user = nil
        self.baseURL = url
        UserDefaults.standard.set(target, forKey: Self.keyBaseURL)
        sessionEpoch += 1
        errorMessage = "已切换到 \(url.host ?? target)，请输入密码登录"
        return true
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
        rememberServer(url)   // 老版本只有单地址，补进列表
        isRestoring = true
        defer { isRestoring = false }

        let c = APIClient(baseURL: url)
        // 先用系统 cookie 试；失败再用自己落盘的那份注入试一次
        for attempt in 0..<2 {
            if attempt == 1, !injectPersistedCookie(for: url) { break }
            do {
                let u = try await c.fetchCurrentUser()
                self.client = c
                self.user = u
                persistSessionCookie()
                return
            } catch {
                if Self.isNetworkFailure(error) {
                    // 网络 / TLS 问题不代表登录态失效：cookie 和地址都留着，
                    // 等网络恢复后冷启动还能直接免密进来；登录页会显示排查提示
                    errorMessage = Self.describe(error)
                    return
                }
                // 401 等：继续下一次尝试 / 最终走清理
            }
        }
        // 确实失效了：清掉残留，留在登录页（地址已预填）
        clearCookies(for: url)
        removePersistedCookie(for: url)
        self.client = nil
        self.user = nil
    }

    // MARK: - cookie 兜底（按 host 隔离）

    private static func sessionMap() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: keySessionMap) as? [String: String] ?? [:]
    }

    private static func setSessionMap(_ map: [String: String]) {
        UserDefaults.standard.set(map, forKey: keySessionMap)
    }

    /// 把当前 session cookie 的值自己存一份（按 host）。
    /// iOS 的 `httpCookieAcceptPolicy` 默认是 `.onlyFromMainDocumentDomain`，
    /// URLSession 这种非主文档请求拿到的 Set-Cookie **不保证会写盘**，
    /// 光指望系统的话，冷启动能不能拿到全看运气 —— 所以自己落一份。
    private func persistSessionCookie() {
        guard let url = baseURL, let host = url.host else { return }
        let cookies = HTTPCookieStorage.shared.cookies(for: url) ?? []
        guard let cookie = cookies.first(where: { $0.name == "session" }) else { return }
        var m = Self.sessionMap()
        m[host] = cookie.value
        Self.setSessionMap(m)
        // 旧字段同步写，兼容回滚 / 旧逻辑
        UserDefaults.standard.set(cookie.value, forKey: Self.keySessionValue)
        UserDefaults.standard.set(host, forKey: Self.keySessionHost)
    }

    private func removePersistedCookie(for url: URL) {
        guard let host = url.host else { return }
        var m = Self.sessionMap()
        m.removeValue(forKey: host)
        Self.setSessionMap(m)
        if UserDefaults.standard.string(forKey: Self.keySessionHost) == host {
            UserDefaults.standard.removeObject(forKey: Self.keySessionValue)
            UserDefaults.standard.removeObject(forKey: Self.keySessionHost)
        }
    }

    /// 把存下来的 session cookie 写回 cookie storage，再试一次请求
    @discardableResult
    private func injectPersistedCookie(for url: URL) -> Bool {
        guard let host = url.host else { return false }
        var value = Self.sessionMap()[host]
        // 旧版单份数据兜底
        if value == nil, UserDefaults.standard.string(forKey: Self.keySessionHost) == host {
            value = UserDefaults.standard.string(forKey: Self.keySessionValue)
        }
        guard let value, !value.isEmpty else { return false }
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
