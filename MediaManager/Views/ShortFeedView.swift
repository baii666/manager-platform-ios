import SwiftUI
import Combine
import UIKit

// MARK: - 当前页播放引擎句柄
// 刷流的右上角图标（画中画 / 投屏）钉在屏幕上不动，但要作用在**当前**那条视频上。
// 每页播放器在成为当前页时把引擎报上来（换页就换引擎），这里只做持有 + 变更转发：
// 引擎的 @Published 变化要能让外层 UI 刷新，光存一个引用是不够的。
final class FeedEngineHandle: ObservableObject {
    private(set) var engine: PlayerEngine?
    private var bag: AnyCancellable?

    func attach(_ engine: PlayerEngine) {
        bag?.cancel()
        self.engine = engine
        // 转发引擎的 objectWillChange：isPiPActive / rate 这类状态变了，外层按钮跟着换图标
        bag = engine.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }
}

// MARK: - 刷流底栏状态（收藏 / 连播 / 倍速）
// ⚠️ 刻意独立成 class 而不是塞进 View 的 @State：播放结束回调要长期挂在
//    PlayerEngine 上，闭包若捕获 View（struct），会经 @StateObject engineHandle
//    → engine → 闭包 形成环，换页后旧引擎永远释放不掉（每条视频泄漏一个 AVPlayer）。
//    这里让闭包只 [weak controls]，不碰 engineHandle，环就断了。
final class ShortFeedControls: ObservableObject {
    /// 已收藏的短视频 id（type = "short"，对接 /api/actions/favorite）
    @Published var favoriteIDs: Set<Int> = []
    @Published var favoriteBusy = false
    /// 连播：播完自动滚到下一条；关掉则退回单条循环（原来的行为）
    @Published private(set) var autoAdvance: Bool
    /// 全局倍速：换页后自动应用到新引擎，不会每滑一条就跳回 1x
    @Published private(set) var rate: Float
    /// 播放结束 → 请求切下一条。值是「刚播完那条」的 id，外层据此找下一条。
    @Published var advanceRequest: Int? = nil

    private static let advanceKey = "shortFeed.autoAdvance"
    private static let rateKey = "shortFeed.rate"

    init() {
        // register 只提供「没存过」时的默认值，用户存过的不会被覆盖
        UserDefaults.standard.register(defaults: [
            Self.advanceKey: true,
            Self.rateKey: 1.0,
        ])
        autoAdvance = UserDefaults.standard.bool(forKey: Self.advanceKey)
        rate = Float(UserDefaults.standard.double(forKey: Self.rateKey))
    }

    // ⚠️ 刻意用显式方法而不是 @Published + didSet：带 property wrapper 的属性
    //    加观察者在部分 Swift 版本会编译报错，持久化放到写入点最稳。
    func setAutoAdvance(_ on: Bool) {
        autoAdvance = on
        UserDefaults.standard.set(on, forKey: Self.advanceKey)
    }

    func setRate(_ r: Float) {
        rate = r
        UserDefaults.standard.set(Double(r), forKey: Self.rateKey)
    }

    /// 从 AVPlayerItemDidPlayToEndTime 通知回调调用。该通知注册在 queue: .main，
    /// 所以回调本来就在主线程，直接写 @Published 即可，不必再包一层 Task。
    func requestAdvance(from id: Int) {
        advanceRequest = id
    }

    @MainActor
    func loadFavorite(id: Int, client: APIClient?) async {
        guard let client else { return }
        do {
            // 短视频在统一行为层里的资产类型是 "short"，不是 "shorts"
            let on = try await client.fetchFavorite(type: "short", id: id)
            if on { favoriteIDs.insert(id) } else { favoriteIDs.remove(id) }
        } catch {
            // 收藏状态拿不到不该挡住刷流，静默即可（下次切回来会再查）
        }
    }

    @MainActor
    func toggleFavorite(id: Int, client: APIClient?) async {
        guard let client, !favoriteBusy else { return }
        favoriteBusy = true
        defer { favoriteBusy = false }
        let next = !favoriteIDs.contains(id)
        // 乐观更新，点了一下立刻有反馈
        if next { favoriteIDs.insert(id) } else { favoriteIDs.remove(id) }
        do {
            let confirmed = try await client.setFavorite(type: "short", id: id, on: next)
            if confirmed { favoriteIDs.insert(id) } else { favoriteIDs.remove(id) }
        } catch {
            // 失败回滚到操作前的状态
            if next { favoriteIDs.remove(id) } else { favoriteIDs.insert(id) }
        }
    }
}

// MARK: - 刷流预加载池（地址 + 首帧缓冲）
// 目标：播当前条时就把「下一条」备好，滑过去零等待。分两层：
//   1. 地址层：提前解析并缓存 PlaybackTarget。直连 MP4 只是同步拼 URL（零成本）；
//      非直连容器要开 HLS 会话（服务端会起 ffmpeg），**只给紧邻下一条**开，一次最多一个。
//   2. 缓冲层：PlayerEngine 给离屏页设 preferredForwardBufferDuration + preroll，
//      AVPlayer 在暂停态也会把首段数据与首帧准备好（见 PlayerEngine）。
// ⚠️ 旧实现的「±2 窗口」只在 currentIndex 更新后（滚动停稳）才解析地址，等于没提前；
//    这里由外层 .task(id: currentID) 主动预热，页面 body 同步读缓存，视图一出现就能渲染播放器。
// ⚠️ 正在进行的解析按 id 存 Task：页面 await 同一个 Task，不会重复开会话。
// ⚠️ 刻意不标 @MainActor（类与方法都不标）：
//    1. SwiftUI 的 ObservableObject 协议要求 objectWillChange 非隔离，类级标注会顶协议；
//    2. body / .task / .onChange 的隔离上下文在不同 SDK 版本不完全一致，方法非隔离
//       才能在任何调用点直接调，不必插 await MainActor.run。
//    实际读写全部发生在主线程（SwiftUI 调用链 + prepare 的 @MainActor），
//    Task 内也显式 @MainActor；字典只做简单值读写，不构成跨线程竞态。
final class ShortFeedPrefetcher: ObservableObject {
    /// 让挂在页面上的 @ObservedObject 在缓存落地时重算 body（placeholder → 播放器）
    @Published private(set) var revision = 0
    /// 已解析完成的地址
    private var resolved: [Int: PlaybackTarget] = [:]
    /// 正在进行的完整解析（非直连容器要发请求 / 开 HLS 会话），按 id 去重
    private var inflight: [Int: Task<PlaybackTarget?, Never>] = [:]
    /// 最近一个非直连预解析的 id。快速连滑时旧的会话还没用上就过期了，
    /// 起新的之前把旧的取消，保证服务端同时最多只有一个为预加载开的转码会话。
    private var hlsInflightID: Int? = nil

    /// 当前页一确定就调用。顺序按「下滑方向优先」：下一条 > 下两条 > 上一条 > 上两条。
    /// allowHLS 只给紧邻下一条为 true，避免一次起多个服务端转码会话。
    func prefetch(around index: Int, items: [ShortVideo], client: APIClient?) {
        guard let client else { return }
        let before = resolved.count
        let plan: [(Int, Bool)] = [(1, true), (2, false), (-1, false), (-2, false)]
        for (offset, allowHLS) in plan {
            let i = index + offset
            guard i >= 0, i < items.count else { continue }
            start(items[i], client: client, allowHLS: allowHLS)
        }
        trim(around: index, items: items)
        // 一批地址只发一次变更，别让 5 页 × 4 次 body 重算落在滚动刚停的那一帧
        if resolved.count != before { revision += 1 }
    }

    /// 同步快查：页面 body 里直接用，视图一出现就能渲染播放器，不必等 .task 跑完
    func cachedTarget(for id: Int) -> PlaybackTarget? { resolved[id] }

    /// 页面 prepare 时用：已解析直接回，正在解析就等同一个 Task（不重复请求）
    func resolvedTarget(for id: Int) async -> PlaybackTarget? {
        if let t = resolved[id] { return t }
        guard let task = inflight[id] else { return nil }
        return await task.value
    }

    /// 页面自己解析成功后回填，回滑时零等待
    func store(_ target: PlaybackTarget, for id: Int) {
        resolved[id] = target
        revision += 1
    }

    private func start(_ video: ShortVideo, client: APIClient, allowHLS: Bool) {
        guard resolved[video.id] == nil, inflight[video.id] == nil,
              let path = video.filePath, !path.isEmpty else { return }
        // 99% 的短视频是 MP4/M4V/MOV：同步拼直连 URL，零网络、零服务端成本。
        // 这里直接写字典、不逐条发变更，由 prefetch 末尾统一发一次。
        if let url = client.streamURL(path: path) {
            resolved[video.id] = PlaybackTarget(url: url, title: video.titleText,
                                                assetType: nil, assetID: nil,
                                                startAt: 0, timeOffset: 0,
                                                knownDuration: video.duration, sourcePath: path)
            return
        }
        guard allowHLS else { return }
        let id = video.id
        if let old = hlsInflightID, old != id, let stale = inflight.removeValue(forKey: old) {
            stale.cancel()
        }
        hlsInflightID = id
        inflight[id] = Task { @MainActor [weak self] in
            let t = try? await resolveShortPlayback(video, path: path, client: client)
            if let t { self?.store(t, for: id) }
            self?.inflight.removeValue(forKey: id)
            // 不用 optional chaining 直接比（会变成 Int??）：显式解包成单层可选
            if let s = self, s.hlsInflightID == id { s.hlsInflightID = nil }
            return t
        }
    }

    /// 缓存很轻（一个 URL + 几个字符串），只在刷了几百条之后才清理一次；
    /// 保留 ±20，正常滚动绝不会把还在窗口内的页清掉。in-flight 的 Task 不动
    /// （可能正被页面 await），它自己完成时会回填 / 移除。
    private func trim(around index: Int, items: [ShortVideo]) {
        guard resolved.count > 200, !items.isEmpty else { return }
        let lo = max(0, index - 20)
        let hi = min(items.count - 1, index + 20)
        guard lo <= hi else { return }
        var keep = Set<Int>()
        for i in lo...hi { keep.insert(items[i].id) }
        // 不在 trim 里单独发变更：prefetch 末尾按 count 变化统一发一次
        resolved = resolved.filter { keep.contains($0.key) }
    }
}

// MARK: - 真随机刷流队列
// 旧「随机连播」只随机挑一个起始下标，队列仍是 /api/shorts/videos 的
// created_desc 顺序分页 —— 同目录 / 同批入库的视频连成一片，看着就是顺序播放。
// 这里改由后端 /api/shorts/random（ORDER BY RANDOM()）分批供给整条队列：
// 每批 30 条，按 id 本地去重后 append，滑到队尾继续补，形成可持续的随机流。
// 刻意不新增 Swift 文件（xcodegen 红线），与 ShortFeedPrefetcher 同放本文件。
final class ShortRandomFeedLoader: ObservableObject {
    @Published private(set) var items: [ShortVideo] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private let batchSize = 30
    /// 已出现过的 id：后端每批都是全库重新抽，跨批会重复，必须本地去重
    private var seen = Set<Int>()
    private var total = Int.max
    private var poolId: Int?
    private var client: APIClient?
    /// 连续两批全重复 → 认为这个范围已刷遍，停止再请求（小池不会空转）
    private var emptyStreak = 0

    private var hasMore: Bool { emptyStreak < 2 && seen.count < total }

    /// 只在首次进入时拉第一批；client 从常驻的列表 VM 借，不另建会话
    func start(poolId: Int?, client: APIClient?) async {
        guard items.isEmpty, !isLoading else { return }
        self.poolId = poolId
        guard let client else {
            errorMessage = "未连接服务器"
            return
        }
        self.client = client
        await loadMore()
        if items.isEmpty, errorMessage == nil {
            errorMessage = "这个范围没有可随机播放的视频"
        }
    }

    func loadMore() async {
        guard let client, !isLoading, hasMore else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let (batch, totalCount) = try await client.fetchShortRandomBatch(
                poolId: poolId, size: batchSize)
            total = totalCount
            var fresh: [ShortVideo] = []
            for v in batch where !seen.contains(v.id) {
                seen.insert(v.id)
                fresh.append(v)
            }
            if fresh.isEmpty {
                emptyStreak += 1
            } else {
                emptyStreak = 0
                items.append(contentsOf: fresh)
            }
            errorMessage = nil
        } catch {
            // 不弹错打断刷流：已有队列继续看，下次滑到队尾会再试
            errorMessage = error.localizedDescription
        }
    }

    /// 重试：重新绑定 client（可能刚重连 / 换过服务器），并清掉耗尽标记
    func retry(poolId: Int?, client: APIClient?) async {
        self.poolId = poolId
        guard let client else {
            errorMessage = "未连接服务器"
            return
        }
        self.client = client
        errorMessage = nil
        emptyStreak = 0
        await loadMore()
    }
}

// MARK: - 抖音式短视频刷流
// 短视频页点开某一条后，进入这个全屏的、上下滑切片的刷流。
// 对齐抖音的交互：一屏一条、上下滑切换、当前页自动循环播、滑到末尾自动加载更多，
// 每条视频自带一条底部信息区（标题 / 简介 / 进度条 / 关联内容 / 收藏·连播·倍速）。
//
// 实现要点：
//   1. 垂直分页用 iOS 17 的 ScrollView + .scrollTargetBehavior(.paging) + containerRelativeFrame，
//      每页占满整屏，比 TabView 旋转 hack 干净。
//   2. 复用 VideoPlayerView（手势/倍速/降级/进度上报都在），加 loop + isActive：
//      当前页循环播放，滑走暂停、滑回来续播。
//   3. 只对当前页 ±2 的窗口起 AVPlayer（更远的只挂封面占位，避免 1 万多条把内存吃爆）；
//      地址解析不依赖这个窗口：外层 ShortFeedPrefetcher 在播当前条时就把相邻页备好，
//      离屏页还会设前向缓冲并预卷首帧，滑过去不用重新握手 / 等首帧（无缝下滑）。
//   4. 短视频 99% 是 MP4，streamURL 同步拿地址、零等待；AVI/MKV 才走 HLS 会话。
//   5. 信息区挂在**每一页内部**（FeedBottomBar）：上滑时随本页一起滚走、下一条的
//      从屏幕下方升上来；固定层只留右上角画中画/投屏与顶部关闭。进度条绑本页引擎，
//      全局状态（收藏 / 连播 / 倍速）仍由外层 ShortFeedControls 共享。
//   6. randomMode = 真随机连播：队列改由 ShortRandomFeedLoader 从
//      /api/shorts/random 分批抽取（本地按 id 去重、滑到队尾自动补），
//      不再是「随机起点 + created_desc 顺序队列」。
struct ShortFeedView: View {
    @ObservedObject var viewModel: ShortsViewModel
    let startIndex: Int
    /// true = 真随机刷流：队列由 randomLoader 供给，不用列表 VM 的顺序分页
    var randomMode: Bool = false
    /// 退出回调：关掉根层 overlay 回到**进来时的那个 tab**（首页进的回首页、
    /// 短视频页进的回短视频页）—— 刷流挂在 RootView 的 overlay 上，背后就是来源页
    var onClose: () -> Void = {}
    /// 退出动画**开始**的回调：此刻恢复底栏（.opacity 渐显），
    /// 等页面滑开时底栏已经在位。等 onClose 再恢复的话，页面已滑开、底栏才冒出来。
    ///
    /// ⚠️ 状态栏不在这里处理：它曾经走「打开时隐藏、退出时恢复」的路子，
    /// 但状态栏显隐是系统级的、无法动画，它一出现窗口 safeArea 就变、背后页面
    /// 跟着重排 —— 无论提前到动画开始还是延到 close，用户都能看到那一下「闪」。
    /// 所以改成刷流期间状态栏一直在（RootView 的 statusBarHidden 不含刷流），
    /// 退出时零变化。
    var onBeginExit: () -> Void = {}

    /// 右上角固定图标（投屏 / 画中画）要作用在**当前**视频上 —— 每页播放器在成为
    /// 当前页时把引擎报上来，换页就换引擎；按钮本身钉在屏幕上不动。
    @StateObject private var engineHandle = FeedEngineHandle()
    /// 底栏三件套的状态（收藏 / 连播 / 倍速），独立于引擎，见上面 ShortFeedControls 注释
    @StateObject private var controls = ShortFeedControls()
    /// 相邻页的地址预取缓存：播当前条时就把下一条备好，切过去零等待
    @StateObject private var prefetcher = ShortFeedPrefetcher()
    /// 真随机队列：每次打开都随 ShortFeedView 一起重建（RootView .id(generation)），
    /// 所以每次进随机连播都是一批全新的随机视频
    @StateObject private var randomLoader = ShortRandomFeedLoader()
    /// 当前正在看的页（scrollPosition 跟踪，滑到哪更新到哪）
    @State private var currentID: Int?
    @State private var currentIndex: Int
    /// 右滑退出：页面向右的拖动偏移（只向右、严格水平）
    @State private var dragOffsetX: CGFloat = 0
    @State private var isExiting = false
    /// 连播播完时用它滚到下一条。只在本视图生命周期内持有，不跨重建缓存。
    @State private var scrollProxy: ScrollViewProxy?
    /// 非nil 时弹「同文件夹关联视频页」（item 式 fullScreenCover，跟随当前视频换内容）
    @State private var relatedVideo: ShortVideo?
    // 进度条手势态 / 简介展开态已下沉到每页的 FeedBottomBar（各自独立，
    // 换页天然不带旧状态，不需要在外层重置）。

    /// 预加载窗口半径：当前页 ±2
    private let windowRadius = 2

    init(viewModel: ShortsViewModel, startIndex: Int,
         randomMode: Bool = false,
         onClose: @escaping () -> Void = {},
         onBeginExit: @escaping () -> Void = {}) {
        self.viewModel = viewModel
        self.startIndex = startIndex
        self.randomMode = randomMode
        self.onClose = onClose
        self.onBeginExit = onBeginExit
        // 随机模式的队列要等首批网络结果，此刻为空 → currentID 从 nil 起，
        // 由 .task 里的 start() 完成后设为第一条；顺序模式沿用列表快照。
        let initial: [ShortVideo] = randomMode ? [] : viewModel.items
        let idx = min(max(startIndex, 0), max(initial.count - 1, 0))
        _currentIndex = State(initialValue: idx)
        _currentID = State(initialValue: initial.indices.contains(idx) ? initial[idx].id : nil)
    }

    /// 刷流队列：随机模式用随机批次，其余用列表 VM 的顺序分页。
    /// 预取 / 连播 / 关联页回跳都只认它，不各自去读 viewModel.items。
    private var items: [ShortVideo] { randomMode ? randomLoader.items : viewModel.items }

    private func loadMore() async {
        if randomMode { await randomLoader.loadMore() } else { await viewModel.loadMore() }
    }

    /// 首批随机队列落地后把 scrollPosition 落到第一条（含失败后重试成功的场景）
    private func settleRandomStart() {
        if currentID == nil, let first = randomLoader.items.first {
            currentIndex = 0
            currentID = first.id
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()

            // 真随机首批要等一次网络请求；队列为空时给个明确的加载/失败态，
            // 而不是一片黑屏。关闭按钮与右上角图标都在本层之后，仍可点。
            if randomMode && items.isEmpty {
                ZStack {
                    Color.black.ignoresSafeArea()
                    VStack(spacing: 14) {
                        if let msg = randomLoader.errorMessage {
                            Image(systemName: "shuffle")
                                .font(.system(size: 34))
                                .foregroundStyle(.white.opacity(0.55))
                            Text(msg)
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.8))
                                .multilineTextAlignment(.center)
                            Button("重试") {
                                Task {
                                    await randomLoader.retry(poolId: viewModel.poolId,
                                                             client: viewModel.client)
                                    settleRandomStart()
                                }
                            }
                                .buttonStyle(.bordered)
                                .tint(.white)
                        } else {
                            ProgressView().tint(.white)
                            Text("正在抽取随机视频…")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.65))
                        }
                    }
                    .padding(.horizontal, 32)
                }
            }

            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, video in
                            ShortFeedPage(video: video,
                                          client: viewModel.client,
                                          isActive: index == currentIndex,
                                          inWindow: abs(index - currentIndex) <= windowRadius,
                                          controls: controls,
                                          prefetcher: prefetcher,
                                          onRelated: { relatedVideo = $0 },
                                          onEngineReady: { engine in
                                              engineHandle.attach(engine)
                                              configure(engine, for: video.id)
                                          })
                                .containerRelativeFrame([.horizontal, .vertical])
                                .id(video.id)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: $currentID)
                .scrollIndicators(.hidden)
                .ignoresSafeArea()
                .onAppear { scrollProxy = proxy }
            }

            // 统一关闭入口（播放器里 xmark 已隐藏，避免两个按钮叠一起）。
            // 与右滑走同一条退出动画：有动画缓冲，底栏渐显才不会硬切
            Button { beginExit() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(Color.black.opacity(0.45)))
            }
            // 顶部按钮按安全区排布（本层不再 ignoresSafeArea）：
            // 状态栏常驻不隐藏，按钮要落在它下面
            .padding(.top, 8)
            .padding(.leading, 16)

            // 右上角固定图标组：画中画 + 投屏。
            // ⚠️ 钉在屏幕上，不随上下滑切视频移动；作用的引擎换成当前页的。
            HStack(spacing: 12) {
                if let engine = engineHandle.engine, engine.isPiPSupported {
                    Button { engine.togglePiP() } label: {
                        Image(systemName: engine.isPiPActive ? "pip.exit" : "pip.enter")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(Color.black.opacity(0.35)))
                    }
                    .buttonStyle(.plain)
                }
                AirPlayButton()
                    .frame(width: 30, height: 30)
            }
            // 撑满只为把按钮推到右上（透明区域不吃手势，滑动照常）
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(.trailing, 16)
            .padding(.top, 8)

            // 信息区（标题 / 简介 / 进度条 / 关联内容 / 收藏·连播·倍速）已下沉到
            // 每一页内部：上滑时随本页一起滚走、下一条的从下方升上来（抖音式）。
            // 右上角画中画 / 投屏 / 顶部关闭仍钉在屏幕上，不随页滚。
        }
        // 右滑退出：页面跟手向右移动，松手超过阈值向右滑出屏幕（露出背后的来源页）
        .offset(x: dragOffsetX)
        // ⚠️ 本层**不加** ignoresSafeArea（视频层/黑底各自加了，照样铺满全屏）。
        // 加在整层上会把安全区 inset 清零，关闭按钮就压到状态栏上了；
        // 而且刷流期间状态栏不再隐藏，也没有「跟着 safeArea 下移」的问题要防。
        .simultaneousGesture(exitDragGesture)
        // 状态栏保持系统默认（常驻显示）：由 RootView 统一控制，刷流不参与隐藏
        .onChange(of: currentID) {
            guard let id = currentID,
                  let idx = items.firstIndex(where: { $0.id == id }) else { return }
            currentIndex = idx
            // 滑到倒数第 3 条就补下一批（随机模式补随机批次，顺序模式翻下一页）
            if idx >= items.count - 3 {
                Task { await loadMore() }
            }
        }
        // 当前页一确定（含首次进入）就做两件事：先同步预热相邻页地址，再查收藏。
        // ⚠️ 不能靠页面自己的 inWindow —— 那个值只在滚动停稳后 currentIndex 才更新，
        //    等于没提前。这里主动解析完缓存，页面 body 同步读，视图一出现就有播放器。
        // 每切一条查一次收藏状态（请求很轻；失败静默，不挡刷流）
        .task(id: currentID) {
            guard let id = currentID else { return }
            if let idx = items.firstIndex(where: { $0.id == id }) {
                prefetcher.prefetch(around: idx, items: items, client: viewModel.client)
            }
            await controls.loadFavorite(id: id, client: viewModel.client)
        }
        // 队列追加了新数据（顺序翻页 / 随机补批）：补一次预取，跨批加载后仍无缝
        .onChange(of: items.count) {
            guard let id = currentID,
                  let idx = items.firstIndex(where: { $0.id == id }) else { return }
            prefetcher.prefetch(around: idx, items: items, client: viewModel.client)
        }
        // 真随机首批：拿到结果后把 scrollPosition 落到第一条。
        // 用 onAppear 而不是再叠一个 .task（同一视图多个 .task 行为不稳）；
        // loader.start 自带 guard，重复 appear 不会重复抽批次把队列打乱。
        .onAppear {
            guard randomMode else { return }
            Task {
                await randomLoader.start(poolId: viewModel.poolId, client: viewModel.client)
                settleRandomStart()
            }
        }
        // 连播开关：立刻改当前引擎的「播完通知」。关掉就退回单条循环。
        .onChange(of: controls.autoAdvance) {
            guard let engine = engineHandle.engine, let id = currentID else { return }
            configure(engine, for: id)
        }
        // 全局倍速：即时生效，且下一条 attach 时也会重新应用
        .onChange(of: controls.rate) {
            engineHandle.engine?.setRate(controls.rate)
        }
        // 播完 → 自动滚到下一条
        .onChange(of: controls.advanceRequest) {
            guard let id = controls.advanceRequest else { return }
            controls.advanceRequest = nil
            advance(from: id)
        }
        // 关联页盖上来时暂停当前视频（不然声音一直垫底）、关掉后恢复；
        // 用户下滑手势关 cover 也会把 item 重置回 nil，统一走这里恢复播放。
        // 恢复用 play()：它会写 player.rate = rate，倍速不会被打回 1x。
        .onChange(of: relatedVideo) {
            guard let engine = engineHandle.engine else { return }
            if relatedVideo == nil { engine.play() } else { engine.pause() }
        }
        // 标题点击 → 同文件夹关联视频页。页内点卡片一律直接起播放器：
        // 以前还分「命中刷流队列就关页 + scrollTo 回跳」一支，关 cover 时
        // 滚动常被吞掉，看起来像点了没反应；现在两条路统一。
        .fullScreenCover(item: $relatedVideo) { v in
            ShortRelatedView(video: v, client: viewModel.client)
        }
    }

    // MARK: 播放设置 / 连播

    /// 每个引擎成为当前页时都要重新应用一次全局设置：倍速是全局的，
    /// 播完通知按当前连播开关挂（或清空）。闭包只 [weak controls]，不碰 engineHandle。
    private func configure(_ engine: PlayerEngine, for id: Int) {
        engine.setRate(controls.rate)
        let ctrls = controls
        if controls.autoAdvance {
            engine.onPlaybackEnd = { [weak ctrls] in
                ctrls?.requestAdvance(from: id)
            }
        } else {
            engine.onPlaybackEnd = nil
        }
    }

    /// 连播：滚到刚播完那条的下一条。已经是最后一条时什么都不做 ——
    /// 引擎在播完那一刻已经 seek 回 0 继续循环了，不会卡在静止画面。
    private func advance(from id: Int) {
        guard controls.autoAdvance,
              let idx = items.firstIndex(where: { $0.id == id }),
              idx + 1 < items.count else { return }
        let nextID = items[idx + 1].id
        if let proxy = scrollProxy {
            withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(nextID, anchor: .top) }
            // 兜底：paging + containerRelativeFrame 下 scrollTo 偶尔第一次不落地。
            // 0.35s 后若仍停在刚播完那条（说明既没切成功、用户也没自己滑走），
            // 再滚一次；切页成功时 currentID 已变成 nextID，这里直接跳过，
            // 用户中途手动滑走时 currentID 变成别的值，同样跳过，不抢他的位置。
            let originID = id
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                guard self.currentID == originID else { return }
                withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(nextID, anchor: .top) }
            }
        } else {
            withAnimation(.easeInOut(duration: 0.3)) { currentID = nextID }
        }
    }

    /// 右滑退出：只响应严格水平的向右拖动（dx>0 且 dx>abs(dy)），页面跟手右移；
    /// 松手超阈值 → 向右滑出屏幕并退出；否则弹回。上下滑切视频完全不飘。
    /// ⚠️ 起点落在底部进度条热区（约 34pt）内一律不参与：进度条用的是
    ///    .simultaneousGesture，向右拖 seek 时本手势也会同时收到，不挡的话整页
    ///    会跟着右移，超过 100pt 甚至直接退出刷流。
    private var exitDragGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                guard !isExiting, !startsInBottomBar(value.startLocation.y) else { return }
                let dx = value.translation.width
                let dy = value.translation.height
                if dx > 0, dx > abs(dy) {
                    dragOffsetX = dx
                }
            }
            .onEnded { value in
                guard !isExiting, !startsInBottomBar(value.startLocation.y) else { return }
                let dx = value.translation.width
                let dy = value.translation.height
                if dx > 100, dx > abs(dy) {
                    beginExit()
                } else {
                    withAnimation(.easeOut(duration: 0.25)) {
                        dragOffsetX = 0
                    }
                }
            }
    }

    /// ZStack 坐标可能不含安全区，用屏幕高度比例兜底：底部约 24% 视为
    /// 「进度条 + 信息区」保留区（信息区虽随页滚动，静止时仍落在这一带）。
    /// 正常的右滑退出都从屏幕中上部起手，不受影响；从进度条/按钮上起手的
    /// 右滑不会误触发退出（进度条横拖是 seek、按钮横拖不该把整页拖走）。
    private func startsInBottomBar(_ y: CGFloat) -> Bool {
        y > UIScreen.main.bounds.height * 0.76
    }

    /// 统一的退出：整页右移滑出屏幕 → 关闭。
    /// ⚠️ 顺序很重要：先 onBeginExit（底栏开始渐显，背后的来源页完成布局），
    /// 再动画，最后 onClose 移除本层。反过来就会看到背后页面「整体下移」的一闪。
    private func beginExit() {
        guard !isExiting else { return }
        isExiting = true
        onBeginExit()
        let screenW = UIScreen.main.bounds.width
        withAnimation(.easeIn(duration: 0.28)) {
            dragOffsetX = screenW + 40
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            onClose()
        }
    }
}

// MARK: - 每页信息区（跟随上下滑一起滚）
// 页面是**上下分区**，不是把控件浮在铺满全屏的视频上：
//   上半：视频区（标题 / 简介透明地浮在视频底部；进度条贴视频区底边）
//   下半：独立的底部状态栏（关联内容 / 收藏·连播·倍速）
// 进度线正好压在「视频下沿 / 状态栏上沿」的接缝，三者零间距；
// 视频层止于状态栏上沿，不与底 bar 叠加、不互相透色。整块都在 ShortFeedPage 内，
// 上滑时随本页一起滚走，下一条的从屏幕下方升上来。

/// 标题 / 简介：透明，浮在视频区底部。点标题进关联视频页。
private struct FeedTitleBlock: View {
    let video: ShortVideo
    var onRelated: (ShortVideo) -> Void

    @State private var descExpanded = false

    private var currentMeta: String? {
        var parts: [String] = []
        if let d = video.durationText { parts.append(d) }
        if let dim = video.dimensionText { parts.append(dim) }
        if let y = video.year, y > 0 { parts.append(String(y)) }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }

    /// 有独立标题时用真实文件名当简介；标题即文件名时退回 meta
    private var descText: String? {
        guard let t = video.title, !t.isEmpty,
              t != video.fileName, !video.fileName.isEmpty else { return nil }
        // 只展示剥掉站点水印的那截；剥完和标题一样就别重复显示副标题
        let clean = ShortVideo.displayName(video.fileName)
        return clean == video.titleText ? nil : clean
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                onRelated(video)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(video.titleText)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .shadow(color: .black.opacity(0.7), radius: 4, y: 1)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white.opacity(0.7))
                }
                // plain Button 的 label 对齐行为不稳定，显式撑满并靠左
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            if let desc = descText {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(desc)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(descExpanded ? nil : 1)
                        .allowsHitTesting(false)
                    Button(descExpanded ? "收起" : "展开") {
                        withAnimation(.easeInOut(duration: 0.15)) { descExpanded.toggle() }
                    }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.85))
                }
            } else if let meta = currentMeta {
                Text(meta)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
                    .allowsHitTesting(false)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        // 上移避开视频区底部 34pt 的进度条热区，标题仍在进度条上方
        .padding(.bottom, 34)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 进度条：画在视频区最底部，进度线正好落在「视频下沿 / 状态栏上沿」的接缝上。
/// 34pt 透明热区向视频区内延伸，不占状态栏高度；绑本页引擎而非外层当前页引擎。
private struct FeedProgressOverlay: View {
    let engine: PlayerEngine?

    @State private var barScrubbing = false
    @State private var barScrubRatio = 0.0

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { _ in
            let total = engine?.duration ?? 0
            let ratio: Double = total > 0
                ? (barScrubbing ? barScrubRatio : min(max((engine?.currentTime ?? 0) / total, 0), 1))
                : 0
            BottomProgressBar(
                ratio: ratio,
                duration: total,
                scrubbing: barScrubbing,
                onStart: {
                    barScrubbing = true
                    engine?.isScrubbing = true
                },
                onChange: { r in
                    barScrubRatio = r
                },
                onEnd: { r in
                    barScrubbing = false
                    engine?.isScrubbing = false
                    if let r, let e = engine, total > 0 {
                        e.seek(to: r * total)
                    }
                },
                // 0 = 线贴热区底边 = 视频区底边 = 状态栏上沿
                bottomInset: 0
            )
        }
        .frame(maxWidth: .infinity)
        .frame(height: 34)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }
}

/// 底部状态栏：独立实底区域，上沿紧接视频下沿（进度线压在接缝上）。
private struct FeedBottomBar: View {
    let video: ShortVideo
    let client: APIClient?
    /// 全局刷流设置（收藏 / 连播 / 倍速），跨页共享
    @ObservedObject var controls: ShortFeedControls
    /// 点「关联内容」→ 外层弹关联视频页
    var onRelated: (ShortVideo) -> Void

    private var isFavorite: Bool { controls.favoriteIDs.contains(video.id) }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                onRelated(video)
            } label: {
                HStack(spacing: 6) {
                    Text("关联内容")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.12)))
                .frame(width: 140)
            }
            .buttonStyle(.plain)

            Spacer(minLength: 8)

            HStack(spacing: 12) {
                inlineButton(icon: isFavorite ? "heart.fill" : "heart",
                             text: isFavorite ? "已收藏" : "收藏",
                             active: isFavorite) {
                    Task { await controls.toggleFavorite(id: video.id, client: client) }
                }
                .disabled(controls.favoriteBusy)

                inlineButton(icon: "arrow.triangle.2.circlepath",
                             text: controls.autoAdvance ? "连播" : "单曲",
                             active: controls.autoAdvance) {
                    controls.setAutoAdvance(!controls.autoAdvance)
                }

                rateButton
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .padding(.top, 8)
        // 距物理屏底 14pt：给 home indicator 留余量
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        // 整条状态栏的实底：视频不铺到这里。放行手势，空白处上下滑仍切视频。
        .background(Color.black.opacity(0.55).allowsHitTesting(false))
    }

    /// 「图标在左、文字在右」横排按钮，无圆形底。
    /// 开/关只用同一套白阶亮度表达，不引入红色（收藏）或品牌蓝（连播）等强调色。
    private func inlineButton(icon: String, text: String, active: Bool,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                Text(text)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(controlTint(active))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 底栏三件套（收藏 / 连播 / 倍速）共用：开=纯白，关=72% 白，无任何彩色高亮。
    /// 状态同时由图标与文字表达（heart.fill / 已收藏、连播 / 单曲、1x / 2x），
    /// 因此不依赖颜色也能分辨，按钮整体保持朴素。
    private func controlTint(_ active: Bool) -> Color {
        active ? Color.white : Color.white.opacity(0.72)
    }

    private var rateButton: some View {
        Menu {
            ForEach(PlayerEngine.rates, id: \.self) { r in
                Button {
                    controls.setRate(r)
                } label: {
                    if abs(controls.rate - r) < 0.01 {
                        Label(rateLabel(r), systemImage: "checkmark")
                    } else {
                        Text(rateLabel(r))
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "clock")
                    .font(.system(size: 14, weight: .semibold))
                Text(abs(controls.rate - 1.0) < 0.01 ? "倍速" : shortRateText(controls.rate))
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(controlTint(abs(controls.rate - 1.0) >= 0.01))
            .contentShape(Rectangle())
        }
    }

    private func shortRateText(_ r: Float) -> String {
        abs(r - 1.0) < 0.01 ? "1x" : String(format: "%gx", Double(r))
    }

    private func rateLabel(_ r: Float) -> String {
        abs(r - 1.0) < 0.01 ? "正常" : String(format: "%gx", Double(r))
    }
}

// MARK: - 刷流里的单页
// 一页 = 一条短视频。职责：拿播放地址（MP4 同步、其他 HLS）+ 挂播放器。
private struct ShortFeedPage: View {
    let video: ShortVideo
    let client: APIClient?
    let isActive: Bool
    let inWindow: Bool
    /// 全局刷流设置（收藏 / 连播 / 倍速）：底栏随页滚，但设置跨页共享
    @ObservedObject var controls: ShortFeedControls
    /// 相邻页地址预取缓存（@ObservedObject：缓存落地时要重算 body，把占位换成播放器）
    @ObservedObject var prefetcher: ShortFeedPrefetcher
    /// 点标题 / 「关联内容」→ 外层弹关联视频页
    var onRelated: ((ShortVideo) -> Void)? = nil
    /// 本页成为当前页时，把播放引擎交给外层（右上角固定图标 / 全局倍速要用）
    var onEngineReady: ((PlayerEngine) -> Void)? = nil

    @State private var target: PlaybackTarget?
    @State private var error: String?
    @State private var attempt = 0
    /// 本页自己的引擎：进度条画在页内，必须绑本页而非外层「当前页」引擎
    @State private var pageEngine: PlayerEngine?

    /// 本页自己的解析结果优先；没有就同步读预取池 —— 视图一出现就能渲染播放器，
    /// 不必等 .task 那一帧。缓存命中后 .task 会把它写回 target，之后不再依赖池子。
    private var effectiveTarget: PlaybackTarget? {
        target ?? prefetcher.cachedTarget(for: video.id)
    }

    private var poster: URL? {
        guard let raw = video.posterUrl, let u = URL(string: raw) else { return nil }
        return client?.resolve(u) ?? u
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                Color.black
                if let playTarget = effectiveTarget {
                    VideoPlayerView(url: playTarget.url,
                                    startPosition: 0,
                                    timeOffset: 0,
                                    sourcePath: playTarget.sourcePath,
                                    knownDuration: playTarget.knownDuration ?? video.duration,
                                    title: video.titleText,
                                    assetType: nil,
                                    assetID: nil,
                                    autoplay: isActive,
                                    loop: true,
                                    isActive: isActive,
                                    showsCloseButton: false,
                                    dragGesturesEnabled: false,
                                    // 播放器自带控制条的片名在左上角、会和固定退出按钮挤在一起，
                                    // 刷流里关掉；标题/简介改由 FeedTitleBlock 画（透明浮层，随页滚动）。
                                    showsControlBar: false,
                                    // 本页成为当前页时把引擎交给外层。
                                    // ⚠️ 参数顺序必须和 VideoPlayerView 的声明顺序一致：
                                    // Swift 不允许实参乱序（会报 “must precede argument”）
                                    onEngineReady: { engine in
                                        pageEngine = engine
                                        onEngineReady?(engine)
                                    },
                                    // 刷流里状态栏常驻（退出时才不会「闪」）：
                                    // 播放器别再自己藏一次，控制条也会自动让开状态栏
                                    hidesStatusBar: false,
                                    // 进度条由本页 FeedBottomBar 画（页内、随页滚），
                                    // 播放器自己那条关掉，避免一页出现两条
                                    showsBottomProgressBar: false,
                                    // 非当前页提前缓冲 10s + 预卷首帧（暂停态、不出声）。
                                    // 成为当前页后 VideoPlayerView 会调回 0（系统默认），省带宽。
                                    prefetchSeconds: isActive ? 0 : 10)
                } else {
                    placeholder
                }
                // 进度线贴视频区底边，正好压在视频下沿 / 状态栏上沿的接缝
                FeedProgressOverlay(engine: pageEngine)
                // 标题 / 简介透明地浮在视频区底部，上移避开 34pt 进度条热区
                FeedTitleBlock(video: video, onRelated: { v in onRelated?(v) })
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // 独立底部状态栏：上沿紧贴视频下沿（进度线压在接缝）；视频层止于这里
            FeedBottomBar(video: video, client: client,
                          controls: controls, onRelated: { v in onRelated?(v) })
        }
        .ignoresSafeArea(edges: .bottom)
        // inWindow 或 attempt 变化都重跑。
        // 先把预取池的结果（含正在进行的解析）写回本页 @State：之后池子清理缓存也不影响本页。
        .task(id: "\(inWindow)-\(attempt)") {
            guard inWindow else { return }
            if target == nil, let cached = await prefetcher.resolvedTarget(for: video.id) {
                target = cached
                return
            }
            guard target == nil else { return }
            await prepare()
        }
    }

    /// 封面占位 + 加载/失败反馈。滑动很快时大多数页都停在这个状态。
    private var placeholder: some View {
        ZStack {
            RemoteImage(url: poster, fallbackIcon: "play.rectangle.fill",
                        fallbackColors: Theme.placeholderGradient(for: .short))
                .imageFilled()
                .ignoresSafeArea()
            // 不压暗角/渐变：标题由视频区底部的 FeedTitleBlock 画（透明层）
            VStack(spacing: 12) {
                if let error {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                    Button("重试") { attempt += 1 }
                        .buttonStyle(.plain)
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color.white.opacity(0.2)))
                } else {
                    ProgressView().controlSize(.large).tint(.white)
                }
            }
            .padding(24)
        }
    }

    @MainActor
    private func prepare() async {
        guard let path = video.filePath, !path.isEmpty else {
            error = "这条记录没有文件路径"
            return
        }
        guard let client else {
            error = "还没连接到服务器，请重新登录"
            return
        }
        do {
            // MP4/M4V/MOV 直接直连，同步拿到 URL、零等待；只有 AVI/MKV 才开会话
            let resolved: PlaybackTarget
            if let url = client.streamURL(path: path) {
                resolved = PlaybackTarget(url: url, title: video.titleText,
                                          assetType: nil, assetID: nil,
                                          startAt: 0, timeOffset: 0,
                                          knownDuration: video.duration, sourcePath: path)
            } else {
                resolved = try await client.resolvePlayback(
                    path: path, startAt: nil, title: video.titleText,
                    assetType: nil, assetID: nil, knownDuration: video.duration)
            }
            target = resolved
            // 回填预取池：滑走再滑回来不用重新解析（非直连容器尤其省一次 HLS 会话）
            prefetcher.store(resolved, for: video.id)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - 短视频播放地址解析（共用）
// 刷流页 ShortFeedPage 与下方关联页 ShortRelatedPlayer 同一套口径：
// MP4/M4V/MOV 直连零等待，其余走 HLS 会话。
@MainActor
func resolveShortPlayback(_ video: ShortVideo, path: String, client: APIClient) async throws -> PlaybackTarget {
    if let url = client.streamURL(path: path) {
        return PlaybackTarget(url: url, title: video.titleText,
                              assetType: nil, assetID: nil,
                              startAt: 0, timeOffset: 0,
                              knownDuration: video.duration, sourcePath: path)
    }
    return try await client.resolvePlayback(
        path: path, startAt: nil, title: video.titleText,
        assetType: nil, assetID: nil, knownDuration: video.duration)
}

// MARK: - 同文件夹关联视频页（刷流底栏标题入口）
// v1 口径：后端按 file_path 父目录匹配（/api/shorts/videos/:id/related）。
// 后续扩展（同番号/同演员等）只动后端接口与本页标题文案，列表/播放逻辑不变。
// ⚠️ 刻意放本文件而不是新建 Swift 文件：新增文件必须 xcodegen generate（还会
// 冲掉手选 Team），本页纯加视图不触发这条红线。
private struct ShortRelatedView: View {
    let video: ShortVideo
    let client: APIClient?

    /// 卡片规格与 PoolVideosView（池内视频墙）逐项对齐：关联页以前用
    /// 108 宽 / 150 封面的小卡，看起来跟外面是两套样式。
    /// ⚠️ 要改就两边一起改：gridSpacing / edgePadding / coverHeight / titleHeight。
    private let gridSpacing: CGFloat = 12
    private let edgePadding: CGFloat = 16
    private let coverHeight: CGFloat = 240
    private let titleHeight: CGFloat = 28

    @Environment(\.dismiss) private var dismiss
    @State private var items: [ShortVideo] = []
    @State private var folder = ""
    @State private var isLoading = true
    @State private var errorText: String?
    @State private var playing: ShortVideo?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // 顶栏与网格改成上下分区：以前顶栏是浮在网格上的 ZStack 层，
            // 网格只留 6pt 上边距，第一行卡片会被「X / 标题」直接压住。
            VStack(spacing: 0) {
                headerBar
                    .padding(.horizontal, edgePadding)
                    .padding(.top, 8)
                    .padding(.bottom, 12)

                Group {
                    if isLoading {
                        ProgressView().controlSize(.large).tint(.white)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    } else if let errorText {
                        VStack(spacing: 14) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 26))
                                .foregroundStyle(.orange)
                            Text(errorText)
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.85))
                                .multilineTextAlignment(.center)
                            Button("重试") { Task { await load() } }
                                .buttonStyle(.plain)
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 20)
                                .padding(.vertical, 8)
                                .background(Capsule().fill(Color.white.opacity(0.2)))
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(24)
                    } else if items.isEmpty {
                        Text("这个文件夹里没有其他视频")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.6))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            // 直接复用池内视频墙的 ShortCard，参数与 PoolVideosView 完全一致
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 220),
                                                          spacing: gridSpacing)],
                                      spacing: gridSpacing) {
                                ForEach(items) { v in
                                    ShortCard(video: v, client: client,
                                              coverHeight: coverHeight,
                                              titleHeight: titleHeight,
                                              cardHeight: coverHeight + titleHeight) {
                                        playing = v
                                    }
                                }
                            }
                            .padding(.horizontal, edgePadding)
                            .padding(.bottom, 24)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // 播放器用同层覆盖，不再嵌套 fullScreenCover：关联页本身已被
            // .fullScreenCover 呈现，里面再 present 一层在 iOS 上会被系统忽略，
            // 表现就是点卡片毫无反应。关闭只撤掉这一层，回到关联列表。
            if let v = playing {
                ShortRelatedPlayer(video: v, client: client) { self.playing = nil }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .zIndex(1)
            }
        }
        .task { await load() }
    }

    /// 顶部固定：关闭 + 「同文件夹 · N 个视频」+ 文件夹路径。
    /// 路径用 .head 截断：保住最深的目录名，砍掉前面冗长的盘符/父级
    private var headerBar: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(Color.black.opacity(0.45)))
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 2) {
                Text("同文件夹 · \(items.count) 个视频")
                    .font(.headline)
                    .foregroundStyle(.white)
                if !folder.isEmpty {
                    Text(folder)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @MainActor
    private func load() async {
        isLoading = true
        errorText = nil
        guard let client else {
            errorText = "还没连接到服务器，请重新登录"
            isLoading = false
            return
        }
        do {
            let (list, f) = try await client.fetchRelatedShorts(id: video.id)
            items = list
            folder = f
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isLoading = false
    }
}

// MARK: - 关联页的独立播放器（同层覆盖，不是嵌套 fullScreenCover）
// 复用 VideoPlayerView，地址解析走 resolveShortPlayback。关闭按钮自己画——
// 不依赖 VideoPlayerView 的 showsCloseButton 关闭行为（刷流页同样自己画）。
// ⚠️ VideoPlayerView 实参顺序必须与声明顺序一致。
private struct ShortRelatedPlayer: View {
    let video: ShortVideo
    let client: APIClient?
    /// 只撤掉播放器这一层，回到关联列表；不能用 @Environment(\.dismiss)，
    /// 那会把外层关联页一起关掉、直接退回刷流。
    let onClose: () -> Void

    @State private var target: PlaybackTarget?
    @State private var error: String?
    @State private var attempt = 0

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            if let target {
                VideoPlayerView(url: target.url,
                                startPosition: 0,
                                timeOffset: 0,
                                sourcePath: target.sourcePath,
                                knownDuration: target.knownDuration ?? video.duration,
                                title: video.titleText,
                                assetType: nil,
                                assetID: nil,
                                autoplay: true,
                                loop: true,
                                isActive: true,
                                showsCloseButton: false,
                                dragGesturesEnabled: false,
                                showsControlBar: true,
                                onEngineReady: nil,
                                hidesStatusBar: true,
                                showsBottomProgressBar: true)
            } else {
                placeholder
            }

            Button { onClose() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(Color.black.opacity(0.45)))
            }
            .padding(.top, 8)
            .padding(.leading, 16)
        }
        .task(id: attempt) {
            guard target == nil else { return }
            await prepare()
        }
    }

    private var placeholder: some View {
        ZStack {
            Color.black
            VStack(spacing: 12) {
                if let error {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                    Button("重试") { attempt += 1 }
                        .buttonStyle(.plain)
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color.white.opacity(0.2)))
                } else {
                    ProgressView().controlSize(.large).tint(.white)
                }
                Text(video.titleText)
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
        }
    }

    @MainActor
    private func prepare() async {
        guard let path = video.filePath, !path.isEmpty else {
            error = "这条记录没有文件路径"
            return
        }
        guard let client else {
            error = "还没连接到服务器，请重新登录"
            return
        }
        do {
            target = try await resolveShortPlayback(video, path: path, client: client)
        } catch let e {
            error = (e as? LocalizedError)?.errorDescription ?? e.localizedDescription
        }
    }
}
