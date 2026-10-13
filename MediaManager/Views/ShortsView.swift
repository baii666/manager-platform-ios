import SwiftUI

// MARK: - 随机刷流请求（首页「短视频连播」卡 → 随机起始沉浸刷流）
// 请求方（首页 DiscoverCard）与消费方（ShortsView）分处不同 tab 的 NavigationStack，
// 没有共同祖先能传 binding，用单例广播（与 RootView 的 FullscreenOverlay 同思路）。
// generation 自增触发：连点两次也各自生效；消费方不记已消费值，靠 feedEntry == nil 去重。
final class ShortsRandomRequest: ObservableObject {
    static let shared = ShortsRandomRequest()
    /// 自增即代表一次新请求
    @Published private(set) var generation = 0
    /// 本次请求是否来自首页「短视频连播」卡。
    /// 首页进来的，退出刷流要退回首页 tab —— 用户的心理路径是
    ///「首页 → 刷完 → 回首页」，留在短视频列表页等于把他扔在半路。
    private(set) var fromHome = false

    private init() {}

    func request(fromHome: Bool = false) {
        self.fromHome = fromHome
        generation += 1
    }
}

// MARK: - 短视频页
// 对齐网页端 ShortsPage（消费侧）：池筛选 + 搜索 + 封面墙 + 点开播放
struct ShortsView: View {
    @StateObject private var viewModel = ShortsViewModel()
    /// 底 bar tab：从首页卡发起的刷流，退出后要切回首页
    @Binding var tab: RootTab
    /// 刷流入口：点卡片后带着起始下标弹全屏抖音式刷流
    @State private var feedEntry: ShortFeedEntry?
    /// 当前这次刷流是否由首页「短视频连播」卡发起（决定退出后切不切回首页）
    @State private var feedFromHome = false
    /// 播放地址构造失败时给出明确原因，而不是静默什么都不发生
    @State private var playError: String?
    /// 随机刷流请求（首页「短视频连播」卡）：generation 自增即触发一次
    @ObservedObject private var randomRequest = ShortsRandomRequest.shared
    /// 请求到达时 items 还没加载完（首帧 loading 中）：置位，items 到达后补开
    @State private var pendingRandomOpen = false

    private let gridSpacing: CGFloat = 12
    private let edgePadding: CGFloat = 16
    /// 封面高度写死成常量，不跟列宽挂钩。
    ///
    /// 短视频封面是 FFmpeg 抽帧，横屏 1920×1080 / 竖屏 1080×1920 / 4K 混在一起，
    /// 尺寸完全没有统一标准。只要行高还会随内容变（列宽测量、图片加载完成），
    /// LazyVGrid 就不会重算已布局的行 —— 表现就是卡片互相压住。
    /// 所以这里连列宽都不自己量，改用 adaptive 交给系统，高度保持常量。
    private let coverHeight: CGFloat = 240
    /// 标题区高度也写死，让整卡高度成为常量
    private let titleHeight: CGFloat = 28

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 160, maximum: 220), spacing: gridSpacing)]
    }

    var body: some View {
        ZStack {
            ScrollView {
            if viewModel.items.isEmpty && !viewModel.isLoading {
                ContentUnavailableView(viewModel.errorMessage ?? "暂无短视频",
                                       systemImage: viewModel.errorMessage == nil ? "play.rectangle.fill" : "exclamationmark.triangle")
                    .frame(maxWidth: .infinity, minHeight: 400)
            } else {
                LazyVGrid(columns: columns, spacing: gridSpacing) {
                    ForEach(viewModel.items) { v in
                        ShortCard(video: v, client: viewModel.client,
                                  coverHeight: coverHeight,
                                  titleHeight: titleHeight,
                                  cardHeight: coverHeight + titleHeight) {
                            guard let path = v.filePath, !path.isEmpty else {
                                playError = "这条记录没有文件路径"
                                return
                            }
                            guard let idx = viewModel.items.firstIndex(where: { $0.id == v.id }) else { return }
                            feedEntry = ShortFeedEntry(id: v.id, startIndex: idx)
                        }
                        .task {
                            if v.id == viewModel.items.last?.id { await viewModel.loadMore() }
                        }
                    }
                }
                .padding(edgePadding)
                if viewModel.isLoading {
                    ProgressView().frame(maxWidth: .infinity).padding()
                }
            }
        }
        .navigationTitle("短视频")
        .navigationBarTitleDisplayMode(.inline)
        // ⚠️ 每个 tab / 每个 push 进来的页面都要自己垫一层背景：
        // NavigationStack 只渲染栈顶那一层，App 根的背景透不进来
        .appBackground()
        // 下拉刷新
        .refreshable { await viewModel.refresh() }
        .searchable(text: $viewModel.searchText, prompt: "搜索文件名…")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { Task { await viewModel.selectPool(nil) } } label: {
                        if viewModel.selectedPoolID == nil { Label("全部池", systemImage: "checkmark") }
                        else { Text("全部池") }
                    }
                    ForEach(viewModel.pools) { pool in
                        Button { Task { await viewModel.selectPool(pool.id) } } label: {
                            if pool.id == viewModel.selectedPoolID { Label(pool.name, systemImage: "checkmark") }
                            else { Text(pool.name) }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(viewModel.selectedPoolName)
                            .font(.subheadline.weight(.medium))
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(Theme.brand)
                }
            }
        }
        // ⚠️ iOS 17 起 `onChange(of:) { newValue in }`（单参数）已废弃，用零参数闭包
        .onChange(of: viewModel.searchText) {
            Task {
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled else { return }
                await viewModel.reload()
            }
        }
        .task { await viewModel.loadInitial() }
        // 首页「短视频连播」卡 → 随机起始的沉浸刷流
        // ⚠️ iOS 17 起 `onChange(of:) { newValue in }`（单参数，含 `{ _ in }`）已废弃，
        // 统一用零参数闭包，闭包内直接读属性即为新值
        .onChange(of: randomRequest.generation) {
            // 已在刷流中：忽略（连点只第一次生效）
            guard feedEntry == nil else { return }
            if viewModel.items.isEmpty {
                // 首帧 loading 未回：置位，items 到达后由下面的 onChange 补开
                pendingRandomOpen = true
            } else {
                startRandomFeed()
            }
        }
        .onChange(of: viewModel.items.count) {
            if pendingRandomOpen, !viewModel.items.isEmpty {
                pendingRandomOpen = false
                startRandomFeed()
            }
        }

            // 刷流：用 ZStack overlay 呈现（不用 fullScreenCover），
            // 右滑退出时页面右移、露出背后的列表页
            if let entry = feedEntry {
                ShortFeedView(viewModel: viewModel, startIndex: entry.startIndex,
                              onClose: {
                    feedEntry = nil
                    // 首页卡进来的：退出刷流直接回首页。
                    // 与 feedEntry 同一次渲染更新，不会先闪一下短视频列表页再跳。
                    if feedFromHome {
                        feedFromHome = false
                        tab = .home
                    }
                })
                    .transition(.move(edge: .trailing))
                    .zIndex(1)
            }
        }
        // 刷流打开时隐藏导航栏（否则列表页导航栏盖在刷流上）
        .toolbar(feedEntry == nil ? .automatic : .hidden, for: .navigationBar)
        // 刷流打开时隐藏底 bar（底 bar 在 RootView 层级，刷流盖不住它）
        .onChange(of: feedEntry) {
            FullscreenOverlay.shared.active = feedEntry != nil
        }
        .alert("无法播放", isPresented: Binding(
            get: { playError != nil },
            set: { if !$0 { playError = nil } }
        )) {
            Button("好", role: .cancel) { playError = nil }
        } message: {
            Text(playError ?? "")
        }
    }

    // MARK: 随机刷流

    /// 随机起始下标开沉浸刷流：短视频池内随机，沿用当前选中的池 / 搜索范围
    private func startRandomFeed() {
        guard !viewModel.items.isEmpty else { return }
        let idx = Int.random(in: 0..<viewModel.items.count)
        // 记下来源：startRandomFeed 只被首页卡的请求触发，卡片点进来的不走这里
        feedFromHome = randomRequest.fromHome
        feedEntry = ShortFeedEntry(id: viewModel.items[idx].id, startIndex: idx)
    }
}

// MARK: - 刷流入口
// 用 item 触发 overlay 呈现（而不是 isPresented + 分离 index），
// 避免闭包读到「更新前」的下标。遵循 Equatable 供 .onChange(of:) 使用。
private struct ShortFeedEntry: Identifiable, Equatable {
    let id: Int
    let startIndex: Int
}

// MARK: - 短视频 VM
final class ShortsViewModel: ObservableObject {
    @Published var items: [ShortVideo] = []
    @Published var pools: [ShortPool] = []
    @Published var selectedPoolID: Int?
    @Published var searchText = ""
    @Published var totalCount = 0
    @Published var isLoading = false
    @Published var errorMessage: String?

    var client: APIClient? { AppSession.shared.client }
    var selectedPoolName: String {
        if let id = selectedPoolID, let p = pools.first(where: { $0.id == id }) { return p.name }
        return "全部池"
    }

    private var page = 1
    private let pageSize = 60
    private var hasMore = true

    @MainActor
    func loadInitial() async {
        guard let client else { errorMessage = "未连接服务器"; return }
        do { pools = try await client.fetchShortPools() } catch { pools = [] }
        // 同 AlbumListView：从详情返回本页时 .task 可能重跑，此时 reload 会清空 items
        // 让 ScrollView 弹回顶部。已有数据就跳过，保住滚动位置。
        // 搜索 / 切换合集仍各自直接调 reload()，不受影响。
        guard items.isEmpty else { return }
        await reload()
    }

    @MainActor
    func selectPool(_ id: Int?) async {
        selectedPoolID = id
        await reload()
    }

    @MainActor
    func reload() async {
        items = []
        page = 1
        hasMore = true
        await loadMore()
    }

    /// 下拉刷新：保留旧列表，加载第一页后替换。
    /// ⚠️ 不碰 isLoading（触发 body 重算会让 .refreshable 的刷新 Task 被取消），
    /// 刷新指示由系统 refreshable 转圈承担。
    @MainActor
    func refresh() async {
        guard let client, !isLoading else { return }
        page = 1
        hasMore = true
        do {
            let (batch, total) = try await client.fetchShortVideos(
                poolId: selectedPoolID, page: page, size: pageSize,
                q: searchText.isEmpty ? nil : searchText)
            totalCount = total
            items = batch
            page += 1
            hasMore = !batch.isEmpty && items.count < total
        } catch {
            errorMessage = "加载失败 · \(describe(error))"
        }
    }

    @MainActor
    func loadMore() async {
        guard let client, !isLoading, hasMore else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let (batch, total) = try await client.fetchShortVideos(
                poolId: selectedPoolID, page: page, size: pageSize,
                q: searchText.isEmpty ? nil : searchText)
            totalCount = total
            items.append(contentsOf: batch)
            page += 1
            hasMore = !batch.isEmpty && items.count < total
        } catch {
            errorMessage = "加载失败 · \(describe(error))"
        }
    }

    private func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

// MARK: - 短视频封面卡（高度全常量：封面 coverHeight + 标题 titleHeight）
private struct ShortCard: View {
    let video: ShortVideo
    let client: APIClient?
    let coverHeight: CGFloat
    let titleHeight: CGFloat
    let cardHeight: CGFloat
    var onTap: () -> Void

    private var poster: URL? {
        guard let raw = video.posterUrl, let u = URL(string: raw) else { return nil }
        return client?.resolve(u) ?? u
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .bottomLeading) {
                    RemoteImage(url: poster, fallbackIcon: "play.rectangle.fill",
                                fallbackColors: Theme.placeholderGradient(for: .short))
                        // imageFilled 把图片钉死在容器尺寸里，杜绝按原图像素渲染
                        .imageFilled()
                        .frame(height: coverHeight)
                        .frame(maxWidth: .infinity)
                        .clipped()
                    LinearGradient(colors: [.clear, .black.opacity(0.75)],
                                  startPoint: .top, endPoint: .bottom)
                        .frame(height: 70)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .clipped()
                    VStack(alignment: .leading, spacing: 2) {
                        if let dur = video.durationText {
                            HStack(spacing: 4) {
                                Image(systemName: "play.fill").font(.system(size: 9))
                                Text(dur).font(.caption2).monospacedDigit()
                            }
                            .foregroundStyle(.white)
                        }
                        if let dim = video.dimensionText {
                            Text(dim).font(.caption2).foregroundStyle(.white.opacity(0.7))
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)

                    // 封面状态徽章
                    HStack(spacing: 4) {
                        if video.hasPreview {
                            Text("动态").font(.system(size: 9)).fontWeight(.medium)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(.blue.opacity(0.85), in: Capsule())
                        } else if video.hasPoster {
                            Text("静态").font(.system(size: 9))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(.black.opacity(0.6), in: Capsule())
                        } else {
                            Text("无封面").font(.system(size: 9))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(.red.opacity(0.8), in: Capsule())
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                Text(video.titleText)
                    .font(.caption)
                    .lineLimit(1).truncationMode(.tail)
                    .padding(.horizontal, 8)
                    .frame(height: titleHeight, alignment: .leading)
            }
            // 整卡高度也钉死：LazyVGrid 行高是「首帧测出来就固定」的，
            // 只要高度有任何变化（图片加载完成、列宽重算）都不会重排 → 卡片压在一起
            .frame(height: cardHeight, alignment: .top)
            .clipped()
            .appSurface(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.separator))
        }
        .buttonStyle(.plain)
    }
}
