import SwiftUI
import Combine

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
        // 转发引擎的 objectWillChange：isPiPActive 这类状态变了，外层按钮跟着换图标
        bag = engine.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }
}

// MARK: - 抖音式短视频刷流
// 短视频页点开某一条后，进入这个全屏的、上下滑切片的刷流。
// 对齐抖音的交互：一屏一条、上下滑切换、当前页自动循环播、滑到末尾自动加载更多。
//
// 实现要点：
//   1. 垂直分页用 iOS 17 的 ScrollView + .scrollTargetBehavior(.paging) + containerRelativeFrame，
//      每页占满整屏，比 TabView 旋转 hack 干净。
//   2. 复用 VideoPlayerView（手势/倍速/降级/进度上报都在），加 loop + isActive：
//      当前页循环播放，滑走暂停、滑回来续播。
//   3. 只对当前页 ±2 的窗口做预加载（解析地址 + 起 AVPlayer），更远的只挂封面占位，
//      避免 1 万多条全起 AVPlayer 把内存吃爆。
//   4. 短视频 99% 是 MP4，streamURL 同步拿地址、零等待；AVI/MKV 才走 HLS 会话。
struct ShortFeedView: View {
    @ObservedObject var viewModel: ShortsViewModel
    let startIndex: Int
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

    /// 刷流页：一屏一条，上下滑切视频，退到 RootView 根层呈现
    /// 右上角固定图标（投屏 / 画中画）要作用在**当前**视频上 —— 每页播放器在成为
    /// 当前页时把引擎报上来，换页就换引擎；按钮本身钉在屏幕上不动。
    @StateObject private var engineHandle = FeedEngineHandle()
    /// 当前正在看的页（scrollPosition 跟踪，滑到哪更新到哪）
    @State private var currentID: Int?
    @State private var currentIndex: Int
    /// 右滑退出：页面向右的拖动偏移（只向右、严格水平）
    @State private var dragOffsetX: CGFloat = 0
    @State private var isExiting = false

    /// 预加载窗口半径：当前页 ±2
    private let windowRadius = 2

    init(viewModel: ShortsViewModel, startIndex: Int,
         onClose: @escaping () -> Void = {},
         onBeginExit: @escaping () -> Void = {}) {
        self.viewModel = viewModel
        self.startIndex = startIndex
        self.onClose = onClose
        self.onBeginExit = onBeginExit
        let idx = min(max(startIndex, 0), viewModel.items.count - 1)
        _currentIndex = State(initialValue: idx)
        _currentID = State(initialValue: viewModel.items.indices.contains(idx) ? viewModel.items[idx].id : nil)
    }

    /// 当前页的标题（左下角固定信息区用，跟着 currentIndex 更新）
    private var currentTitle: String {
        viewModel.items.indices.contains(currentIndex)
            ? viewModel.items[currentIndex].titleText
            : ""
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()

            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(viewModel.items.enumerated()), id: \.element.id) { index, video in
                        ShortFeedPage(video: video,
                                      client: viewModel.client,
                                      isActive: index == currentIndex,
                                      inWindow: abs(index - currentIndex) <= windowRadius,
                                      onEngineReady: { engineHandle.attach($0) })
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
            // ⚠️ 与左下角标题同理 —— 钉在屏幕上，不随上下滑切视频移动；
            // 作用的引擎换成当前页的（滑到哪一条就控制哪一条）。
            // 这两个原本画在每页的控制条里，于是跟着视频一起滚了出去。
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

            // 左下角信息区：固定在屏幕上（不随上下滑切换视频移动），内容跟着当前页变。
            // ⚠️ 之前标题画在内嵌播放器的控制条里 = 每页一份，既跟着视频一起滚，
            // 又和左上角那个固定不动的退出按钮挤在一起。信息区统一收在这里：
            // 控制条关掉（里面那套每页一份的 UI 不再跟着滚），标题归左下（抖音式）。
            VStack(alignment: .leading, spacing: 4) {
                Text(currentTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .shadow(color: .black.opacity(0.65), radius: 4, y: 1)
                if viewModel.items.count > 1 {
                    Text("\(currentIndex + 1) / \(viewModel.items.count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.7))
                        .shadow(color: .black.opacity(0.65), radius: 4, y: 1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .padding(.leading, 16)
            // 右侧留白：标题不顶到屏幕边（也给将来的竖排操作位留地方）
            .padding(.trailing, 72)
            .padding(.bottom, 12)
            // 撑满整屏只为定位，不能吃掉滑动手势
            .allowsHitTesting(false)
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
                  let idx = viewModel.items.firstIndex(where: { $0.id == id }) else { return }
            currentIndex = idx
            // 滑到倒数第 3 条就预加载下一页，别等滑到底才卡一下
            if idx >= viewModel.items.count - 3 {
                Task { await viewModel.loadMore() }
            }
        }
    }

    /// 右滑退出：只响应严格水平的向右拖动（dx>0 且 dx>abs(dy)），页面跟手右移；
    /// 松手超阈值 → 向右滑出屏幕并退出；否则弹回。上下滑切视频完全不飘。
    private var exitDragGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                guard !isExiting else { return }
                let dx = value.translation.width
                let dy = value.translation.height
                if dx > 0, dx > abs(dy) {
                    dragOffsetX = dx
                }
            }
            .onEnded { value in
                guard !isExiting else { return }
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

// MARK: - 刷流里的单页
// 一页 = 一条短视频。职责：拿播放地址（MP4 同步、其他 HLS）+ 挂播放器。
private struct ShortFeedPage: View {
    let video: ShortVideo
    let client: APIClient?
    let isActive: Bool
    let inWindow: Bool
    /// 本页成为当前页时，把播放引擎交给外层（右上角固定图标要用）
    var onEngineReady: ((PlayerEngine) -> Void)? = nil

    @State private var target: PlaybackTarget?
    @State private var error: String?
    @State private var attempt = 0

    private var poster: URL? {
        guard let raw = video.posterUrl, let u = URL(string: raw) else { return nil }
        return client?.resolve(u) ?? u
    }

    var body: some View {
        ZStack {
            Color.black
            if let target {
                VideoPlayerView(url: target.url,
                                startPosition: 0,
                                timeOffset: 0,
                                sourcePath: target.sourcePath,
                                knownDuration: target.knownDuration ?? video.duration,
                                title: video.titleText,
                                assetType: nil,
                                assetID: nil,
                                autoplay: isActive,
                                loop: true,
                                isActive: isActive,
                                showsCloseButton: false,
                                dragGesturesEnabled: false,
                                // 控制条每页一份会跟着上下滑一起滚，且它的片名在左上角、
                                // 正好和左上角固定的退出按钮挤在一起 —— 刷流里关掉，
                                // 信息区由本视图统一画在固定位置（左下角标题）
                                showsControlBar: false,
                                // 刷流里状态栏常驻（退出时才不会「闪」）：
                                // 播放器别再自己藏一次，控制条也会自动让开状态栏
                                hidesStatusBar: false,
                                onEngineReady: onEngineReady)
            } else {
                placeholder
            }
        }
        // inWindow 或 attempt 变化都重跑；拿到地址后 guard 直接返回，不重复解析
        .task(id: "\(inWindow)-\(attempt)") {
            guard inWindow, target == nil else { return }
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
            LinearGradient(colors: [.clear, .black.opacity(0.8)],
                           startPoint: .center, endPoint: .bottom)
                .ignoresSafeArea()
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
            // MP4/M4V/MOV 直接直连，同步拿到 URL、零等待；只有 AVI/MKV 才开会话
            if let url = client.streamURL(path: path) {
                target = PlaybackTarget(url: url, title: video.titleText,
                                        assetType: nil, assetID: nil,
                                        startAt: 0, timeOffset: 0,
                                        knownDuration: video.duration, sourcePath: path)
            } else {
                target = try await client.resolvePlayback(
                    path: path, startAt: nil, title: video.titleText,
                    assetType: nil, assetID: nil, knownDuration: video.duration)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
