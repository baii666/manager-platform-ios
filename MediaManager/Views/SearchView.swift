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
    /// **当前是否在「语义」这个视图**（它就是第 6 个分类，点顶栏那个 sparkles 按钮切过来）。
    /// ⚠️ 它不是一个「要不要附带语义」的开关：切过来就只看语义匹配到的照片，
    /// 切回关键词分类（全部/影视/相册/照片/拍摄集）就只看那类结果 ——
    /// 两个视图互斥，和其它分类按钮的用法完全一致。
    /// 默认 false（一进来在「全部」）；关键词搜索仍会自动附带语义组，排在最后。
    @State private var isSemantic = false
    /// 语义结果按 id 存相似度，供卡片角标显示
    @State private var similarity: [Int: Double] = [:]
    /// 语义匹配单独存一份，**不混进 results**。
    /// ⚠️ 它是异步回来的（CLIP 推理比关键词搜索慢得多），关键词结果先渲染，
    /// 语义结果到了再追加到最后一组 / 最后一段。
    @State private var semanticItems: [SearchItem] = []
    /// 语义请求在飞（用于最后一组显示「匹配中」占位）
    @State private var isSemanticLoading = false
    @State private var semanticTask: Task<Void, Never>?
    /// 真正拿去请求的词（防抖后写入），避免每敲一个字都打接口
    @State private var activeQuery = ""
    @State private var selectedTab: Tab = .all
    /// 关键词命中的结果（不含语义）
    @State private var results: [SearchItem] = []
    @State private var totals: [String: Int] = [:]
    /// 关键词搜索响应里的 total。语义是异步追加的，回来后要把它加回去，
    /// 所以这个中间值得单独留着
    @State private var keywordTotal = 0
    /// 服务端回的**总匹配数**（顶栏「已加载 / 总数」的右边那个数）= 关键词 total + 语义条数。
    /// ⚠️ 独立于 totals：totals 是 /search/totals 按类型给的（给分类胶囊用），
    /// 这个是搜索响应自带的 total，跟列表页的 totalCount 同源。
    @State private var resultTotal = 0
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var page = 1
    @State private var hasMore = false
    @State private var history: [String] = SearchHistoryStore.load()
    /// 防抖定时器已移除：现在是**点搜索按钮（或回车）才搜**，敲字不再自动打接口。
    /// 真正在飞的那次搜索任务。换词后点搜索时取消它，避免旧请求回来覆盖新结果
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
            content
            // ⚠️ 底部要垫一个 Spacer：历史记录/空态这种内容不满一屏时，
            // VStack 只占内容自身高度，会被 NavigationStack 垂直居中——
            // 内容跑到屏幕中间，上方一大块空白（iPad 上尤其明显）。
            // Spacer 撑满剩余高度，让内容始终靠顶。
            //
            // ⚠️ 但瀑布流那两页（照片 / 语义）**不能垫**：它们自己就是撑满全屏的
            // 滚动容器，Spacer 会和 GeometryReader 平分剩余高度 → 网格只剩半屏，
            // 看着就像「滑不动」。
            if !fillsScreen { Spacer(minLength: 0) }
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
                placeholder: "搜索影视 / 相册 / 照片 / 拍摄集",
                // ⚠️ 只传 fieldWidth，不传 narrow：宽屏（iPad，本项目主场景）走
                // ListSearchBarItem.width（280），与列表页完全一致；
                // 窄屏给 170 只是临时值，iPhone 顶栏塞不下整排按钮，后续统一适配
                fieldWidth: hSizeClass == .compact ? Self.compactFieldWidth : nil,
                focus: $fieldFocused,
                onSubmit: { runSearch(query) },
                onClear: { clearAll() },
                // 「🔍搜索」放进搜索框里（对齐网页端样式），点了立刻搜，绕过防抖
                searchAction: { runSearch(query) },
                searchDisabled: query.trimmingCharacters(in: .whitespaces).isEmpty
            )
            // 紧跟搜索框的一组：分类胶囊 → 语义开关。
            // ⚠️ 必须全部收进同一个 ToolbarItem：之前分类组单独占一个 leading item，
            // 实测被系统挤到只剩一个圆点（多个 leading item 的宽度分配不可控），
            // 收进一个 HStack 后间距、先后顺序都由我们自己说了算。
            //
            // ⚠️ 这些按钮没有各自的特殊逻辑：点了就是「按当前条件搜一次」——
            // 分类决定搜哪类、语义决定按不按画面搜，都复用同一条搜索链路。
            ToolbarItem(placement: .topBarLeading) {
                HStack(spacing: 4) {
                    // 分类胶囊组：始终可点。
                    // ⚠️ 在语义视图下点分类 = 切回关键词视图、按该分类搜（互斥的两个视图）。
                    // ⚠️ 之前试过语义模式下置灰，用户否了——后面的按钮都要能点、点了就搜。
                    if !activeQuery.isEmpty {
                        categoryChips
                            // ⚠️ 防压缩：这个组之前被系统压到只剩一个圆点，
                            // fixedSize 让按钮文字保持完整，空间不足宁可溢出也不缩成空壳
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    // 语义：**第 6 个分类**（放在类别最后面，用户指定）。
                    // 点它和其它分类按钮完全一样 —— 切到语义这个视图、按当前词搜一次，
                    // 结果区只展示语义匹配到的照片。回关键词结果就点前面的分类胶囊。
                    // ⚠️ 放最后一个是有讲究的：它在最右，自己变宽只往右扩，
                    // 不会把前面的搜索框和分类胶囊推得左右挪。
                    // ⚠️ minWidth 钉死槽位：高亮态字重从 medium 变 semibold，
                    // 文字会宽那么一两个点，不给下限的话切换时整排会轻微抖一下。
                    ToolChip(label: "语义", icon: "sparkles", highlighted: isSemantic,
                             tintColor: isSemantic ? Color.purple : nil) {
                        selectSemantic()
                    }
                    .frame(minWidth: 62)
                }
            }
            .withoutGlass()
            // 右侧整组：与列表页同一个 TrailingToolsItem，间距/高度由 ToolbarMetrics 统一
            TrailingToolsItem {
                // 转圈：列表页同款槽位思路（固定宽度 + opacity），
                // 出现/消失不会把左右的控件推着挪。
                // ⚠️ 语义视图下没有关键词请求（只有 isSemanticLoading），要一起算进来
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 16)
                    .opacity(isLoading || isSemanticLoading ? 1 : 0)
                // 「已加载 / 总数」，列表页顶栏同款：等宽数字 + 固定槽位 + 与按钮分组的间隔。
                // ⚠️ 同样只在宽屏显示：窄屏这一行已经很挤（iPhone 排版后续统一适配）
                if hSizeClass == .regular, !activeQuery.isEmpty {
                    Text("\(loadedCount) / \(currentTotal)")
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
        // ⚠️ 敲字不自动搜：只认「点搜索按钮」和「回车」两个入口（用户要求取消防抖）
        .task { applyInitial() }
        // ⚠️ 每个 tab / 每个 push 进来的页面都要自己垫一层背景：
        // NavigationStack 只渲染栈顶那一层，App 根的背景透不进来
        .appBackground()
        .navigationDestination(item: $movieTarget) { MediaDetailView(media: $0) }
        .navigationDestination(item: $albumTarget) { AlbumPhotosView(album: $0, libID: albumLibID) }
        .navigationDestination(item: $shootTarget) { ShootDetailView(shoot: $0) }
    }

    /// 当前结果区是不是**自己撑满全屏的滚动容器**（瀑布流）。
    /// 是的话外层不能再垫 Spacer —— 那会分走一半高度，网格只剩半屏。
    private var fillsScreen: Bool {
        guard !activeQuery.isEmpty, errorMessage == nil else { return false }
        return isSemantic || selectedTab == .photo
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

    /// 切到「语义」视图：和点任何一个分类胶囊是同一件事 ——
    /// 标记当前视图 + 按当前词重搜一次，结果区只展示语义匹配到的照片。
    /// ⚠️ 幂等：已经在语义视图时再点一次，就是原地重搜（和点已选中的分类胶囊一样）
    @MainActor
    private func selectSemantic() {
        isSemantic = true
        if !activeQuery.isEmpty { startSearch() }
    }

    /// 切分类：就是一个普通的条件切换 + 重搜。
    /// ⚠️ 顺带退出语义视图：语义和关键词是两个互斥视图，
    /// 点了某个分类就是想看那类结果（点分类退出语义，是分类自己的用法，不是给语义开的分支）
    @MainActor
    private func selectTab(_ tab: Tab) {
        isSemantic = false
        selectedTab = tab
        startSearch()
    }

    /// 顶栏搜索框的清除按钮：词和结果一起清
    @MainActor
    private func clearAll() {
        searchTask?.cancel()
        semanticTask?.cancel()
        query = ""
        activeQuery = ""
        results = []
        totals = [:]
        keywordTotal = 0
        resultTotal = 0
        semanticItems = []
        isSemanticLoading = false
        similarity = [:]
        page = 1
        hasMore = false
        errorMessage = nil
    }

    /// 顶栏「已加载 / 总数」的左边那个数：关键词结果 + 异步追加的语义结果
    private var loadedCount: Int { results.count + semanticItems.count }

    /// 顶栏「已加载 / 总数」的右边那个数。
    /// ⚠️ 优先用搜索响应自带的 total（和列表页 totalCount 同源）；后端没给（0，
    /// 老版本接口就不返回 total）时退回 /search/totals 的分类计数汇总，
    /// 免得显示成「30 / 0」这种看着像坏了的东西。
    private var currentTotal: Int {
        if resultTotal > 0 { return resultTotal }
        return selectedTab.totalKeys.reduce(0) { $0 + (totals[$1] ?? 0) }
    }

    // MARK: 分类选择（顶栏胶囊组）
    //
    // ⚠️ 位置从内容区挪到了导航栏，紧跟搜索框 —— 整页控件收进顶栏那一行。
    // ⚠️ 试过下拉菜单（ToolMenuChip），用户否掉了：本项目主要跑 iPad，横向空间足够，
    //    分类是高频切换项，摊开成一排比藏进菜单里好点；iPhone 的拥挤问题后续再统一适配。
    // ⚠️ 选中态保留胶囊底：ToolbarItem 加了 .withoutGlass()，iOS 26 那层共享玻璃底
    //    已经去掉了，再画一层底不会变成「两层圆弧」。
    private var categoryChips: some View {
        // ⚠️ 语义视图下整排胶囊都不高亮：当前展示的是语义结果，
        // 不是任何一类关键词结果（高亮留着会让人以为看到的还是那一类）
        let active: Tab? = isSemantic ? nil : selectedTab
        return HStack(spacing: 6) {
            ForEach(Tab.allCases, id: \.self) { tab in
                Button {
                    selectTab(tab)
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
                    .font(.subheadline.weight(active == tab ? .semibold : .regular))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(active == tab ? Theme.brand.opacity(0.15) : Color.clear,
                                in: Capsule())
                    // 未选中用次级灰：跟顶栏其它工具（排序/库筛选）同一个色调
                    .foregroundStyle(active == tab ? Theme.brand : Color.secondary)
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
        } else if isSemantic {
            // 语义视图：只展示语义匹配到的照片（它自己管加载中 / 空态）
            semanticResults
        } else if results.isEmpty && semanticItems.isEmpty && !isLoading && !isSemanticLoading {
            ContentUnavailableView("没有匹配结果", systemImage: "tray")
                .frame(maxWidth: .infinity, minHeight: 300)
        } else if selectedTab == .all {
            groupedResults
        } else {
            flatResults
        }
    }

    /// 语义视图的结果区：与「照片」分类同一套瀑布流，只是数据源换成语义命中的照片。
    /// ⚠️ 语义请求慢（CLIP 推理），先给加载态，不要闪一下「没有结果」
    @ViewBuilder
    private var semanticResults: some View {
        if semanticItems.isEmpty && isSemanticLoading {
            VStack(spacing: 10) {
                ProgressView()
                Text("正在按画面内容匹配…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 300)
        } else if semanticItems.isEmpty {
            ContentUnavailableView("没有语义匹配的照片", systemImage: "sparkles",
                                   description: Text("按画面内容匹配，需要照片已完成 AI 分析；换个说法再试试。"))
                .frame(maxWidth: .infinity, minHeight: 300)
        } else {
            // 复用「照片」分类那套瀑布流组件
            photoGrid(semanticPhotos)
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
                        HStack(spacing: 6) {
                            // 语义组加个 sparkles：一眼看出这组是「按画面匹配」的，
                            // 不是按文件名/标题命中关键词的
                            if section.isSemantic {
                                Image(systemName: "sparkles")
                                    .font(.caption)
                                    .foregroundStyle(Color.purple)
                            }
                            Text(section.title)
                                .font(.headline)
                            if section.count > 0 {
                                Text("\(section.count)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            // 语义组还没回来时不给「查看全部」：点了会跳到空的照片页
                            if !(section.isSemantic && section.items.isEmpty) {
                                Button {
                                    selectTab(targetTab(section))
                                } label: {
                                    Text("查看全部").font(.caption)
                                }
                            }
                        }
                        .padding(.horizontal, 16)

                        if section.items.isEmpty {
                            // 只有语义组会出现在这里：它异步在跑，先占位说明「还在匹配」
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("正在按画面内容匹配…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(height: SearchView.previewCardWidth)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                        } else {
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(spacing: 12) {
                                    ForEach(section.items) { item in
                                        // 照片在浏览页是瀑布流（UIKit 组件），横滑预览里
                                        // 用同款圆角方块缩略图，观感保持一致
                                        if item.type == "photo" {
                                            SearchPhotoThumb(photo: makeBadgedPhoto(item)) { route(item) }
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
            }
            .padding(.vertical, 16)
            .bottomBarClearance()
        }
    }

    /// 单类型：照片走瀑布流（复用相册内照片页的 PhotoGrid），其余走各自列表页的卡片组件。
    /// ⚠️ 照片分类下**不再挂语义横幅**：语义已经是独立的 tab 了，
    /// 照片 tab 就该只有关键词命中的照片（它和语义 tab 是互斥的两个视图）
    @ViewBuilder
    private var flatResults: some View {
        if selectedTab == .photo {
            photoGrid(keywordPhotos)
        } else {
            cardResults
        }
    }

    // MARK: 照片结果（复用 PhotoGrid 瀑布流）

    /// 结果里的照片 → Photo（语义命中把相似度做成角标带进 cell / 缩略图）
    private func makeBadgedPhoto(_ item: SearchItem) -> Photo {
        var p = makePhoto(item)
        // 让用户看得到「为什么是这张」
        if let s = similarity[item.id] { p.badge = "\(Int(s * 100))%" }
        return p
    }

    /// 语义命中的照片。**单独一组**展示，不并进关键词命中的照片里。
    /// ⚠️ 来源是 semanticItems（异步回来的那份），不在 results 里
    private var semanticPhotos: [Photo] {
        semanticItems.map { makeBadgedPhoto($0) }
    }

    /// 关键词命中的照片
    private var keywordPhotos: [Photo] {
        results.filter { $0.type == "photo" }.map { makeBadgedPhoto($0) }
    }

    /// 看图器的数据源：关键词在前、语义在后（与页面上的顺序一致）
    private var viewerPhotos: [Photo] { keywordPhotos + semanticPhotos }

    /// 照片瀑布流的裸组件。
    /// ⚠️ PhotoGrid 是 UICollectionView，没有 intrinsicContentSize，
    /// 必须由外层给定尺寸（GeometryReader 量剩下的空间），否则高度为 0
    private func photoGrid(_ photos: [Photo]) -> some View {
        GeometryReader { geo in
            PhotoGrid(photos: photos,
                      columns: photoColumns(width: geo.size.width),
                      onSelect: { openViewer(photos: viewerPhotos, id: $0.id) },
                      onReachEnd: { Task { await loadMore() } })
                // ⚠️ 底部扣掉底栏高度：网格不是 ScrollView，没有 safeArea 避让，
                // 不扣的话滑到底最后一行会被底栏盖住
                .frame(width: geo.size.width,
                       height: max(geo.size.height - BottomTabBar.height, 200))
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
            SearchPhotoThumb(photo: makeBadgedPhoto(item), size: width) { route(item) }
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
        /// 分组头右边的数字。
        /// ⚠️ 语义组没有 /search/totals 的来源（后端不算它），用自己的条数
        let count: Int
        var id: String { type }
        /// 语义组：单独一项，不并入「照片」组（两者区别是命中方式，不是内容类型）
        var isSemantic: Bool { type == "semantic" }
        var title: String {
            switch type {
            case "semantic": return "语义匹配"
            case "movie": return "电影"
            case "tv": return "剧集"
            case "album": return "相册"
            case "photo": return "照片"
            case "shoot": return "拍摄集"
            default: return "其他"
            }
        }
    }

    /// 分组头「查看全部」跳到哪个分类：
    /// · 语义组 → 照片（语义只在照片上工作，展开就是照片那一类）
    /// · tv 不是 Tab 的 case，「剧集」分组落到「影视」
    private func targetTab(_ section: ResultSection) -> Tab {
        if section.isSemantic { return .photo }
        if section.type == "tv" { return .movie }
        return Tab(rawValue: section.type) ?? .all
    }

    /// 把关键词结果按类型归组（后端按请求顺序返回，顺序是乱的）。
    /// ⚠️ 语义命中的照片**单独成一组，排最后**：它异步回来得慢，
    /// 放最后既不挡前面的结果，也不会在追加时把上面的组顶下去。
    private var sections: [ResultSection] {
        let order = ["movie", "tv", "album", "photo", "shoot"]
        var map: [String: [SearchItem]] = [:]
        for item in results { map[item.type, default: []].append(item) }
        // ⚠️ 显式写 [ResultSection] 和闭包返回类型：闭包里两个语句（guard + return），
        // Swift 推断不出复杂闭包的返回类型，会报
        // "Unable to infer complex closure return type"
        var list: [ResultSection] = order.compactMap { t -> ResultSection? in
            guard let items = map[t], !items.isEmpty else { return nil }
            return ResultSection(type: t, items: items, count: totals[t] ?? 0)
        }
        // 语义组：结果到了就有，还在跑就先给个占位组（告诉用户后面还有东西）
        if !semanticItems.isEmpty || isSemanticLoading {
            list.append(ResultSection(type: "semantic", items: semanticItems,
                                      count: semanticItems.count))
        }
        return list
    }

    /// 进入时处理首页带过来的初始词。没带词就自动聚焦键盘，省一次点击。
    @MainActor
    private func applyInitial() {
        guard !didApplyInitial else { return }
        didApplyInitial = true
        // 首页开着语义开关进来 → 直接落在「语义」这个 tab 上（它就是首页那个开关的意思）。
        // 首页没开就停在「全部」：关键词搜索照样会自动附带语义组，排在最后
        if semantic { isSemantic = true }
        let q = initialQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            fieldFocused = true
            return
        }
        query = q
        runSearch(q)
    }

    // MARK: 搜索入口
    //
    // ⚠️ 敲字不自动搜（防抖已取消，用户明确要求）：只有这几个入口会真的打接口 ——
    // ① 搜索框里的「🔍搜索」按钮  ② 键盘回车  ③ 分类 / 语义按钮（按当前词重搜）
    // ④ 点最近搜索  ⑤ 首页带词进来（applyInitial）。
    // 敲字只改 query，不影响正在展示的结果。

    @MainActor
    private func runSearch(_ text: String) {
        // 取消上一次在飞的请求：换词后旧结果已经没意义，
        // 而且它回来还会把新结果覆盖掉（请求返回顺序不保证）
        searchTask?.cancel()
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        activeQuery = q
        selectedTab = .all
        guard !q.isEmpty else {
            results = []; totals = [:]; resultTotal = 0; similarity = [:]
            semanticTask?.cancel(); semanticItems = []; isSemanticLoading = false
            return
        }
        SearchHistoryStore.add(q)
        history = SearchHistoryStore.load()
        startSearch()
    }

    /// 统一的请求入口：点搜索 / 切分类 / 切语义模式都走这里。
    /// 每次先取消上一次在飞的任务 —— 请求返回顺序不保证，不取消就会出现
    /// 「旧结果盖掉新结果」「两个词的结果混在一屏」。
    @MainActor
    private func startSearch() {
        // ⚠️ 点了按钮就按输入框里**当前的词**搜：用户可能改了词但没点搜索按钮，
        // 这时若沿用 activeQuery（上一次搜的词），按钮会看起来「点了没反应」
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty { activeQuery = q }
        searchTask?.cancel()
        // 语义是异步的，换条件时它在飞的那次也一并作废（reload 里会清空结果）
        semanticTask?.cancel()
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
        // 换词了，语义那一组也整个作废（旧词的语义结果不能留在新词下面）
        semanticTask?.cancel()
        semanticItems = []
        isSemanticLoading = false
        // 换词了，总数也得跟着重来（否则新词第一页会顶着上一个词的总数）
        keywordTotal = 0
        resultTotal = 0
        // 分类计数（/totals 有 5s 服务端缓存，切 Tab 不会重复打爆）。
        // ⚠️ 语义视图下也打：胶囊上的计数要保持准确，点回某个分类时数字才是对的
        do { totals = try await client.searchTotals(query: token) } catch { totals = [:] }
        // 计数回来期间词可能已经换了（或这次任务被取消了），别再往下翻页
        guard !Task.isCancelled, token == activeQuery else { return }
        if isSemantic {
            // 语义视图：只跑语义那一路。关键词结果在这页一条都不展示，
            // 再打一次关键词请求纯属浪费（还拖慢出结果的观感）
            hasMore = false
            startSemantic(token: token)
            return
        }
        await loadMore()
    }

    private let pageSize = 30

    @MainActor
    private func loadMore() async {
        // 语义视图没有关键词结果，翻页走它自己那条链路（按 offset 取下一批语义照片）
        if isSemantic { await loadMoreSemantic(); return }
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
            // 「全部」只取每类一批做总览，翻页交给各分类页
            let size = selectedTab == .all ? 8 : pageSize
            let p = try await client.searchGrouped(
                query: token, types: selectedTab.requestTypes, page: page, size: size)
            // 结果回来时词已经换了 / 任务被取消 → 整批丢弃，不能往列表里写
            guard !Task.isCancelled, token == activeQuery else { return }
            let isFirstPage = (page == 1)
            if isFirstPage { results = p.items } else { results.append(contentsOf: p.items) }
            keywordTotal = p.total
            resultTotal = keywordTotal + semanticItems.count
            page += 1
            hasMore = selectedTab == .all ? false : p.hasMore
            // 语义匹配（CLIP 推理）明显比关键词搜索慢，**异步**跑：
            // 关键词结果先落地渲染，语义结果到了再追加到最后一组 / 最后一段，
            // 不让慢的那一路拖住整页出结果。
            if isFirstPage { startSemantic(token: token) }
        } catch {
            // 旧词的报错也不该弹在新结果上
            guard !Task.isCancelled, token == activeQuery else { return }
            let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            errorMessage = "搜索失败 · " + msg
        }
    }

    /// 语义匹配（CLIP 以文搜图）拿回来的照片，**异步**跑（它比关键词搜索慢得多）。
    ///
    /// ⚠️ 两个用途，同一个请求：
    /// · 语义视图（isSemantic）：它就是这一页的全部结果；
    /// · 关键词视图：作为附加的一组 / 一段，排在最后（用户要「执行一次搜索顺带跑语义」）。
    /// ⚠️ 其它约束：
    /// · 只在第一页取一次（不参与翻页，翻页交给关键词搜索那一套）；
    /// · 影视/相册/拍摄集分类下不打（那几类没有向量）；
    /// · 失败一律静默（服务端没加载 CLIP 会返回 503），
    ///   绝不能让语义不可用把关键词搜索的结果也拖没了。
    @MainActor
    private func startSemantic(token: String) {
        // ⚠️ 括号不能省：&& 优先级高于 ||，而且 guard let 绑定不能只出现在 || 的一侧。
        // ⚠️ 只有「全部」（最后那组语义）和语义视图才打语义请求：
        // 照片 tab 已经不展示语义了，打了也是白打
        guard let client, (isSemantic || selectedTab == .all) else { return }
        semanticTask?.cancel()
        isSemanticLoading = true
        semanticTask = Task { @MainActor in
            // 语义视图取满一页（它要能往下翻）；「全部」只是总览，少取一点免得这一组一家独大
            let limit = isSemantic ? pageSize : 12
            // ⚠️ 用 var + 初值：do/catch 两个分支都给 let 赋值，编译器会判「初始化两次」
            var items: [SearchItem] = []
            // 语义响应自己的总匹配数（语义视图下要靠它判断还能不能往下翻）
            var total = 0
            do {
                let p = try await client.semanticSearch(query: token, limit: limit, offset: 0)
                total = p.total
                var map = similarity
                for r in p.results { map[r.id] = r.similarity ?? 0 }
                similarity = map
                items = p.results.map { makeSearchItem($0) }
            } catch {
                // 静默：CLIP 没加载（503）不该把关键词结果变成错误态
            }
            // 慢请求，回来时可能已经换了词 / 切了分类 / 任务被取消
            guard !Task.isCancelled else { return }
            // 词换了：这批结果整个作废。⚠️ loading 标记不在这里关 ——
            // 关掉的可能是**新词**那次请求的占位（它们共用同一个标记位），
            // 交给 reload / clearAll 去清（每次开搜都会先置 false）
            guard token == activeQuery else { return }
            isSemanticLoading = false
            // 去重放在写入这一刻：异步期间用户可能翻过页，results 已经不是原来那批了。
            // ⚠️ key 带 type：不同类型之间的 id 是各表自增的，会撞号
            var seen = Set(results.map { "\($0.type)-\($0.id)" })
            var added: [SearchItem] = []
            for var item in items {
                let key = "\(item.type)-\(item.id)"
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                // 打标记：靠它把语义结果单独拎出来成一组，不混进「照片」组
                item.semanticHit = true
                added.append(item)
            }
            semanticItems = added
            resultTotal = isSemantic ? total : keywordTotal + added.count
            // 语义视图要能往下翻：这一页没取完（且确实取到了东西）才留 hasMore。
            // ⚠️ reload 里先把 hasMore 设成了 false（语义视图不打关键词请求），
            // 真正的判断只能等语义响应回来
            if isSemantic { hasMore = !added.isEmpty && added.count < total }
        }
    }

    /// 语义视图的翻页：和关键词那套一样按 offset 翻，追加到语义结果后面。
    /// ⚠️ 之前语义只取一批就停了，滑到底没反应 —— 那就是「语义 tab 滑不动」的由来
    @MainActor
    private func loadMoreSemantic() async {
        let token = activeQuery
        guard let client, hasMore, !token.isEmpty else { return }
        // 同一个词的重复触底要互斥；loadingToken 和关键词那套复用（两个视图互斥，
        // 不会同时在跑）
        guard !(isSemanticLoading && loadingToken == token) else { return }
        isSemanticLoading = true
        loadingToken = token
        defer { if loadingToken == token { isSemanticLoading = false } }
        do {
            let p = try await client.semanticSearch(query: token, limit: pageSize,
                                                    offset: semanticItems.count)
            guard !Task.isCancelled, token == activeQuery else { return }
            var map = similarity
            for r in p.results { map[r.id] = r.similarity ?? 0 }
            similarity = map
            // 去重：offset 分页可能因为排序/新增出现重复
            var seen = Set(semanticItems.map { "\($0.type)-\($0.id)" })
            var added: [SearchItem] = []
            for var item in p.results.map({ makeSearchItem($0) }) {
                let key = "\(item.type)-\(item.id)"
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                item.semanticHit = true
                added.append(item)
            }
            semanticItems.append(contentsOf: added)
            resultTotal = p.total
            hasMore = !added.isEmpty && semanticItems.count < p.total
        } catch {
            guard !Task.isCancelled, token == activeQuery else { return }
            // 静默：翻页失败就当作没有更多，不要把整页结果变成错误态
            hasMore = false
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
                // 语义命中的相似度角标：与瀑布流 cell 里的 BadgeLabel 同款（左下角、
                // 半透明黑底）。横滑预览没法复用 UIKit 的 cell，这里补一枚同款的。
                .overlay(alignment: .bottomLeading) {
                    if let badge = photo.badge {
                        Text(badge)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.black.opacity(0.55), in: Capsule())
                            .padding(.leading, 6)
                            .padding(.bottom, 6)
                    }
                }
        }
        .buttonStyle(.plain)
    }
}
