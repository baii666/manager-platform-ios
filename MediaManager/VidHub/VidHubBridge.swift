import SwiftUI
import UIKit

// MARK: - VidHub 外播桥接层
//
// 三块内容，按「谁活得久」分层：
//
//  ① VidHubBridge（App 级单例）—— 收 open-vidhub://x-callback-url 的回调。
//     它活得比任何页面都久：用户点外播后 App 就退到后台，VidHub 放完电影
//     才把 mediamanager://x-callback-url/success 打回来，那时详情页还在
//     （NavigationStack 没pop），但请求必须能在「页面外」被认领 —— 所以
//     request-id → 影片 的登记表放在单例里，不放页面 State。
//
//  ② VidHubLauncher（页面级）—— 「点一下 → 拉起 VidHub」的完整编排：
//     查续播进度 → 探内嵌字幕 →（首次）异步抽取并轮询 → 带齐参数跳转。
//     抽字幕要把整个文件读一遍（挂载盘 20MB/s，5GB 就是 4 分钟），所以
//     这一跳可能是几分钟的等待，等待过程必须摆在明面上（见 PreparingOverlay）。
//
//  ③ 官方契约（https://vidhub.okaapps.com/3rd-party-app-integration/）：
//     open-vidhub://x-callback-url/play?url=&position=&filename=&sub=
//       &x-source=&request-id=&x-success/error/cancel=
//     x-success 回传 lastPlayedUrl/position/duration/status(finished|stopped)/request-id
//     x-error   回传 errorCode(100~104,200~202)/errorMessage/failedUrl/request-id
//     x-cancel  仅「播放还没正式开始就取消」；进了播放器再退出算 x-success+stopped

// MARK: ① App 级回调桥

final class VidHubBridge: ObservableObject {
    static let shared = VidHubBridge()

    /// 外播结束事件。详情页订阅它，给用户一句「进度存了/看完了」的反馈。
    @Published var lastEvent: Event?

    enum Event: Equatable {
        case progressSaved(title: String, position: Double, duration: Double)
        case finished(title: String)
        case failed(title: String?, message: String)
        case cancelled(title: String?)
    }

    private struct Pending {
        let mediaId: Int
        let title: String
    }

    private var pending: [String: Pending] = [:]
    private let lock = NSLock()

    private init() {}

    /// 登记一次外播，返回 request-id（VidHub 原样带回）。
    /// 同一部片重复外播会覆盖旧登记，旧 request-id 来了按未知处理。
    @discardableResult
    func register(mediaId: Int, title: String) -> String {
        let id = UUID().uuidString
        lock.lock(); pending[id] = Pending(mediaId: mediaId, title: title); lock.unlock()
        // 兜底防漏：24 小时没来收尸就忘掉（用户可能看完直接在 VidHub 里干了别的）
        DispatchQueue.main.asyncAfter(deadline: .now() + 24 * 3600) { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.pending.removeValue(forKey: id); self.lock.unlock()
        }
        return id
    }

    /// App 收到 URL 的入口（挂在 App 根的 .onOpenURL）。
    /// 非isolated：系统可能从任意上下文递 URL 进来；内部按需回主线程发事件。
    func handleOpenURL(_ url: URL) {
        guard url.scheme == Self.scheme else { return }
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        guard comps?.host == "x-callback-url" else { return }
        // path = /x-callback-url/success | /error | /cancel
        let action = comps?.path.components(separatedBy: "/").last ?? ""
        let q = Dictionary(uniqueKeysWithValues: (comps?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        let requestId = q["request-id"] ?? ""

        lock.lock(); let p = pending[requestId]; lock.unlock()

        switch action {
        case "success": onSuccess(p, q)
        case "error":
            let event = Event.failed(title: p?.title,
                                     message: Self.errorMessage(code: Int(q["errorCode"] ?? ""),
                                                                raw: q["errorMessage"]))
            Task { @MainActor in self.lastEvent = event }
        case "cancel":
            let event = Event.cancelled(title: p?.title)
            Task { @MainActor in self.lastEvent = event }
        default: break
        }

        if !requestId.isEmpty {
            lock.lock(); pending.removeValue(forKey: requestId); lock.unlock()
        }
    }

    // MARK: 回调落地

    private func onSuccess(_ p: Pending?, _ q: [String: String]) {
        let title = p?.title ?? "影片"
        let pos = Double(q["position"] ?? "") ?? 0
        let dur = Double(q["duration"] ?? "") ?? 0
        let status = q["status"] ?? ""
        guard let mediaId = p?.mediaId else { return } // 没登记过的 request-id：无法归属，静默丢弃

        Task {
            guard let client = AppSession.shared.client else { return }
            // finished = 看完了；位置贴在片头（<=1s）也当看完。两者都清进度，
            // 否则「继续观看」里会躺着一条 100% 的记录，下次点进去又从结尾开始。
            let finished = status == "finished" || pos <= 1
            let report = finished ? 0.0 : pos
            try? await client.reportProgress(type: "media", id: mediaId,
                                             position: report, duration: dur)
            let event: Event = finished
                ? .finished(title: title)
                : .progressSaved(title: title, position: pos, duration: dur)
            await MainActor.run { self.lastEvent = event }
        }
    }

    /// errorCode → 人话。码表来自官方文档：
    /// 100 缺url / 101 url非法 / 102 position非法 / 103 scheme不支持 / 104 回调非法
    /// 200 播放失败 / 201 播放器忙 / 202 无法展示
    static func errorMessage(code: Int?, raw: String?) -> String {
        let detail = (raw?.isEmpty == false) ? "：\(raw!)" : ""
        switch code {
        case 100: return "播放地址缺失"
        case 101: return "播放地址无法解析（服务端地址可能变了）"
        case 102: return "起播位置无效"
        case 103: return "VidHub 不支持这个地址类型"
        case 104: return "回调地址无效"
        case 200: return "VidHub 播放失败\(detail)"
        case 201: return "VidHub 正在播放其他影片，先退出当前播放再试"
        case 202: return "VidHub 无法展示这个内容\(detail)"
        default:
            if let raw, !raw.isEmpty { return "VidHub：\(raw)" }
            return "VidHub 返回了未知错误"
        }
    }

    /// 自家 URL scheme。必须与 Info.plist 的 CFBundleURLTypes 一致，
    /// 否则系统根本不会把回调递进来（x-callback-url 要求调用方注册自己的 scheme）。
    static let scheme = "mediamanager"
}

// MARK: 字幕轨挑选

enum VidHubSubtitlePick {
    /// 选一条最合适的文本轨：中文 > 英文 > 默认 > 第一条。
    /// 图形轨（PGS/VOBSUB，text_based=false）直接出局——抽出来也没有文字。
    static func pick(_ streams: [APIClient.SubtitleStream]) -> APIClient.SubtitleStream? {
        let text = streams.filter { $0.textBased ?? false }
        guard !text.isEmpty else { return nil }
        return text.max(by: { score($0) < score($1) })
    }

    private static func score(_ s: APIClient.SubtitleStream) -> Int {
        let lang = (s.lang ?? "").lowercased()
        let title = s.title ?? ""
        var sc = 0
        // 语言标签：chi/zho/zh 家族一律算中文
        if lang.hasPrefix("chi") || lang.hasPrefix("zho") || lang == "zh" || lang.hasPrefix("cmn") {
            sc += 100
        } else if title.contains("中文") || title.contains("中字") || title.contains("简体") {
            sc += 90
        }
        // 同是中文时偏好简体
        if title.contains("简体") || title.contains("CHS") { sc += 20 }
        if title.contains("繁体") || title.contains("繁體") || title.contains("CHT") { sc += 5 }
        // 英文兜底
        if lang == "eng" || lang == "en" || title.contains("English") { sc += 50 }
        // 容器标记的默认轨微弱优先
        if s.isDefault ?? false { sc += 10 }
        return sc
    }

    /// 给等待界面看的一行说明，如「简体中文（ASS）」。
    static func label(_ s: APIClient.SubtitleStream) -> String {
        var name = (s.title?.isEmpty == false) ? s.title! : langName(s.lang)
        if let codec = s.codec, !codec.isEmpty {
            name += "（\(codec.uppercased())）"
        }
        return name
    }

    private static func langName(_ lang: String?) -> String {
        switch (lang ?? "").lowercased() {
        case "chi", "zho", "zh", "cmn", "chs", "zh-cn", "zh-hans": return "中文"
        case "eng", "en": return "英文"
        case "jpn", "ja": return "日文"
        default: return (lang?.isEmpty == false) ? lang! : "字幕"
        }
    }
}

// MARK: ② 页面级编排
// 隔离风格与项目内其它 ViewModel 一致：类本身不加 @MainActor，只给
// 「会碰 @Published / UIApplication」的方法加。

final class VidHubLauncher: ObservableObject {
    enum Phase: Equatable {
        case idle
        case probing                                                 // 查进度 + 探字幕轨
        case extracting(subLabel: String, elapsed: Int, eta: Int)    // 首次抽字幕（分钟级）
        case opening                                                 // 跳转中
    }

    @Published var phase: Phase = .idle
    @Published var error: String?
    /// VidHub 没装（canOpenURL=false）。调用方弹提示。
    @Published var vidHubMissing = false

    private struct Prepared {
        let mediaId: Int
        let mediaURL: URL
        let title: String
        let position: Double
    }

    private var pollTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var elapsed = 0
    /// 「不等字幕了，直接播」：由 skipSubtitle 置位，waitSubtitle 见到就收手。
    private var skipRequested = false
    /// 代际守卫：play()/cancel()/deinit 各递增一代。run() 每个 await 之后对一遍，
    /// 代数变了就收手——「用户返回了页面 / 取消了」时不该再把人拽进 VidHub。
    private var generation = 0

    deinit {
        generation += 1
        pollTask?.cancel()
        tickTask?.cancel()
    }

    func play(_ d: MediaDetail) {
        Task { @MainActor in
            guard self.phase == .idle else { return } // 防连点
            self.generation += 1
            let gen = self.generation
            self.error = nil
            self.vidHubMissing = false
            self.skipRequested = false
            self.phase = .probing
            await self.run(d, gen: gen)
        }
    }

    /// 抽字幕等不及了：停轮询，让 run() 立刻走「不带字幕」分支跳转。
    /// （不在这里直接跳转——跳转只留 run() 一条路，否则会开两次 VidHub。）
    func skipSubtitle() {
        Task { @MainActor in
            self.skipRequested = true
            self.pollTask?.cancel(); self.pollTask = nil
            self.tickTask?.cancel(); self.tickTask = nil
        }
    }

    /// 整个放弃。
    func cancel() {
        Task { @MainActor in
            self.generation += 1
            self.pollTask?.cancel(); self.pollTask = nil
            self.tickTask?.cancel(); self.tickTask = nil
            self.phase = .idle
        }
    }

    // MARK: 主流程

    @MainActor
    private func run(_ d: MediaDetail, gen: Int) async {
        defer { if self.phase != .idle { self.phase = .idle } }

        guard let client = AppSession.shared.client else {
            error = "未连接服务器"; return
        }
        guard let path = d.videoFiles.first, !path.isEmpty else {
            error = "《\(d.title)》没有可播放的文件"; return
        }
        // ⚠️ 不能用 client.streamURL(path:)：那个方法只放行 MP4/M4V/MOV
        //（AVPlayer 解不了的容器返回 nil）。VidHub 自带解码器，MKV/HEVC/DTS
        // 都能解，所以绕开扩展名过滤，直接给原始文件流地址。
        guard let mediaURL = client.makeURL("/stream", queryItems: [
            URLQueryItem(name: "path", value: path)
        ]) else {
            error = "拼接播放地址失败"; return
        }

        // ① 续播位置（本地库查询，几十毫秒；失败不拦播放）。
        // 贴片尾的（看完九成以上）不如从头放——不然点进去又是最后几分钟。
        var position: Double = 0
        if let prog = try? await client.fetchMediaProgress(id: d.id) {
            let nearEnd = prog.duration > 0 && prog.position > prog.duration - 30
            position = nearEnd ? 0 : prog.position
        }
        guard gen == generation else { return } // 等待期间用户走了/取消了

        // ② 内嵌字幕：探轨 →（未缓存）异步抽取。
        // 任何一步失败都只当「没有字幕」，绝不为字幕废掉播放。
        var subURL: URL?
        if let streams = try? await client.fetchSubtitleStreams(path: path),
           let best = VidHubSubtitlePick.pick(streams),
           let url = client.subtitleExtractURL(path: path, index: best.index,
                                               asASS: best.codec == "ass" || best.codec == "ssa") {
            if await waitSubtitle(url, label: VidHubSubtitlePick.label(best)) {
                subURL = url
            }
        }
        guard gen == generation else { return } // 抽字幕等一半用户走了/取消了

        phase = .opening
        openVidHub(Prepared(mediaId: d.id, mediaURL: mediaURL,
                            title: d.title, position: position), subURL: subURL)
    }

    /// 等字幕就绪。200 = 已缓存（秒回）；202 = 已开始在抽，轮询等它。
    /// - Returns: true = 可以带字幕跳转；false = 不带字幕（失败/没网/用户跳过）
    @MainActor
    private func waitSubtitle(_ url: URL, label: String) async -> Bool {
        guard let (data, resp) = try? await URLSession.shared.data(from: url),
              let http = resp as? HTTPURLResponse else {
            return false // 网络层就挂了：不带字幕播，别为字幕废掉播放
        }
        if http.statusCode == 200 { return true }
        guard http.statusCode == 202 else { return false } // 4xx/5xx：参数错或抽取失败

        elapsed = 0
        phase = .extracting(subLabel: label, elapsed: 0, eta: Self.parseETA(data) ?? 120)
        startTicker()

        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if Task.isCancelled { return false }
            guard let (d2, r2) = try? await URLSession.shared.data(from: url),
                  let http2 = r2 as? HTTPURLResponse else { continue } // 抖动：接着等
            if http2.statusCode == 200 { return true }
            if http2.statusCode != 202 { return false } // 502：抽失败，不带字幕播
        }
        return false // skipRequested / cancel：subURL 留空，走无字幕分支
    }

    @MainActor
    private func startTicker() {
        tickTask?.cancel()
        elapsed = 0
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { break }
                guard let self else { break }
                self.elapsed += 1
                if case .extracting(let label, _, let eta) = self.phase {
                    self.phase = .extracting(subLabel: label, elapsed: self.elapsed, eta: eta)
                }
            }
        }
    }

    // MARK: 跳转

    @MainActor
    private func openVidHub(_ p: Prepared, subURL: URL?) {
        let requestId = VidHubBridge.shared.register(mediaId: p.mediaId, title: p.title)
        guard let url = Self.buildVidHubURL(p, subURL: subURL, requestId: requestId) else {
            error = "拼接 VidHub 地址失败"
            return
        }
        // ⚠️ canOpenURL 必须在 Info.plist 的 LSApplicationQueriesSchemes 里
        // 声明 open-vidhub，否则一律返回 false（装了也当成没装）。
        if UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
        } else {
            vidHubMissing = true
        }
    }

    /// 拼 open-vidhub://x-callback-url/play。
    /// position 官方区间 0...31536000 秒；回调地址必须带 scheme 且不能是
    /// open-vidhub（自家 scheme，见 Info.plist CFBundleURLTypes）。
    // ⚠️ 必须是 private：Prepared 是 private 嵌套类型，Swift 不允许 internal
    // 方法的参数使用比它更严格的类型（否则报 "Method cannot be declared
    // internal because its parameter uses a private type"）。
    private static func buildVidHubURL(_ p: Prepared, subURL: URL?, requestId: String) -> URL? {
        var comp = URLComponents()
        comp.scheme = "open-vidhub"
        comp.host = "x-callback-url"
        comp.path = "/play"

        var pos = p.position
        if pos < 1 { pos = 0 } // 贴片头不用续播
        pos = min(max(pos, 0), 31536000)

        var items = [
            URLQueryItem(name: "url", value: p.mediaURL.absoluteString),
            URLQueryItem(name: "filename", value: p.title),
            URLQueryItem(name: "x-source", value: "媒体库"),
            URLQueryItem(name: "request-id", value: requestId),
            URLQueryItem(name: "x-success", value: "\(VidHubBridge.scheme)://x-callback-url/success"),
            URLQueryItem(name: "x-error", value: "\(VidHubBridge.scheme)://x-callback-url/error"),
            URLQueryItem(name: "x-cancel", value: "\(VidHubBridge.scheme)://x-callback-url/cancel"),
        ]
        if pos >= 1 {
            // 秒数取整：VidHub 只认「valid number」，整数最稳
            items.append(URLQueryItem(name: "position", value: String(Int(pos.rounded()))))
        }
        if let subURL {
            items.append(URLQueryItem(name: "sub", value: subURL.absoluteString))
        }
        comp.queryItems = items
        return comp.url
    }

    /// 202 响应体里的 eta_seconds（服务端按文件体积/读取速度估的）。
    private static func parseETA(_ data: Data) -> Int? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let eta = obj["eta_seconds"] as? Int else { return nil }
        return eta
    }
}

// MARK: ③ 等待反馈浮层

/// 外播准备中的全屏反馈。抽字幕是分钟级的等待——
/// 干转圈最大的问题不是慢，是不知道还要等多久（内置播放器的 PreparingOverlay
/// 同款思路）：把「在等什么 / 等了多久 / 预计还要多久 / 随时可以不等了」写清楚。
struct VidHubPreparingOverlay: View {
    @ObservedObject var launcher: VidHubLauncher
    let title: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.65).ignoresSafeArea()
            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)

                Text(title)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)

                Text(phaseText)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center)

                if case .extracting(_, let elapsed, let eta) = launcher.phase {
                    Text("已等待 \(Self.clock(elapsed))，预计还要 \(Self.clock(max(eta - elapsed, 0)))")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.55))
                        .monospacedDigit()
                }

                if case .extracting = launcher.phase {
                    // 一等几分钟的等待，必须给「不等了」的出口
                    Button("直接播放（不带字幕）") { launcher.skipSubtitle() }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(.white))
                }

                Button("取消") { launcher.cancel() }
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.6))
            }
            .padding(32)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .padding(.horizontal, 40)
        }
    }

    private var phaseText: String {
        switch launcher.phase {
        case .probing:
            return "正在查询续播进度与内嵌字幕…"
        case .extracting(let subLabel, _, _):
            return "正在抽取内嵌字幕（\(subLabel)）\n首次需要把整个文件读一遍，之后永久缓存"
        case .opening:
            return "正在唤起 VidHub…"
        case .idle:
            return ""
        }
    }

    /// 秒 → m:ss（超过一小时 → h:mm:ss）
    static func clock(_ seconds: Int) -> String {
        PlayerTimeFormatter.string(Double(seconds))
    }
}
