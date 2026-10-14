import SwiftUI

// MARK: - 随机刷流请求（首页「短视频连播」卡 → 随机起始沉浸刷流）
// 请求方（首页 DiscoverCard）与消费方（ShortsView）分处不同 tab 的 NavigationStack，
// 没有共同祖先能传 binding，用单例广播（与 RootView 的 FullscreenOverlay 同思路）。
// generation 自增触发：连点两次也各自生效；消费方不记已消耗值，靠刷流是否已开去重。
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

// MARK: - 短视频页（池卡网格）
// 与相册 / 拍摄集同一套展示逻辑：第一层是「集合卡」，点卡进入内容页。
// 池卡只做入口，不带任何管理动作（扫描 / 抽帧 / 删除是网页端管理侧的事）。
//
// ⚠️ 2026-10-15 从「chips 行 + 视频墙」改成这个结构，两个原因：
// ① 一致性：其他三个列表 tab 都是集合卡 → 内容，只有短视频是平铺视频墙
// ② 规模化：chips 每颗约 98pt，千池就是约 130 屏横滑，等于不可用；
//    池卡网格 + 搜索把找池成本压回 O(1)
//
// 「全部」为什么固定第一张：相册没有「全部」是因为相册互斥、单集小，
// 短视频的全量视图是刚需（随机刷流的基线）—— 首页「连播」卡走的也是
// 这条，把它藏进第二层会多一跳。
struct ShortsView: View {
    /// 「全部」数据源：只服务于随机刷流（首页卡 / 本页 shuffle 按钮）。
    /// 池内播放走 PoolVideosView 自己的 VM，两个 VM 各管各的
    @StateObject private var viewModel = ShortsViewModel(poolId: nil)
    /// 刷流呈现器：打开/关闭都走它，刷流本体挂在 RootView 根层
    @ObservedObject private var feedPresenter = ShortFeedPresenter.shared
    /// 随机刷流请求（首页「短视频连播」卡）：generation 自增即触发一次
    @ObservedObject private var randomRequest = ShortsRandomRequest.shared
    /// 请求到达时 items 还没加载完（首帧 loading 中）：置位，items 到达后补开
    @State private var pendingRandomOpen = false
    /// 池列表（卡片数据源）
    @State private var pools: [ShortPool] = []
    /// 池列表是否加载过（区分「加载中」与「真的没有池」，别闪空状态）
    @State private var poolsLoaded = false
    @State private var poolsError: String?
    /// 池名搜索（本地过滤：池列表稳定，不需要持久化）
    @State private var poolSearchText = ""
    /// 导航目标：全部 / 某个池
    @State private var route: PoolRoute?
    /// 窄屏（iPhone）：搜索框缩短、计数隐藏，避免导航栏一行塞不下。
    /// 与电影/相册/拍摄集列表同一判据，保证各 tab 顶栏行为一致
    @Environment(\.horizontalSizeClass) private var hSizeClass

    private let gridSpacing: CGFloat = 12
    private let edgePadding: CGFloat = 16

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 160, maximum: 220), spacing: gridSpacing)]
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: gridSpacing) {
                // 「全部」固定第一张，搜索时也在：它是回得来的「家」
                PoolCard(title: "全部", count: totalVideoCount, coverURL: nil) {
                    route = .all
                }
                ForEach(filteredPools) { pool in
                    PoolCard(title: pool.name, count: pool.itemCount,
                             coverURL: poolCoverURL(pool)) {
                        route = .pool(id: pool.id, name: pool.name)
                    }
                }
            }
            .padding(edgePadding)

            if poolsLoaded && pools.isEmpty {
                ContentUnavailableView(poolsError ?? "还没有池",
                                       systemImage: poolsError == nil ? "square.stack.3d.up.slash" : "exclamationmark.triangle")
                    .frame(maxWidth: .infinity, minHeight: 400)
            } else if !poolSearchText.isEmpty && filteredPools.isEmpty {
                ContentUnavailableView("没有匹配的池", systemImage: "magnifyingglass")
                    .frame(maxWidth: .infinity, minHeight: 200)
            }
        }
        .navigationDestination(item: $route) { r in
            PoolVideosView(poolId: r.poolId, poolName: r.name)
        }
        // ⚠️ 顶部栏与电影/相册/拍摄集/演员四个列表页完全同构（ ListTopBar.swift 那套）：
        // ListSearchBarItem（靠左死宽搜索框 + 页名）+ TrailingToolsItem
        // （随机 / 计数，间距由 ToolbarMetrics 统一）。
        // 这里搜的是池名（本地过滤），不是视频 —— 视频搜索在池内页
        .toolbar {
            ListSearchBarItem(text: $poolSearchText,
                              placeholder: "搜索池名…",
                              title: "短视频",
                              narrow: hSizeClass == .compact)
            TrailingToolsItem {
                // 随机刷流：从「全部」范围随机起播 —— 首页「连播」卡同款能力，
                // 现在 tab 内也能直接发起（池内随机在 PoolVideosView 里）
                ToolChip(label: "随机", icon: "shuffle", iconOnly: true) {
                    startRandomFeed()
                }
                if hSizeClass == .regular {
                    Text("\(pools.count) 池 · \(totalVideoCount) 支")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        // ⚠️ 不加 fixedSize：工具栏空间紧张时 Text 会被压缩换行，
                        // 变成上下两行，把导航栏撑高
                        .fixedSize(horizontal: true, vertical: false)
                        .lineLimit(1)
                        // ⚠️ 给计数留固定槽位：整排锚定屏幕右缘，数字位数一变
                        // 整排按钮就被推着左右挪
                        .frame(minWidth: ToolbarMetrics.countMinWidth, alignment: .trailing)
                        // 与前面按钮的间隔独立于按钮间距（见 ToolbarMetrics.countGap）
                        .padding(.leading, ToolbarMetrics.countGap)
                }
            }
        }
        .tint(Theme.brand)
        // ⚠️ 每个 tab / 每个 push 进来的页面都要自己垫一层背景：
        // NavigationStack 只渲染栈顶那一层，App 根的背景透不进来
        .appBackground()
        // 「全部」VM 拉第一页：随机刷流的数据源（首页卡不等页面加载完就要能开）
        .task { await viewModel.loadInitial() }
        .task { await loadPools() }
        .refreshable { await loadPools() }
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
    }

    // MARK: 随机刷流

    /// 随机起始下标开沉浸刷流：从「全部」范围随机
    private func startRandomFeed() {
        guard !viewModel.items.isEmpty else { return }
        let idx = Int.random(in: 0..<viewModel.items.count)
        feedPresenter.open(viewModel: viewModel, startIndex: idx)
    }

    // MARK: 池列表

    private func loadPools() async {
        guard let client = AppSession.shared.client else {
            poolsLoaded = true
            poolsError = "未连接服务器"
            return
        }
        do {
            pools = try await client.fetchShortPools()
            poolsError = nil
        } catch {
            pools = []
            poolsError = "加载失败 · \(error.localizedDescription)"
        }
        poolsLoaded = true
    }

    /// 全库视频总数 = 各池计数之和（静态口径：搜索时也显示全库总量）
    private var totalVideoCount: Int {
        pools.reduce(0) { $0 + $1.itemCount }
    }

    /// 搜索过滤后的池，按视频数降序（大池在前：找热门的概率远大于翻长尾；
    /// 数量打地用 id 升序兜底，保证顺序稳定）
    private var filteredPools: [ShortPool] {
        let q = poolSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = q.isEmpty ? pools : pools.filter { $0.name.localizedCaseInsensitiveContains(q) }
        return base.sorted { $0.itemCount == $1.itemCount ? $0.id < $1.id : $0.itemCount > $1.itemCount }
    }

    /// 池封面 URL：后端给的是相对路径（/raw?path=…），过一遍 client 解析成绝对地址。
    /// nil（空池 / 没抽帧）→ RemoteImage 走渐变占位
    private func poolCoverURL(_ pool: ShortPool) -> URL? {
        guard let raw = pool.coverUrl, let u = URL(string: raw) else { return nil }
        return AppSession.shared.client?.resolve(u) ?? u
    }
}

// MARK: - 池网格 → 池内视频墙 的路由值
/// 用 enum 而不是 Int?：Int? 做 navigationDestination(item:) 时「全部」与
/// 「具体池」含糊，nil 的 id 也不好给
enum PoolRoute: Identifiable, Hashable {
    case all
    case pool(id: Int, name: String)

    var id: String {
        switch self {
        case .all: return "all"
        case .pool(let id, _): return "pool-\(id)"
        }
    }

    var poolId: Int? {
        switch self {
        case .all: return nil
        case .pool(let id, _): return id
        }
    }

    var name: String {
        switch self {
        case .all: return "全部短视频"
        case .pool(_, let name): return name
        }
    }
}

// MARK: - 池卡（对齐相册卡：封面 + 右下角计数 + 标题区）
/// 只做入口：没有管理动作（扫描 / 抽帧 / 删除在网页端管理侧）
private struct PoolCard: View {
    let title: String
    let count: Int
    var coverURL: URL? = nil

    /// 封面高度写死：视频海报混了横屏 / 竖屏 / 4K，行高随内容变
    /// LazyVGrid 就不重排已布局的行 → 卡片互相压（同 ShortCard 的理由）
    private let coverHeight: CGFloat = 150
    /// 标题区高度（名字一行 + 计数一行）
    private let infoHeight: CGFloat = 46

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .bottomTrailing) {
                    RemoteImage(url: coverURL,
                                fallbackIcon: "play.rectangle.on.rectangle",
                                fallbackColors: Theme.placeholderGradient(for: .short))
                        .imageFilled()
                        .frame(height: coverHeight)
                        .frame(maxWidth: .infinity)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    // 右下角计数角标（同 AlbumCard）
                    Text("\(count)")
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.55), in: Capsule())
                        .padding(7)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text("\(count) 支")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .frame(height: infoHeight, alignment: .leading)
            }
            // 整卡高度也钉死，理由同 ShortCard
            .frame(height: coverHeight + infoHeight, alignment: .top)
            .clipped()
            .appSurface(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.separator))
        }
        .buttonStyle(.plain)
    }

    var onTap: () -> Void
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

    /// 数据范围：nil = 全部池，非 nil = 指定池。构造时定死，运行期不改 ——
    /// 换范围就是换 VM（池网格的「全部」VM 只管随机刷流；每个池页各持
    /// 自己的 VM，互不干扰）
    let poolId: Int?

    @Published var items: [ShortVideo] = []
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

    private var page = 1
    private let pageSize = 60
    private var hasMore = true

    init(poolId: Int? = nil) {
        self.poolId = poolId
        // 还原上次的搜索词 / 排序 / 方向（没记过就用默认值）
        self.searchText = ListSearchPrefs.loadSearch(prefsPage)
        self.sort = ListSearchPrefs.loadSort(prefsPage, fallback: .created)
        self.descending = ListSearchPrefs.loadDescending(prefsPage, fallback: true)
    }

    @MainActor
    func loadInitial() async {
        // ⚠️ 只探活不绑定：函数体只用 reload()，client 在 loadMore() 里
        // 会重新绑一次 —— 写成 `guard let client else` 会绑个没人用的变量，
        // 编译器警告 "immutable value 'client' was never used"
        guard AppSession.shared.client != nil else { errorMessage = "未连接服务器"; return }
        // 同 AlbumListView：从详情返回本页时 .task 可能重跑，此时 reload 会清空 items
        // 让 ScrollView 弹回顶部。已有数据就跳过，保住滚动位置。
        // 搜索 / 排序变更仍各自直接调 reload()，不受影响。
        guard items.isEmpty else { return }
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
                poolId: poolId, page: page, size: pageSize,
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
                poolId: poolId, page: page, size: pageSize,
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
// ⚠️ internal 而不是 private：PoolVideosView 在另一个文件里用它
struct ShortCard: View {
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
