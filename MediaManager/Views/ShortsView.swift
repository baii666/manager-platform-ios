import SwiftUI

// MARK: - 随机刷流请求（首页「短视频连播」卡 → 随机起始沉浸刷流）
// 请求方（首页 DiscoverCard）与消费方（ShortsView）分处不同 tab 的 NavigationStack，
// 没有共同祖先能传 binding，用单例广播（与 RootView 的 FullscreenOverlay 同思路）。
// generation 自增触发：连点两次也各自生效；消费方不记已消费值，靠刷流是否已开去重。
final class ShortsRandomRequest: ObservableObject {
    static let shared = ShortsRandomRequest()
    /// 自增即代表一次新请求
    @Published private(set) var generation = 0

    private init() {}

    func request() {
        generation += 1
    }
}

// MARK: - 刷流呈现器（挂在根层 overlay，而不是短视频页内部）
// ⚠️ 为什么提到根层：刷流原来挂在 ShortsView 内（短视频 tab 那一层），
// 右滑退出时它右移，露出来的必然是它底下那一层 = 短视频列表页。
// 从首页「短视频连播」卡进来的人，心理路径是「首页 → 刷完 → 回首页」，
// 退出时露出短视频页等于把他扔在半路（切 tab 也救不了：切了 tab 承载刷流的
// 那一层就 opacity 0，刷流跟着一起消失）。
// 提到 RootView 的 overlay 后，刷流盖在**当前 tab 之上**，右滑露出的是它背后的
// 那个 tab —— 首页进的露首页，短视频页进的露短视频页，各自回到来处。
final class ShortFeedPresenter: ObservableObject {
    static let shared = ShortFeedPresenter()
    @Published var isActive = false
    /// 每次打开自增：驱动 ShortFeedView 重建（换起始下标 / 换数据源）。
    /// 不重建的话 ShortFeedView 的 @State currentIndex 还是上一次的。
    @Published var generation = 0
    /// 数据源：短视频页的 VM（ShortsView 常驻挂载，不会被释放）
    private(set) var viewModel: ShortsViewModel?
    private(set) var startIndex = 0

    func open(viewModel: ShortsViewModel, startIndex: Int) {
        self.viewModel = viewModel
        self.startIndex = startIndex
        generation += 1
        isActive = true
        // 底 bar 在 RootView 的 safeAreaInset 里、层级比刷流高，刷流盖不住它
        FullscreenOverlay.shared.active = true
    }

    /// 退出动画开始（右滑松手 / 点关闭）：底栏就在这时恢复，
    /// 与页面滑出同步 —— 等 close() 再恢复的话，页面已经滑开、底栏才「啪」地冒出来
    func beginExit() {
        FullscreenOverlay.shared.active = false
    }

    func close() {
        isActive = false
        FullscreenOverlay.shared.active = false
    }
}

// MARK: - 短视频页
// 对齐网页端 ShortsPage（消费侧）：池筛选 + 搜索 + 封面墙 + 点开播放
struct ShortsView: View {
    @StateObject private var viewModel = ShortsViewModel()
    /// 刷流呈现器：打开/关闭都走它，刷流本体挂在 RootView 根层
    @ObservedObject private var feedPresenter = ShortFeedPresenter.shared
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
                            // 刷流在根层 overlay 打开：背后仍是当前 tab（短视频页），
                            // 右滑退出就回到这里
                            feedPresenter.open(viewModel: viewModel, startIndex: idx)
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
            // 排序字段（与电影/相册/拍摄集列表同一套 ToolMenuChip 胶囊样式）
            ToolbarItem(placement: .topBarTrailing) {
                ToolMenuChip(label: viewModel.sort.label) {
                    ForEach(ShortsViewModel.Sort.allCases, id: \.self) { s in
                        Button {
                            Task { await viewModel.setSort(s) }
                        } label: {
                            if viewModel.sort == s { Label(s.label, systemImage: "checkmark") }
                            else { Text(s.label) }
                        }
                    }
                }
            }
            // 升/降序开关：只图标，箭头朝向即当前方向
            ToolbarItem(placement: .topBarTrailing) {
                ToolChip(label: "降序", icon: viewModel.descending ? "arrow.down" : "arrow.up",
                         highlighted: viewModel.descending, iconOnly: true) {
                    Task { await viewModel.toggleDirection() }
                }
            }
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
            guard !feedPresenter.isActive else { return }
            if viewModel.items.isEmpty {
                // 首帧 loading 未回：置位，items 到达后由下面的 onChange 补开
                pendingRandomOpen = true
                // ⚠️ 从首页卡进来时本页可能一次都没进过（items 还是空的），
                // 光置位会一直等不到 —— 主动拉一次
                Task { await viewModel.loadInitial() }
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
        feedPresenter.open(viewModel: viewModel, startIndex: idx)
    }
}

// MARK: - 短视频 VM
final class ShortsViewModel: ObservableObject {
    /// 排序字段。方向单独一档（descending）—— 后端 /api/shorts/videos 是
    /// `sort=<字段>&order=asc|desc` 两个参数，别硬拼成一对枚举。
    enum Sort: String, CaseIterable, Sendable {
        case created, title, duration, size, year
        var label: String {
            switch self {
            case .created: return "入库时间"
            case .title: return "标题"
            case .duration: return "时长"
            case .size: return "文件大小"
            case .year: return "年份"
            }
        }
    }

    @Published var items: [ShortVideo] = []
    @Published var pools: [ShortPool] = []
    @Published var selectedPoolID: Int?
    @Published var searchText = "" {
        didSet { ListSearchPrefs.saveSearch(prefsPage, searchText) }
    }
    @Published var sort: Sort {
        didSet { ListSearchPrefs.saveSort(prefsPage, raw: sort.rawValue) }
    }
    /// 升/降序。true = 降序（默认）：新的/大的在前
    @Published var descending: Bool {
        didSet { ListSearchPrefs.saveDescending(prefsPage, descending) }
    }
    @Published var totalCount = 0
    @Published var isLoading = false
    @Published var errorMessage: String?

    /// 记忆键按「页」分
    private let prefsPage = "shorts"

    var client: APIClient? { AppSession.shared.client }
    var selectedPoolName: String {
        if let id = selectedPoolID, let p = pools.first(where: { $0.id == id }) { return p.name }
        return "全部池"
    }

    private var page = 1
    private let pageSize = 60
    private var hasMore = true

    init() {
        // 还原上次的搜索词 / 排序 / 方向（没记过就用默认值）
        self.searchText = ListSearchPrefs.loadSearch(prefsPage)
        self.sort = ListSearchPrefs.loadSort(prefsPage, fallback: .created)
        self.descending = ListSearchPrefs.loadDescending(prefsPage, fallback: true)
    }

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

    /// 切换排序字段
    @MainActor
    func setSort(_ s: Sort) async {
        guard sort != s else { return }
        sort = s
        await reload()
    }

    /// 切换升/降序（字段不变）
    @MainActor
    func toggleDirection() async {
        descending.toggle()
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
                sort: sort.rawValue, descending: descending,
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
                sort: sort.rawValue, descending: descending,
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
