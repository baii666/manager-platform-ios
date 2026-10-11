import SwiftUI

// MARK: - 搜索历史（本地 UserDefaults）
// 搜索是核心入口，最近搜过的词要能一键重搜；只存字符串，不存结果。
final class SearchHistoryStore {
    private static let key = "search.history"
    private static let limit = 12

    static func load() -> [String] {
        (UserDefaults.standard.array(forKey: key) as? [String]) ?? []
    }

    static func add(_ raw: String) {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        var list = load()
        list.removeAll { $0 == q }
        list.insert(q, at: 0)
        if list.count > limit { list = Array(list.prefix(limit)) }
        UserDefaults.standard.set(list, forKey: key)
    }

    // ⚠️ 是 removeObject(forKey:)，不是 removeItem —— UserDefaults 没有 removeItem
    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
}

// MARK: - 搜索页
// 对齐网页端搜索：分类 Tab（全部/影视/相册/照片/拍摄集）+ 每类无限滚动 + 结果直达详情
struct SearchView: View {
    /// 首页搜索框提交后带进来的关键词；为空则进入后自动聚焦键盘等用户输入
    var initialQuery: String = ""
    /// 首页的「语义搜索」开关状态（sparkles 按钮）带进来
    var semantic: Bool = false

    @State private var query = ""
    /// 语义模式（以文搜图）。只对照片生效，由搜索框右侧的 sparkles 按钮切换
    @State private var isSemantic = false
    /// 语义结果按 id 存相似度，供卡片角标显示
    @State private var similarity: [Int: Double] = [:]
    /// 真正拿去请求的词（防抖后写入），避免每敲一个字都打接口
    @State private var activeQuery = ""
    @State private var selectedTab: Tab = .all
    @State private var results: [SearchItem] = []
    @State private var totals: [String: Int] = [:]
    /// 服务端回的**总匹配数**（顶栏「已加载 / 总数」的右边那个数）。
    /// ⚠️ 独立于 totals：totals 是 /search/totals 按类型给的（给分类胶囊用），
    /// 这个是搜索响应自带的 total，跟列表页的 totalCount 同源。
    @State private var resultTotal = 0
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var page = 1
    @State private var hasMore = false
    @State private var history: [String] = SearchHistoryStore.load()
    /// 防抖定时器：敲字停手 debounceInterval 后才发请求
    @State private var debounceTask: Task<Void, Never>?
    /// 真正在飞的那次搜索任务。换词时取消它，避免旧请求回来覆盖新结果
    @State private var searchTask: Task<Void, Never>?
    /// 正在加载的词。旧请求结束只清自己的标记，不会把新请求的转圈关掉
    @State private var loadingToken = ""
    /// 初始词只应用一次：从下级页面返回时会再次 onAppear，不能每次都重搜
    @State private var didApplyInitial = false
    @FocusState private var fieldFocused: Bool
    @Environment(\.horizontalSizeClass) private var hSizeClass

    // 导航目标
    @State private var movieTarget: MediaItem?
    @State private var albumTarget: Album?
    @State private var albumLibID: Int = 0
    @State private var shootTarget: Shoot?

    private var client: APIClient? { AppSession.shared.client }

    enum Tab: String, CaseIterable {
        case all, movie, album, photo, shoot

        var label: String {
            switch self {
            case .all: return "全部"; case .movie: return "影视"
            case .album: return "相册"; case .photo: return "照片"; case .shoot: return "拍摄集"
            }
        }

        /// 该 Tab 对应的**后端 type 列表**。
        /// ⚠️ 不能请求 type=all：后端 type=all 是 searchAll，返回的是分组 map
        ///（`{movie:[...], tv:[...], album:[...], shoot:[...], library:[...]}`），
        /// 既没有 items/total，也不含 photo，按 items 解必然空。跨类型由客户端并发聚合。
        var requestTypes: [String] {
            switch self {
            case .all: return ["movie", "tv", "album", "photo", "shoot"]
            case .movie: return ["movie", "tv"]   // 影视 = 电影 + 剧集
            default: return [rawValue]
            }
        }

        /// 计数取自 /api/search/totals 的哪些键（影视要 movie+tv；全部要排除 library）
        var totalKeys: [String] {
            switch self {
            case .all: return ["movie", "tv", "album", "photo", "shoot"]
            case .movie: return ["movie", "tv"]
            default: return [rawValue]
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 语义模式只看照片，分类 Tab 无意义（影视/相册/拍摄集没有语义向量），
            // 只留一句说明讲清为什么搜出来全是照片
            if isSemantic {
                semanticBanner
                Divider()
            }
            content
            // ⚠️ 底部必须垫一个 Spacer：历史记录/空态这种内容不满一屏时，
            // VStack 只占内容自身高度，会被 NavigationStack 垂直居中——
            // 内容跑到屏幕中间，上方一大块空白（iPad 上尤其明显）。
            // Spacer 撑满剩余高度，让内容始终靠顶。
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // ⚠️ 不设 navigationTitle：顶栏被搜索框占满（和三个列表页同一套规范），
        // 再放一个居中标题会跟搜索框抢地方；返回按钮显示上一页标题（"首页"）
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // 搜索框：与三个列表页同一个 ListSearchBarItem（.topBarLeading + 死宽），
            // 紧跟系统返回按钮，切页面时位置不跳
            ListSearchBarItem(
                text: $query,
                placeholder: isSemantic ? "用一句话描述画面…" : "搜索影视 / 相册 / 照片 / 拍摄集",
                // ⚠️ 只传 fieldWidth，不传 narrow：宽屏（iPad，本项目主场景）走
                // ListSearchBarItem.width（280），与列表页完全一致；
                // 窄屏给 170 只是临时值，iPhone 顶栏塞不下整排按钮，后续统一适配
                fieldWidth: hSizeClass == .compact ? Self.compactFieldWidth : nil,
                focus: $fieldFocused,
                onSubmit: { runSearch(query) },
                onClear: { clearAll() }
            )
            // 紧跟搜索框的一组：语义开关 → 搜索按钮 → 分类胶囊组。
            // ⚠️ 必须全部收进同一个 ToolbarItem：之前分类组单独占一个 leading item，
            // 实测被系统挤到只剩一个圆点（多个 leading item 的宽度分配不可控），
            // 收进一个 HStack 后间距、先后顺序都由我们自己说了算。
            ToolbarItem(placement: .topBarLeading) {
                HStack(spacing: 4) {
                    // 语义开关：紧挨搜索框（用户指定顺序），紫 = 开
                    ToolChip(label: "语义", icon: "sparkles", highlighted: isSemantic,
                             tintColor: isSemantic ? Color.purple : nil) {
                        toggleSemantic()
                    }
                    // 搜索按钮：防抖之外给一个明确的「立刻搜」出口（不用等 350ms，也不用按回车）
                    ToolChip(label: "搜索", icon: "magnifyingglass") {
                        runSearch(query)
                    }
                    // 空词没什么可搜的，按钮置灰
                    .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
                    // 分类胶囊组：语义模式下不显示（语义只搜照片，没有分类）
                    if !activeQuery.isEmpty && !isSemantic {
                        categoryChips
                            // ⚠️ 防压缩：这个组之前被系统压到只剩一个圆点，
                            // fixedSize 让按钮文字保持完整，空间不足宁可溢出也不缩成空壳
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
            }
            .withoutGlass()
            // 右侧整组：与列表页同一个 TrailingToolsItem，间距/高度由 ToolbarMetrics 统一
            TrailingToolsItem {
                // 转圈：列表页同款槽位思路（固定宽度 + opacity），
                // 出现/消失不会把左右的控件推着挪
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 16)
                    .opacity(isLoading ? 1 : 0)
                // 「已加载 / 总数」，列表页顶栏同款：等宽数字 + 固定槽位 + 与按钮分组的间隔。
                // ⚠️ 同样只在宽屏显示：窄屏这一行已经很挤（iPhone 排版后续统一适配）
                if hSizeClass == .regular, !activeQuery.isEmpty {
                    Text("\(results.count) / \(currentTotal)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        // ⚠️ 不加 fixedSize：工具栏空间紧张时 Text 会被压缩换行，
                        // 变成「12 / 128」上下两行，把导航栏撑高
                        .fixedSize(horizontal: true, vertical: false)
                        .lineLimit(1)
                        // ⚠️ 固定槽位：整排锚定屏幕右缘，位数变化（9→10）不会推动前面的按钮
                        .frame(minWidth: ToolbarMetrics.countMinWidth, alignment: .trailing)
                        .padding(.leading, ToolbarMetrics.countGap)
                }
            }
        }
        .onChange(of: query) { scheduleSearch() }
        .task { applyInitial() }
        // 离开页面就撤掉还没发出去的防抖请求，别在背后偷偷打接口
        .onDisappear { debounceTask?.cancel() }
        // ⚠️ 每个 tab / 每个 push 进来的页面都要自己垫一层背景：
        // NavigationStack 只渲染栈顶那一层，App 根的背景透不进来
        .appBackground()
        .navigationDestination(item: $movieTarget) { MediaDetailView(media: $0) }
        .navigationDestination(item: $albumTarget) { AlbumPhotosView(album: $0, libID: albumLibID) }
        .navigationDestination(item: $shootTarget) { ShootDetailView(shoot: $0) }
    }

    // MARK: 搜索框（在顶栏里，见 body 的 .toolbar）
    // 这里只留搜索框相关的两个动作 + 宽度常量。
    // ⚠️ 搜索框本体不再画在内容区：三个列表页已经把它放进了 navigationBar
    //（ListSearchBarItem，紧跟系统返回按钮），搜索页跟着同一套规范走。

    /// iPhone 上的搜索框宽度（与列表页 narrow 同一个值 170）。
    /// ⚠️ 当前排版以 iPad 为准（宽屏走 ListSearchBarItem.width = 280，空间充裕）；
    /// iPhone 上顶栏还要再塞一整排分类胶囊，宽度必然不够，这里只是个临时值 ——
    /// 等 iPhone 适配时分类组会换形态（大概率挪回内容区或改成分段控件），再一起定。
    private static let compactFieldWidth: CGFloat = 170

    /// 语义开关。切完立刻重搜（词没变就不打接口）
    @MainActor
    private func toggleSemantic() {
        isSemantic.toggle()
        if !activeQuery.isEmpty { startSearch() }
    }

    /// 顶栏搜索框的清除按钮：词和结果一起清，不等防抖
    @MainActor
    private func clearAll() {
        debounceTask?.cancel()
        searchTask?.cancel()
        query = ""
        activeQuery = ""
        results = []
        totals = [:]
        resultTotal = 0
        similarity = [:]
        page = 1
        hasMore = false
        errorMessage = nil
    }

    /// 顶栏「已加载 / 总数」的右边那个数。
    /// ⚠️ 优先用搜索响应自带的 total（和列表页 totalCount 同源）；后端没给（0，
    /// 老版本接口就不返回 total）时退回 /search/totals 的分类计数汇总，
    /// 免得显示成「30 / 0」这种看着像坏了的东西。
    private var currentTotal: Int {
        if resultTotal > 0 { return resultTotal }
        return selectedTab.totalKeys.reduce(0) { $0 + (totals[$1] ?? 0) }
    }

    /// 语义模式的说明条：说清它只搜照片、且照片要先跑过 AI 分析，
    /// 否则用户只会看到「零结果」而不知道为什么
    private var semanticBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.caption)
                .foregroundStyle(Color.purple)
            Text("语义搜索：按画面内容匹配照片，需要照片已完成 AI 分析")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: 分类选择（顶栏胶囊组）
    //
    // ⚠️ 位置从内容区挪到了导航栏，紧跟搜索框 —— 整页控件收进顶栏那一行。
    // ⚠️ 试过下拉菜单（ToolMenuChip），用户否掉了：本项目主要跑 iPad，横向空间足够，
    //    分类是高频切换项，摊开成一排比藏进菜单里好点；iPhone 的拥挤问题后续再统一适配。
    // ⚠️ 选中态保留胶囊底：ToolbarItem 加了 .withoutGlass()，iOS 26 那层共享玻璃底
    //    已经去掉了，再画一层底不会变成「两层圆弧」。
    private var categoryChips: some View {
        HStack(spacing: 6) {
            ForEach(Tab.allCases, id: \.self) { tab in
                Button {
                    selectedTab = tab
                    startSearch()
                } label: {
                    HStack(spacing: 5) {
                        Text(tab.label)
                        // 计数直接摊在胶囊里：iPad 横向空间够，不用藏进菜单。
                        // ⚠️ 恒显（0 也显示）：按条件显示的话胶囊宽度会随计数有无变宽变窄，
                        // 切分类时整排胶囊跟着左右挪。monospacedDigit 同理，
                        // 位数变化（9→10）时数字本身不等宽会抖。
                        Text("\(tab.totalKeys.reduce(0) { $0 + (totals[$1] ?? 0) })")
                            .font(.caption2.monospacedDigit())
                            // 计数恒为次级灰：选中项的标题已经是品牌色，
                            // 数字再跟着变色整颗胶囊就太花了
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline.weight(selectedTab == tab ? .semibold : .regular))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(selectedTab == tab ? Theme.brand.opacity(0.15) : Color.clear,
                                in: Capsule())
                    // 未选中用次级灰：跟顶栏其它工具（排序/库筛选）同一个色调
                    .foregroundStyle(selectedTab == tab ? Theme.brand : Color.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: 结果区

    @ViewBuilder
    private var content: some View {
        if let errorMessage {
            ContentUnavailableView(errorMessage, systemImage: "exclamationmark.triangle")
                .frame(maxWidth: .infinity, minHeight: 300)
        } else if activeQuery.isEmpty {
            historyList
        } else if results.isEmpty && !isLoading {
            // 语义模式的空结果要解释原因，不然用户只会觉得「语义搜索坏了」
            Group {
                if isSemantic {
                    ContentUnavailableView {
                        Label("没有语义匹配的照片", systemImage: "sparkles")
                    } description: {
                        Text("确认照片已跑过 AI 分析（会生成语义向量），或换个说法、把阈值调低再试。")
                    }
                } else {
                    ContentUnavailableView("没有匹配结果", systemImage: "tray")
                }
            }
            .frame(maxWidth: .infinity, minHeight: 300)
        } else if selectedTab == .all && !isSemantic {
            groupedResults
        } else {
            flatResults
        }
    }

    /// 空态：最近搜索（点一下直接重搜）
    private var historyList: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !history.isEmpty {
                HStack {
                    Text("最近搜索").font(.subheadline.weight(.semibold))
                    Spacer()
                    Button("清空") {
                        SearchHistoryStore.clear()
                        history = []
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                ForEach(history, id: \.self) { h in
                    Button {
                        query = h
                        runSearch(h)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
                            Text(h).lineLimit(1)
                            Spacer()
                            Image(systemName: "arrow.up.left").foregroundStyle(.secondary)
                        }
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
            } else {
                ContentUnavailableView("输入关键词开始搜索", systemImage: "magnifyingglass")
                    .frame(maxWidth: .infinity, minHeight: 300)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// 「全部」：按类型分组，每组一行横滑 + 「查看全部」
    private var groupedResults: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(section.title)
                                .font(.headline)
                            if let total = totals[section.type], total > 0 {
                                Text("\(total)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                // tv 不是 Tab 的 case，「剧集」分组的查看全部落到「影视」
                                selectedTab = section.type == "tv" ? .movie : (Tab(rawValue: section.type) ?? .all)
                                startSearch()
                            } label: {
                                Text("查看全部").font(.caption)
                            }
                        }
                        .padding(.horizontal, 16)

                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 12) {
                                ForEach(section.items) { item in
                                    // 照片在浏览页是瀑布流（UIKit 组件），横滑预览里
                                    // 用同款圆角方块缩略图，观感保持一致
                                    if item.type == "photo" {
                                        SearchPhotoThumb(photo: makePhoto(item)) { route(item) }
                                    } else {
                                        resultCard(item, width: SearchView.previewCardWidth)
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                    }
                }
            }
            .padding(.vertical, 16)
            .bottomBarClearance()
        }
    }

    /// 单类型 / 语义模式：
    /// 照片走瀑布流（复用相册内照片页的 PhotoGrid），其余走各自列表页的卡片组件
    @ViewBuilder
    private var flatResults: some View {
        if isSemantic || selectedTab == .photo {
            photoResults
        } else {
            cardResults
        }
    }

    // MARK: 照片结果（复用 PhotoGrid 瀑布流）

    /// 结果里的照片 → Photo（语义模式把相似度做成角标带进 cell）
    private var viewerPhotos: [Photo] {
        results.filter { $0.type == "photo" }.map { item in
            var p = makePhoto(item)
            // 语义搜索：让用户看得到「为什么是这张」
            if isSemantic, let s = similarity[item.id] { p.badge = "\(Int(s * 100))%" }
            return p
        }
    }

    private var photoResults: some View {
        let photos = viewerPhotos
        // ⚠️ PhotoGrid 是 UICollectionView，没有 intrinsicContentSize，
        // 必须由外层给定尺寸（GeometryReader 量剩下的空间），否则高度为 0
        return GeometryReader { geo in
            PhotoGrid(photos: photos,
                      columns: photoColumns(width: geo.size.width),
                      onSelect: { openViewer(photos: photos, id: $0.id) },
                      onReachEnd: { Task { await loadMore() } })
                .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    /// 列数随宽度走：窄屏 3 列，宽屏逐步加密（对齐相册照片页的观感）
    private func photoColumns(width: CGFloat) -> Int {
        switch width {
        case ..<500: return 3
        case ..<800: return 4
        case ..<1100: return 5
        default: return 6
        }
    }

    private func openViewer(photos: [Photo], id: Int) {
        let index = photos.firstIndex { $0.id == id } ?? 0
        // 走全局 overlay：本页是 push 进来的，fullScreenCover 退出会闪白屏
        PhotoViewerPresenter.shared.show(photos, index: index, hasMore: hasMore, onLoadMore: {
            Task {
                await self.loadMore()
                PhotoViewerPresenter.shared.updatePhotos(self.viewerPhotos)
            }
        })
    }

    // MARK: 卡片结果（复用 MediaCard / AlbumCard / ShootCard）

    /// 分组横滑里的卡片宽度：与列表页默认竖版宽度一致（150）
    private static let previewCardWidth: CGFloat = 150

    private var cardResults: some View {
        GeometryReader { geo in
            let grid = gridLayout(containerWidth: geo.size.width)
            ScrollView {
                LazyVGrid(columns: grid.columns, spacing: 18) {
                    ForEach(results) { item in
                        resultCard(item, width: grid.itemWidth)
                            .task {
                                if item.id == results.last?.id { await loadMore() }
                            }
                    }
                }
                .padding(16)
                .bottomBarClearance()
                if isLoading {
                    ProgressView().frame(maxWidth: .infinity).padding()
                }
            }
        }
    }

    /// 列数 / 卡片宽度：与影视列表页同一套算法（固定卡片宽 150，均分铺满）
    private func gridLayout(containerWidth: CGFloat) -> (columns: [GridItem], itemWidth: CGFloat) {
        let spacing: CGFloat = 18
        let padding: CGFloat = 16
        let gridW = max(containerWidth - padding * 2, 0)
        let cardW: CGFloat = Self.previewCardWidth
        let n = max(2, Int((gridW + spacing) / (cardW + spacing)))
        let itemW = (gridW - spacing * CGFloat(n - 1)) / CGFloat(n)
        let cols = Array(repeating: GridItem(.flexible(), spacing: spacing), count: n)
        return (cols, itemW)
    }

    /// 单张结果卡：**按类型派发给浏览页的同款卡片组件**，
    /// 搜索结果和列表页因此长得一样，改样式也只改一处。
    @ViewBuilder
    private func resultCard(_ item: SearchItem, width: CGFloat) -> some View {
        // 与列表页同一判据：卡片够宽才显示下方标题区，否则标题叠进封面底部渐变
        let showInfo = width >= CardLayoutController.compactThreshold
        switch item.type {
        case "movie", "series", "tv":
            let m = item.asMediaItem()
            // 搜索结果只带海报（没有 fanart），封面 URL 用 mediaCoverURL 统一拼
            MediaCard(item: m,
                      coverURL: client?.mediaCoverURL(m, landscape: false),
                      width: width, landscape: false, showInfo: showInfo) { route(item) }
        case "album":
            let a = item.asAlbum()
            // AlbumCard 本身不带点击（列表页是包在 NavigationLink 里的），这里包一层 Button
            Button { route(item) } label: {
                AlbumCard(album: a, coverURL: albumCoverURL(a),
                          width: width, landscape: false, showInfo: showInfo)
            }
            .buttonStyle(.plain)
        case "shoot":
            ShootCard(shoot: item.asShoot(), client: client) { route(item) }
        case "photo":
            // 兜底：单类型结果里混进照片时不留空白格
            SearchPhotoThumb(photo: makePhoto(item), size: width) { route(item) }
        default:
            EmptyView()
        }
    }

    /// 相册封面：竖版优先，都没有就退回用相册 id（与列表页 / 原搜索卡一致）
    private func albumCoverURL(_ album: Album) -> URL? {
        let id = album.preferredCoverId ?? album.id
        return client?.makeURL("/photo", queryItems: [
            URLQueryItem(name: "id", value: "\(id)"),
            URLQueryItem(name: "size", value: "600"),
        ])
    }

    // MARK: 数据

    private struct ResultSection: Identifiable {
        let type: String
        let items: [SearchItem]
        var id: String { type }
        var title: String {
            switch type {
            case "movie": return "电影"
            case "tv": return "剧集"
            case "album": return "相册"
            case "photo": return "照片"
            case "shoot": return "拍摄集"
            default: return "其他"
            }
        }
    }

    /// 把混合结果按类型归组（后端按请求顺序返回，顺序是乱的）
    private var sections: [ResultSection] {
        let order = ["movie", "tv", "album", "photo", "shoot"]
        var map: [String: [SearchItem]] = [:]
        for item in results { map[item.type, default: []].append(item) }
        return order.compactMap { t in
            guard let items = map[t], !items.isEmpty else { return nil }
            return ResultSection(type: t, items: items)
        }
    }

    /// 进入时处理首页带过来的初始词。没带词就自动聚焦键盘，省一次点击。
    @MainActor
    private func applyInitial() {
        guard !didApplyInitial else { return }
        didApplyInitial = true
        // 首页的语义开关状态只在这里同步一次：之后由本页自己的按钮控制，
        // 否则每次返回首页再进来都会被覆盖掉
        isSemantic = semantic
        let q = initialQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            fieldFocused = true
            return
        }
        query = q
        runSearch(q)
    }

    /// 输入防抖：停手 350ms 才发请求。太长会觉得卡，太短每个字都打接口
    private static let debounceInterval: Duration = .milliseconds(350)

    /// 输入防抖调度器。
    /// ⚠️ 只管定时器本身；真正的请求由 runSearch 里的 searchTask 负责取消，
    /// 否则快速打字会有多个请求同时在飞，回来顺序不确定 → 旧结果盖掉新结果。
    @MainActor
    private func scheduleSearch() {
        debounceTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // 已经在展示同一个词的结果就别再打一次：程序化赋值 query（比如
        // applyInitial / 点历史记录）也会触发 onChange，不拦就是重复请求
        guard q != activeQuery else { return }
        debounceTask = Task { @MainActor in
            try? await Task.sleep(for: Self.debounceInterval)
            guard !Task.isCancelled else { return }
            runSearch(query)
        }
    }

    @MainActor
    private func runSearch(_ text: String) {
        debounceTask?.cancel()
        // 取消上一次在飞的请求：换词后旧结果已经没意义，
        // 而且它回来还会把新结果覆盖掉（请求返回顺序不保证）
        searchTask?.cancel()
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        activeQuery = q
        selectedTab = .all
        guard !q.isEmpty else {
            results = []; totals = [:]; resultTotal = 0; similarity = [:]; return
        }
        SearchHistoryStore.add(q)
        history = SearchHistoryStore.load()
        startSearch()
    }

    /// 统一的请求入口：换词 / 切分类 / 切语义模式都走这里。
    /// 每次先取消上一次在飞的任务 —— 请求返回顺序不保证，不取消就会出现
    /// 「旧结果盖掉新结果」「两个词的结果混在一屏」。
    @MainActor
    private func startSearch() {
        debounceTask?.cancel()
        searchTask?.cancel()
        searchTask = Task { await reload() }
    }

    @MainActor
    private func reload() async {
        // 词在这里定格：请求期间用户可能又改了词，回来时用它判断结果是否还有效
        let token = activeQuery
        guard let client, !token.isEmpty else {
            results = []; totals = [:]; similarity = [:]; return
        }
        errorMessage = nil
        page = 1; hasMore = true; results = []; similarity = [:]
        // 换词了，总数也得跟着重来（否则新词第一页会顶着上一个词的总数）
        resultTotal = 0
        if isSemantic {
            // 语义模式没有分类计数（它只搜照片），别去打 /totals
            totals = [:]
        } else {
            // 分类计数（/totals 有 5s 服务端缓存，切 Tab 不会重复打爆）
            do { totals = try await client.searchTotals(query: token) } catch { totals = [:] }
        }
        // 计数回来期间词可能已经换了（或这次任务被取消了），别再往下翻页
        guard !Task.isCancelled, token == activeQuery else { return }
        await loadMore()
    }

    private let pageSize = 30

    @MainActor
    private func loadMore() async {
        // 和 reload 同理：把这次翻页针对的词定格，回来时比对才知道结果还有没有效
        let token = activeQuery
        guard let client, hasMore, !token.isEmpty else { return }
        // 同一个词的重复触底（列表在滚动时会连发好几次）才算并发，要互斥；
        // 换了词就直接放行 —— 旧请求的 defer 也不会把新请求的 isLoading 关掉
        guard !(isLoading && loadingToken == token) else { return }
        isLoading = true
        loadingToken = token
        defer { if loadingToken == token { isLoading = false } }
        do {
            if isSemantic {
                // 后端用 offset 翻页，page 从 1 起 → offset = (page-1) * pageSize
                let p = try await client.semanticSearch(
                    query: token, limit: pageSize, offset: (page - 1) * pageSize)
                // 结果回来时词已经换了 / 任务被取消 → 整批丢弃，不能往列表里写
                guard !Task.isCancelled, token == activeQuery else { return }
                let items = p.results.map { makeSearchItem($0) }
                if page == 1 { results = items } else { results.append(contentsOf: items) }
                resultTotal = p.total
                var map = similarity
                for r in p.results { map[r.id] = r.similarity ?? 0 }
                similarity = map
                page += 1
                hasMore = results.count < p.total
            } else {
                // 「全部」只取每类一批做总览，翻页交给各分类页
                let size = selectedTab == .all ? 8 : pageSize
                let p = try await client.searchGrouped(
                    query: token, types: selectedTab.requestTypes, page: page, size: size)
                guard !Task.isCancelled, token == activeQuery else { return }
                if page == 1 { results = p.items } else { results.append(contentsOf: p.items) }
                // searchGrouped 已经把各类型的 total 加过了，直接用
                resultTotal = p.total
                page += 1
                hasMore = selectedTab == .all ? false : p.hasMore
            }
        } catch {
            // 旧词的报错也不该弹在新结果上
            guard !Task.isCancelled, token == activeQuery else { return }
            // 语义模式下最常见的失败是后端没加载 CLIP 模型（503），
            // 服务端原文（"CLIP 模型未加载，语义搜索不可用"）已经说清楚了，直接透出
            let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            errorMessage = (isSemantic ? "语义搜索不可用 · " : "搜索失败 · ") + msg
        }
    }

    // MARK: 路由

    /// 语义结果 → SearchItem：复用同一张卡片、同一套路由和看图器（语义只出照片）
    private func makeSearchItem(_ r: SemanticPhotoResult) -> SearchItem {
        var item = SearchItem(id: r.id)
        item.fillType("photo")
        item.fileName = r.fileName
        item.libraryId = r.libraryId
        item.albumId = r.albumId
        return item
    }

    private func makePhoto(_ item: SearchItem) -> Photo {
        var p = Photo(id: item.id)
        p.albumId = item.albumId
        p.libraryId = item.libraryId
        p.fileName = item.fileName ?? item.titleText
        p.thumbURL = client?.makeURL("/photo", queryItems: [
            URLQueryItem(name: "id", value: "\(item.id)"),
            URLQueryItem(name: "size", value: "600"),
        ])
        p.fullURL = client?.makeURL("/photo", queryItems: [
            URLQueryItem(name: "id", value: "\(item.id)"),
            URLQueryItem(name: "size", value: "original"),
        ])
        return p
    }

    private func route(_ item: SearchItem) {
        // 各类型都用 Models.swift 里那一份转换（asMediaItem / asAlbum / asShoot），
        // 卡片和详情拿到的模型完全一致，不会出现「卡片和详情对不上」
        switch item.type {
        case "movie", "series", "tv":
            movieTarget = item.asMediaItem()
        case "album":
            albumLibID = item.libraryId ?? 0
            albumTarget = item.asAlbum()
        case "photo":
            // 搜索结果里的照片整批交给看图器，可以左右翻，而不是只能看孤立的一张。
            // ⚠️ 走全局 overlay（PhotoViewerPresenter）：本页是 push 进来的全屏页，
            // 全局 overlay 挂在 RootView 最外层，盖得住整个 App（含底栏）；
            // 用 fullScreenCover 的话底层页面会被移出窗口层级 → 退出闪白屏。
            openViewer(photos: viewerPhotos, id: item.id)
        case "shoot":
            shootTarget = item.asShoot()
        default:
            break
        }
    }
}

// MARK: - 搜索结果里的照片缩略图
// 照片在浏览页是 PhotoGrid 瀑布流（UIKit 组件），横滑预览里没法直接复用它，
// 这里用同款圆角 + 满填充的方块，保证与瀑布流里的照片观感一致。
private struct SearchPhotoThumb: View {
    let photo: Photo
    var size: CGFloat = 150
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            RemoteImage(url: photo.thumbURL, fallbackIcon: "photo",
                        fallbackColors: Theme.placeholderGradient(for: .photo))
                .imageFilled()
                .frame(width: size, height: size)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
