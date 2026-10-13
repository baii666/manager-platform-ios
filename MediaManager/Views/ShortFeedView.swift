import SwiftUI

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
    /// 退出动画**开始**的回调：此刻就要恢复状态栏 / 底栏。
    /// 等 onClose 再恢复就晚了 —— 背后的页面已经整屏露出，状态栏一出现它整体
    /// 下移，看着就是返回时那一下「闪」。
    var onBeginExit: () -> Void = {}

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

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()

            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(viewModel.items.enumerated()), id: \.element.id) { index, video in
                        ShortFeedPage(video: video,
                                      client: viewModel.client,
                                      isActive: index == currentIndex,
                                      inWindow: abs(index - currentIndex) <= windowRadius)
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
            // 与右滑走同一条退出动画，不再「点了直接消失」——那样没有动画缓冲，
            // 状态栏/底栏的恢复会硬切一下
            Button { beginExit() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(Color.black.opacity(0.45)))
            }
            // 顶部按钮同样贴屏幕上沿算，不跟状态栏走（下面整层 ignoresSafeArea）
            .padding(.top, 8)
            .padding(.leading, 16)
        }
        // 右滑退出：页面跟手向右移动，松手超过阈值向右滑出屏幕（露出背后的来源页）
        .offset(x: dragOffsetX)
        // ⚠️ 整层不吃安全区：退出动画一开始状态栏就要恢复，
        // 若本层跟着 safeArea 走，状态栏出现的瞬间整页会下移一截 —— 那下「闪」更明显
        .ignoresSafeArea()
        .simultaneousGesture(exitDragGesture)
        // 状态栏由 RootView 统一控制（overlay 里 .statusBar 不一定生效，且退出时要
        // 与动画同步提前恢复，不能写死 hidden: true）
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
    /// ⚠️ 顺序很重要：先 onBeginExit（状态栏 / 底栏开始恢复，背后的来源页完成布局），
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
                                dragGesturesEnabled: false)
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
