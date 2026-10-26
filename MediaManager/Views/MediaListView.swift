import SwiftUI
import UIKit

// MARK: - 影视列表状态
// 对齐网页端 MediaListPage：selectedLibID 为 nil 时不传 lib，后端返回用户可见媒体库的全集
final class MediaListViewModel: ObservableObject {
    /// 排序方式（对齐网页版 MediaListPage 的 SORT_OPTIONS + 后端 /api/media sortMap）。
    /// ⚠️ 每个维度都做成降序在前、升序在后的一对：只有降序档的维度，
    /// 用户没法按「最早的先看」，那正是这次要补的「升降序」。
    enum Sort: String, CaseIterable, Sendable {
        case updated = "updated_desc"
        case updatedAsc = "updated_asc"
        case title = "title"
        case titleDesc = "title_desc"
        case year = "year_desc"
        case yearAsc = "year_asc"
        case rating = "rating_desc"
        case ratingAsc = "rating_asc"
        case premiered = "premiered_desc"
        case premieredAsc = "premiered_asc"
        var label: String {
            switch self {
            case .updated: return "最新更新"
            case .updatedAsc: return "最早更新"
            case .title: return "标题 A→Z"
            case .titleDesc: return "标题 Z→A"
            case .year: return "年份 新→旧"
            case .yearAsc: return "年份 旧→新"
            case .rating: return "评分 高→低"
            case .ratingAsc: return "评分 低→高"
            case .premiered: return "上映 新→旧"
            case .premieredAsc: return "上映 旧→新"
            }
        }
    }

    let type: String
    /// 固定库模式：从「媒体库卡片墙」点进来时传入，直接看该库内容，不再拉库列表/显示筛选菜单
    let fixedLibrary: Library?

    @Published var items: [MediaItem] = []
    @Published var libraries: [Library] = []
    @Published var selectedLibID: Int?
    /// 排序：初值从本机记忆还原（见 ListSearchPrefs），didSet 里落盘
    @Published var sort: Sort {
        didSet { ListSearchPrefs.saveSort(prefsPage, raw: sort.rawValue) }
    }
    /// 搜索词：同样记忆 —— 离开页面再回来（含杀进程重开）不用重新打字
    @Published var searchText = "" {
        didSet { ListSearchPrefs.saveSearch(prefsPage, searchText) }
    }
    @Published var totalCount = 0
    @Published var isLoading = false
    @Published var errorMessage: String?

    /// 记忆键按「页」分：电影和剧集各记一份，互不串味
    private let prefsPage: String

    private var page = 1
    private let pageSize = 60
    private var hasMore = true

    private var client: APIClient? { AppSession.shared.client }

    var selectedLibrary: Library? { libraries.first { $0.id == selectedLibID } }

    init(type: String, library: Library? = nil) {
        self.type = type
        self.fixedLibrary = library
        self.selectedLibID = library?.id
        self.prefsPage = "media.\(type)"
        // 还原上次的搜索词与排序（没记过就用默认值）
        self.searchText = ListSearchPrefs.loadSearch(prefsPage)
        self.sort = ListSearchPrefs.loadSort(prefsPage, fallback: .updated)
    }

    @MainActor
    func loadLibraries() async {
        guard let client else {
            errorMessage = "未连接服务器"
            return
        }
        // 固定库模式：库已由外层指定，直接加载内容
        if fixedLibrary != nil {
            if items.isEmpty { await reload() }
            return
        }
        // 库列表和内容并行：库列表只喂顶部筛选菜单，不该阻塞内容首屏。
        // 之前是串行（先 await 库列表再 reload），库列表里 photo 库的 COUNT 慢时会拖慢整页。
        async let libsTask = client.mediaLibraries(ofMediaType: type)
        // 同 AlbumListView：从详情返回本页时 .task 可能重跑，此时 reload 会清空 items
        // 让 ScrollView 弹回顶部。已有数据就跳过，保住滚动位置。
        if items.isEmpty {
            await reload()
        }
        do {
            libraries = try await libsTask
        } catch {
            // 库列表拉不到不阻塞内容加载，退化成「全部」
            libraries = []
        }
    }

    @MainActor
    func selectLibrary(_ id: Int?) async {
        selectedLibID = id
        await reload()
    }

    @MainActor
    func setSort(_ s: Sort) async {
        guard sort != s else { return }
        sort = s
        await reload()
    }

    @MainActor
    func reload() async {
        items = []
        page = 1
        hasMore = true
        await loadMore()
    }

    /// 下拉刷新：保留旧列表，加载第一页后替换（避免闪空）。
    /// ⚠️ 不碰 isLoading（它触发 body 重算，会让 .refreshable 的刷新 Task 被取消 → 请求取消），
    /// 刷新指示由系统的 refreshable 转圈承担。
    @MainActor
    func refresh() async {
        guard let client, !isLoading else { return }
        page = 1
        hasMore = true
        do {
            let (batch, total) = try await client.fetchMedia(type: type, libID: selectedLibID, page: page, size: pageSize, sort: sort.rawValue, q: searchText.isEmpty ? nil : searchText)
            applyTotal(total)
            items = batch
            page += 1
            hasMore = !batch.isEmpty && hasMoreAfter(batchCount: batch.count, total: total)
        } catch {
            errorMessage = "加载失败 · \(describe(error))"
        }
    }

    @MainActor
    func loadMore(replacing: Bool = false) async {
        guard let client, !isLoading, hasMore else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let (batch, total) = try await client.fetchMedia(type: type, libID: selectedLibID, page: page, size: pageSize, sort: sort.rawValue, q: searchText.isEmpty ? nil : searchText)
            applyTotal(total)
            if replacing {
                items = batch
            } else {
                items.append(contentsOf: batch)
            }
            page += 1
            hasMore = !batch.isEmpty && hasMoreAfter(batchCount: batch.count, total: total)
        } catch {
            errorMessage = "加载失败 · \(describe(error))"
        }
    }

    /// ⚠️ 后端只在第 1 页算总条数，翻页时返回 -1 哨兵
    ///（task-service/internal/routes/media.go：非首页不跑 COUNT，省一次全表扫描）。
    /// 直接把 -1 写进 totalCount 就会显示「34 / -1」，所以负数一律视为「未知」并保留旧值。
    private func applyTotal(_ total: Int) {
        if total >= 0 { totalCount = total }
    }

    /// 还能不能继续翻页。总数已知就按总数比；未知（-1）时退回后端自己的判据：
    /// 本页拉满说明后面可能还有（后端非首页的 hasMore 就是 len(items) == size）。
    /// ⚠️ 不这么写的话，第 2 页拿到 -1 会让 `items.count < total` 恒为 false，
    /// 分页在第二页就悄悄停住，列表永远停在前 120 条。
    private func hasMoreAfter(batchCount: Int, total: Int) -> Bool {
        total >= 0 ? items.count < total : batchCount >= pageSize
    }

    private func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

// MARK: - 影视列表页（电影 / 剧集通用）
struct MediaListView: View {
    let type: String
    let library: Library?

    @StateObject private var viewModel: MediaListViewModel
    @StateObject private var layout: CardLayoutController
    @State private var selected: MediaItem?
    /// 工具栏「演员」chip → 演员库页（按演员找片，电影/剧集共用）
    @State private var showActors = false
    /// 捏合手势起始宽度（MagnificationGesture 的 scale 相对手势开始，需记下起始值）
    @State private var pinchStartWidth: CGFloat = 0
    /// 窄屏（iPhone）下隐藏滑块与计数 —— 一行塞不下时优先让出冗余信息（捏合也能缩放）
    @Environment(\.horizontalSizeClass) private var hSizeClass

    /// 根据容器宽算列布局：列数 + 每列宽。
    /// 对齐网页版 `grid-template-columns: repeat(auto-fill, minmax(size, 1fr))`：
    /// 列宽 = 均分（≥ cardWidth），卡片填满整列，不留空隙。之前用
    /// adaptive(minimum:) 时列宽可能大于卡片固定宽，卡片居中留白导致「间隙太大」。
    private func gridLayout(containerWidth: CGFloat) -> (columns: [GridItem], itemWidth: CGFloat) {
        let spacing: CGFloat = 18
        let padding: CGFloat = 16
        let gridW = max(containerWidth - padding * 2, 0)
        let n = max(1, Int((gridW + spacing) / (layout.cardWidth + spacing)))
        let itemW = (gridW - spacing * CGFloat(n - 1)) / CGFloat(n)
        let cols = Array(repeating: GridItem(.flexible(), spacing: spacing), count: n)
        return (cols, itemW)
    }

    init(type: String, library: Library? = nil) {
        self.type = type
        self.library = library
        _viewModel = StateObject(wrappedValue: MediaListViewModel(type: type, library: library))
        _layout = StateObject(wrappedValue: CardLayoutController(
            baseKey: "mediaList", libID: library?.id,
            portraitDefault: 150, landscapeDefault: 240,
            portraitRange: 100...260, landscapeRange: 130...400
        ))
    }

    var body: some View {
        // 网格：用 GeometryReader 测容器宽（稳定值，非 cell 高度），
        // 自己算列数让卡片填满列宽，捏合时列数跳变但卡片始终铺满、无间隙。
        GeometryReader { geo in
            let grid = gridLayout(containerWidth: geo.size.width)
            ScrollView {
                LazyVGrid(columns: grid.columns, spacing: 18) {
                    ForEach(viewModel.items) { item in
                        let cover = AppSession.shared.client?.mediaCoverURL(item, landscape: layout.landscape)
                        MediaCard(item: item, coverURL: cover, width: grid.itemWidth, landscape: layout.landscape,
                                  showInfo: layout.cardWidth >= CardLayoutController.compactThreshold) {
                            selected = item
                        }
                        .task {
                            if item.id == viewModel.items.last?.id {
                                await viewModel.loadMore()
                            }
                        }
                    }
                }
                .padding(16)
                .bottomBarClearance()
                // 列数跳变时用弹簧动画平滑过渡，别让卡片尺寸「突然跳」
                .animation(.spring(response: 0.28, dampingFraction: 0.85), value: grid.columns.count)
                if viewModel.isLoading {
                    ProgressView().frame(maxWidth: .infinity).padding()
                }
            }
            // 双指捏合缩放卡片大小（对齐网页版 usePinchToResize）
            .simultaneousGesture(pinchGesture)
        }
        // ⚠️ 导航栏必须保持可见。隐藏它会让系统的右滑返回失效，而 SwiftUI 的
        // NavigationStack 在 push 之后不再渲染下一层 —— 任何自定义手势都只能推出
        // 一片空白（右滑到一半是白屏）。导航栏可见时系统手势和系统 pop 转场
        // 都由 UINavigationController 接管，效果与电影详情页返回列表完全一致。
        // ⚠️ 系统返回按钮必须留着：它和右滑返回手势是绑定的，
        // .navigationBarBackButtonHidden(true) 会把 interactivePop 一起禁掉，
        // 而且没有任何可靠手段能单独把手势取回来（自定义位移会白屏，
        // UIKit 桥接在这个场景下也接管不了转场）。样式只能走 tint / appearance。
        .toolbar {
            // 靠左 + 固定宽度（ListSearchBarItem.width），三个列表页共用同一个组件；
            // 媒体库名跟在搜索框后面（可拉长，宽度不够才尾部省略）
            ListSearchBarItem(text: $viewModel.searchText,
                              placeholder: "搜索标题、演员、类型…",
                              title: library?.name ?? (type == "tv" ? "剧集" : "电影"),
                              narrow: hSizeClass == .compact)
            // 右侧整组收进一个 ToolbarItem（TrailingToolsItem），间距由 ToolbarMetrics 统一：
            // 按钮之间等距等高，计数与按钮之间单独留 countGap（纯文本与可点按钮视觉分组）
            TrailingToolsItem {
                sortMenu
                // 演员库入口：按演员找片（对齐网页端左侧「演员」导航项）
                ToolChip(label: "演员", icon: "person.2.fill") {
                    showActors = true
                }
                // 只留图标：图标本身够直观，省下的宽度留给搜索框
                ToolChip(label: layout.landscape ? "横版" : "竖版",
                         icon: layout.landscape ? "rectangle" : "rectangle.portrait",
                         highlighted: layout.landscape,
                         iconOnly: true) {
                    layout.toggleOrientation()
                }
                // 固定库模式不显示库筛选（只有一个库）
                if library == nil && !viewModel.libraries.isEmpty { libraryMenu }
                if hSizeClass == .regular {
                    Text("\(viewModel.items.count) / \(viewModel.totalCount)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        // ⚠️ 不加 fixedSize：工具栏空间紧张时 Text 会被压缩换行，
                        // 变成「1234 / 5678」上下两行，把导航栏撑高
                        .fixedSize(horizontal: true, vertical: false)
                        .lineLimit(1)
                        // ⚠️ 给计数留固定槽位：整排锚定在屏幕右缘，数字位数一变
                        //（60/588 → 120/1200）整排按钮就被推着左右挪。
                        // 右对齐 + 最小宽度 → 常见位数下按钮位置纹丝不动。
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
        .refreshing { await viewModel.refresh() }
        // ⚠️ iOS 17 起 onChange(of:) 零参闭包
        .onChange(of: viewModel.searchText) {
            Task {
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled else { return }
                await viewModel.reload()
            }
        }
        .overlay {
            if viewModel.items.isEmpty && !viewModel.isLoading {
                ContentUnavailableView(
                    viewModel.errorMessage ?? "暂无内容",
                    systemImage: viewModel.errorMessage == nil ? "film" : "exclamationmark.triangle"
                )
            }
        }
        .task { await viewModel.loadLibraries() }
        .navigationDestination(item: $selected) { item in
            MediaDetailView(media: item)
        }
        .navigationDestination(isPresented: $showActors) {
            ActorsView()
        }
    }

    /// 排序选择（对齐网页版列表页顶部状态栏）
    private var sortMenu: some View {
        ToolMenuChip(label: viewModel.sort.label) {
            ForEach(MediaListViewModel.Sort.allCases, id: \.self) { s in
                Button {
                    Task { await viewModel.setSort(s) }
                } label: {
                    if viewModel.sort == s { Label(s.label, systemImage: "checkmark") }
                    else { Text(s.label) }
                }
            }
        }
    }

    /// 双指捏合缩放卡片大小。scale 相对手势开始，所以记下起始宽度再乘比例。
    /// 拖动中只改内存（resize 不落盘），松手才 commit 落盘，避免高频写 UserDefaults 卡顿。
    private var pinchGesture: some Gesture {
        MagnificationGesture()
            .onChanged { scale in
                if pinchStartWidth == 0 { pinchStartWidth = layout.cardWidth }
                layout.resize(to: pinchStartWidth * scale)
            }
            .onEnded { _ in
                pinchStartWidth = 0
                layout.commit()
            }
    }

    /// 库选择放导航栏下拉菜单（iOS 常见样式），不再挤在顶部占一整行
    private var libraryMenu: some View {
        Menu {
            Button {
                Task { await viewModel.selectLibrary(nil) }
            } label: {
                if viewModel.selectedLibID == nil {
                    Label("全部", systemImage: "checkmark")
                } else {
                    Text("全部")
                }
            }
            ForEach(viewModel.libraries) { lib in
                Button {
                    Task { await viewModel.selectLibrary(lib.id) }
                } label: {
                    if lib.id == viewModel.selectedLibID {
                        Label(lib.name, systemImage: "checkmark")
                    } else {
                        Text(lib.name)
                    }
                }
            }
        } label: {
            // 与排序按钮共用 ToolMenuLabel：同字体（caption）、同高度、同内边距
            ToolMenuLabel(text: viewModel.selectedLibrary?.name ?? "全部")
        }
        // ⚠️ Menu 是控件，页面上的 .tint(Theme.brand) 会盖掉 label 里的
        // foregroundStyle（标题和展开后的菜单都变品牌色），必须给控件本身换 tint
        .tint(Color.secondary)
    }
}

// MARK: - 影视卡
struct MediaCard: View {
    let item: MediaItem
    var coverURL: URL?
    var width: CGFloat = 150
    /// 横版封面（16:9）还是竖版海报（2:3）
    var landscape: Bool = false
    /// 是否显示下方标题区（卡片够大时）。由外层按 cardWidth 判断传入，而非列宽。
    var showInfo: Bool = true
    var onTap: () -> Void = {}

    private var coverHeight: CGFloat { width * (landscape ? 9.0 / 16.0 : 3.0 / 2.0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottom) {
                ZStack(alignment: .topTrailing) {
                    RemoteImage(
                        url: coverURL,
                        fallbackIcon: item.type == "tv" ? "tv" : "film",
                        fallbackColors: Theme.placeholderGradient(for: .media)
                    )
                    .imageFilled()
                    .frame(width: width, height: coverHeight)
                    .clipShape(RoundedRectangle(cornerRadius: showInfo ? 10 : 8, style: .continuous))

                    // 横版右上角评分徽章（对齐网页版 MediaCard 的 ★ rating）
                    if landscape, let r = item.rating, r > 0 {
                        Text(String(format: "★ %.1f", r))
                            .font(.caption2.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.black.opacity(0.6), in: Capsule())
                            .padding(6)
                    }
                }

                // 小卡片：底部渐变条 + 标题（iOS 无 hover 故常驻）
                if !showInfo {
                    LinearGradient(colors: [.clear, .black.opacity(0.72)], startPoint: .top, endPoint: .bottom)
                        .frame(height: coverHeight * 0.55)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .allowsHitTesting(false)
                    Text(item.title)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.horizontal, 6)
                        .padding(.bottom, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if showInfo {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    // 番号 + 年份元信息行（对齐网页 MediaCard：番号等宽字体、
                    // 比年份亮一档；标题已含番号时只显示年份）
                    let code = item.code
                    let year = item.subtitle
                    if code != nil || !year.isEmpty {
                        HStack(spacing: 0) {
                            if let code {
                                Text(code)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(Color.primary.opacity(0.75))
                                if !year.isEmpty {
                                    Text(" · ")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if !year.isEmpty {
                                Text(year)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .font(.caption2)
                        .lineLimit(1)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .frame(width: width, alignment: .leading)
            }
        }
        .frame(width: width)
        .appSurface(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color(uiColor: .separator).opacity(0.6), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.10), radius: 8, x: 0, y: 3)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}
