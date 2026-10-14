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
// 对齐网页端 ShortsWall（消费侧）：池 chips + 搜索 + 封面墙 + 点开播放。
// ⚠️ 池切换是内容上方的横滑 chips 行（poolChipsRow，safeAreaInset 钉在
// 导航栏下方），不是 toolbar 下拉、也不是「进场先选池」的二级页 ——
// 理由见 poolChipsRow 的注释。
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
    /// 池选择器（sheet）可见性。池多了以后 chips 行只显示常用 + 「更多」，
    /// 全量检索进这个带搜索的 sheet
    @State private var showPoolPicker = false
    /// 窄屏（iPhone）：搜索框缩短、计数隐藏，避免导航栏一行塞不下。
    /// 与电影/相册/拍摄集列表同一判据，保证各 tab 顶栏行为一致
    @Environment(\.horizontalSizeClass) private var hSizeClass

    private let gridSpacing: CGFloat = 12
    private let edgePadding: CGFloat = 16
    /// chips 行内联显示的池数上限。≤ 此值全量平铺（5 个池一屏放得下，
    /// 横滑只为将来池变多留余量）；超过后 chips 只留常用位 + 「更多」，
    /// 全量切换走带搜索的池选择器 —— 千池横滑约 130 屏，等于不可用
    private let poolChipInlineLimit = 8
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
                // 选中了具体池却一条没有时，说清楚是「这个池」空的，别让用户
                // 以为整个库空了
                ContentUnavailableView(viewModel.errorMessage ?? (viewModel.selectedPoolID == nil ? "暂无短视频" : "该池暂无短视频"),
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
        // 池 chips 钉在导航栏下方。⚠️ 用 safeAreaInset 而不是塞进 ScrollView
        // 里跟着滚：safeAreaInset 相当于扩展安全区，网格内容从它下面开始排，
        // 滚到底也看得见、换池不用先滚回顶部
        .safeAreaInset(edge: .top) {
            poolChipsRow
        }
        // 池多以后的全量入口：chips 只留常用位，「更多」开这个带搜索的 sheet。
        // 「更多」chip 只在池数超上限时才渲染，所以进来面对的一定是多池场景，
        // 直接整屏（[.large]），不给半屏的犹豫
        .sheet(isPresented: $showPoolPicker) {
            PoolPickerSheet(viewModel: viewModel)
                .presentationDetents([.large])
        }
        // ⚠️ 顶部栏与电影/相册/拍摄集/演员四个列表页完全同构（ ListTopBar.swift 那套）：
        // ListSearchBarItem（靠左死宽搜索框 + 页名）+ TrailingToolsItem
        // （排序 / 降序 / 计数，间距由 ToolbarMetrics 统一）。
        // 池筛选是短视频页特有的，不塞工具栏 —— 搬到内容上方的 chips 行。
        // 以前这里是 .searchable + 居中 navigationTitle + 三个散装 ToolbarItem
        // + 品牌色自定义池菜单 label —— 跟其他 tab 摆在一起对比着看不一致。
        // 搜索词的防抖 reload 仍走下面的 .onChange(of: searchText)，换组件不影响。
        .toolbar {
            // 靠左 + 固定宽度（窄屏缩短），五个列表页共用同一个组件
            ListSearchBarItem(text: $viewModel.searchText,
                              placeholder: "搜索文件名…",
                              title: "短视频",
                              narrow: hSizeClass == .compact)
            // 右侧整组收进一个 ToolbarItem：间距由 ToolbarMetrics 说了算，
            // 不再吃 ToolbarItemGroup 的系统默认间距
            TrailingToolsItem {
                sortMenu
                // 升/降序开关：只图标，箭头朝向即当前方向
                ToolChip(label: "降序", icon: viewModel.descending ? "arrow.down" : "arrow.up",
                         highlighted: viewModel.descending, iconOnly: true) {
                    Task { await viewModel.toggleDirection() }
                }
                // 池筛选不在工具栏里了：搬到内容上方的 chips 行（poolChipsRow），
                // 下拉菜单不可见，多数用户根本不知道有池这回事
                if hSizeClass == .regular {
                    Text("\(viewModel.items.count) / \(viewModel.totalCount)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        // ⚠️ 不加 fixedSize：工具栏空间紧张时 Text 会被压缩换行，
                        // 变成「1234 / 5678」上下两行，把导航栏撑高
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
        .navigationBarTitleDisplayMode(.inline)
        // ⚠️ 每个 tab / 每个 push 进来的页面都要自己垫一层背景：
        // NavigationStack 只渲染栈顶那一层，App 根的背景透不进来
        .appBackground()
        // 下拉刷新
        .refreshable { await viewModel.refresh() }
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

    // MARK: 顶部栏控件（与电影/相册/拍摄集/演员列表同一套组件）

    /// 排序字段。ToolMenuChip 的 label 样式与池筛选共用 ToolMenuLabel，
    /// 大小/边距必然一致
    private var sortMenu: some View {
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

    /// 池切换 chips：「全部」+ 每个池（池名 + 数量），横滑。
    ///
    /// 为什么是 chips 而不是「进场先显示池子、再点进去看内容」：
    /// ① 消费场景要零摩擦 —— 每次进场多点一层，而九成情况下用户要的就是
    ///    「全部」（首页「短视频连播」卡更是直接进随机刷流）；
    /// ② 数据形态不支持 —— 全库 5 个池 12525 条，两大池占 81%，「全部」
    ///    本身就是主视图，单池筛选只是「排除另一大池」，一键就能做到；
    /// ③ web 端的池卡片页是管理场景（扫描/抽帧/删除），iOS 没有管理页，
    ///    纯导航层没有功能承载。
    /// chips 把「池」摆到明面上（原来藏在 toolbar 下拉里没人发现），
    /// 又不增加导航层级 —— 5 个池一屏放得下，横滑只为将来池变多留余量。
    ///
    /// ⚠️ 由 body 的 .safeAreaInset(edge: .top) 钉在导航栏下方：
    /// 内容从它下面开始排，滚到底也换得了池。
    private var poolChipsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                PoolChip(title: "全部",
                         // 「全部」= 各池计数之和（静态口径：切进单池时也显示
                         // 全库总量，不会跟着当前筛选变）；pools 还没加载完时
                         // 不显示数字，别闪个 0
                         count: viewModel.pools.isEmpty ? nil : viewModel.pools.reduce(0) { $0 + $1.itemCount },
                         selected: viewModel.selectedPoolID == nil) {
                    Task { await viewModel.selectPool(nil) }
                }

                // 池少时全量平铺（一屏放得下，横滑只为将来变多留余量）；
                // 池多以后 chips 只留常用位 + 「更多」—— 横滑 1000 颗约 130 屏，
                // 等于不可用，全量检索交给 PoolPickerSheet 的搜索框
                if viewModel.pools.count > poolChipInlineLimit {
                    ForEach(inlinePools) { pool in
                        PoolChip(title: pool.name, count: pool.itemCount,
                                 selected: viewModel.selectedPoolID == pool.id) {
                            Task { await viewModel.selectPool(pool.id) }
                        }
                    }
                    PoolChip(title: "更多", icon: "ellipsis", selected: false) {
                        showPoolPicker = true
                    }
                } else {
                    ForEach(viewModel.pools) { pool in
                        PoolChip(title: pool.name, count: pool.itemCount,
                                 selected: viewModel.selectedPoolID == pool.id) {
                            Task { await viewModel.selectPool(pool.id) }
                        }
                    }
                }
            }
            .padding(.horizontal, edgePadding)
            .padding(.vertical, 8)
        }
    }

    /// 多池模式下 chips 行内联显示的池：最近用过的优先；没有历史就退化成
    /// 视频数最多的几个（热门池，新用户第一眼也有东西可点）。
    /// 已删除的池 id 由 compactMap 自然过滤
    private var inlinePools: [ShortPool] {
        let recents = ShortsPoolRecents.load()
            .compactMap { id in viewModel.pools.first(where: { $0.id == id }) }
        let source = recents.isEmpty
            ? viewModel.pools.sorted { $0.itemCount > $1.itemCount }
            : recents
        // 留一颗给「更多」
        Array(source.prefix(poolChipInlineLimit - 1))
    }
}

// MARK: - 池切换胶囊
private struct PoolChip: View {
    let title: String
    /// 池内视频数。nil = 不显示数字（「全部」在 pools 加载完成前）
    var count: Int? = nil
    /// 前缀图标（「更多」用 ellipsis）。池名 chip 不带图标
    var icon: String? = nil
    let selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            // 两种态分开写而不是条件修饰符：选中 = 品牌色实底 + 白字；
            // 未选中 = 和其他卡片同一套 appSurface + 分隔线描边。
            // 整行只有选中一颗是彩色的，不会花花绿绿
            if selected {
                chipContent
                    .foregroundStyle(.white)
                    .background(Theme.brand, in: Capsule())
            } else {
                chipContent
                    .foregroundStyle(.secondary)
                    .appSurface(in: Capsule())
                    .overlay(Capsule().stroke(.separator, lineWidth: 1))
            }
        }
        .buttonStyle(.plain)
    }

    private var chipContent: some View {
        HStack(spacing: 5) {
            if let icon {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold))
            }
            Text(title)
                .font(.caption.weight(.medium))
                .lineLimit(1)
            if let count {
                Text("\(count)")
                    .font(.caption2.monospacedDigit())
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
    }
}

// MARK: - 最近用过的短视频池
/// UserDefaults 持久化，cap 8。池多了以后 poolChipsRow 的常用位 +
/// PoolPickerSheet 的「最近使用」分组都用它。
/// 存 id 不存名字：池改名后历史仍然有效；池删掉后由 compactMap 自然过滤
enum ShortsPoolRecents {
    private static let key = "shorts.recentPoolIDs"
    private static let cap = 8

    static func load() -> [Int] {
        UserDefaults.standard.array(forKey: key) as? [Int] ?? []
    }

    /// 记一次使用：移到最前、去重、截断。nil 不记（调用方已说明理由）
    static func record(_ id: Int?) {
        guard let id else { return }
        var ids = load().filter { $0 != id }
        ids.insert(id, at: 0)
        UserDefaults.standard.set(Array(ids.prefix(cap)), forKey: key)
    }
}

// MARK: - 池选择器（池多以后的全量入口）
/// chips 行是「快捷位」，这里才是「全量」：搜索框 + 按视频数降序 + 最近使用。
/// 千池规模下横滑 chips 不可用（约 130 屏），搜索把找池成本压到 O(1)。
/// 不做缩略图：每池取一张封面 = N 个请求，列表场景不值
private struct PoolPickerSheet: View {
    @ObservedObject var viewModel: ShortsViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            List {
                // 「全部」永远在第一位，与 chips 第一颗对应
                poolRow(title: "全部池",
                        count: viewModel.pools.reduce(0) { $0 + $1.itemCount },
                        selected: viewModel.selectedPoolID == nil) {
                    dismiss()
                    Task { await viewModel.selectPool(nil) }
                }
                // 有历史且没在搜索时才显示「最近使用」，否则和下面的全量列表重复
                if searchText.isEmpty, !recentPools.isEmpty {
                    Section("最近使用") {
                        rows(recentPools)
                    }
                }
                Section(searchText.isEmpty ? "全部池 · \(viewModel.pools.count)" : "搜索结果 · \(filtered.count)") {
                    rows(sortedPools)
                }
            }
            .navigationTitle("选择池")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .searchable(text: $searchText, prompt: "搜索池名")
            .overlay {
                if viewModel.pools.isEmpty {
                    ContentUnavailableView("还没有池", systemImage: "square.stack.3d.up.slash")
                } else if filtered.isEmpty {
                    ContentUnavailableView("没有匹配的池", systemImage: "magnifyingglass")
                }
            }
        }
    }

    private func rows(_ pools: [ShortPool]) -> some View {
        ForEach(pools) { pool in
            poolRow(title: pool.name, count: pool.itemCount,
                    selected: viewModel.selectedPoolID == pool.id) {
                dismiss()
                Task { await viewModel.selectPool(pool.id) }
            }
        }
    }

    private func poolRow(title: String, count: Int, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(title).lineLimit(1)
                Spacer(minLength: 8)
                Text("\(count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if selected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Theme.brand)
                        .font(.body.weight(.semibold))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var recentPools: [ShortPool] {
        ShortsPoolRecents.load()
            .compactMap { id in viewModel.pools.first(where: { $0.id == id }) }
    }

    private var filtered: [ShortPool] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return viewModel.pools }
        return viewModel.pools.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    /// 全量列表按视频数降序：大池在前 —— 用户找「热门」的概率远大于翻长尾
    private var sortedPools: [ShortPool] {
        filtered.sorted { $0.itemCount > $1.itemCount }
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
        // 记进「最近使用」：池多了以后 chips 行的常用位 + 选择器的
        // 「最近使用」分组都靠它。nil（全部）不记 —— 它本来就在 chips
        // 第一位，记了反而挤掉真正的常用池
        ShortsPoolRecents.record(id)
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
