import SwiftUI
import UIKit
import Combine

// MARK: - 相册列表状态
final class AlbumListViewModel: ObservableObject {
    /// 排序方式（对齐网页版 AlbumListPage 的排序下拉 + 后端 /api/photos sortMap）
    enum Sort: String, CaseIterable, Sendable {
        case updatedDesc = "updated_desc"
        case updatedAsc = "updated_asc"
        case releaseDesc = "release_desc"
        case releaseAsc = "release_asc"
        case nameAsc = "name_asc"
        case nameDesc = "name_desc"
        case random = "random"
        var label: String {
            switch self {
            case .updatedDesc: return "最新更新"
            case .updatedAsc: return "最早更新"
            case .releaseDesc: return "最新发表"
            case .releaseAsc: return "最早发表"
            case .nameAsc: return "名称 A→Z"
            case .nameDesc: return "名称 Z→A"
            case .random: return "随机"
            }
        }
    }

    /// 固定库模式：从「媒体库卡片墙」点进来时传入，直接看该库相册
    let fixedLibrary: Library?

    @Published var albums: [Album] = []
    @Published var libraries: [Library] = []
    @Published var selectedLibID: Int?
    /// 排序：初值从本机记忆还原（见 ListSearchPrefs），didSet 里落盘
    @Published var sort: Sort {
        didSet { ListSearchPrefs.saveSort(prefsPage, raw: sort.rawValue) }
    }
    /// 搜索词：相册页按用户要求「切走即清空」——不落盘、不还原。
    /// 置空后由页面的 .onChange(of: searchText) 350ms 防抖 reload 回完整列表。
    @Published var searchText = ""
    @Published var totalCount = 0
    @Published var isLoading = false
    @Published var errorMessage: String?

    /// 记忆键按「页」分：相册列表记一份（排序仍持久化）
    private let prefsPage = "albums"
    /// 切页面信号订阅：tab 是 ZStack + opacity 常驻，页面不卸载，onDisappear 不触发
    private var leaveCancellable: AnyCancellable? = nil

    private var page = 1
    private let pageSize = 60
    private var hasMore = true

    private var client: APIClient? { AppSession.shared.client }

    var selectedLibrary: Library? { libraries.first { $0.id == selectedLibID } }

    init(library: Library? = nil) {
        self.fixedLibrary = library
        self.selectedLibID = library?.id
        // 🔴 2026-11-10 用户要求「相册搜索框切走就清空」：不再还原上次搜索词，
        // 顺手抹掉旧版本已写进 UserDefaults 的值（否则杀进程重开旧词又冒出来）。
        ListSearchPrefs.clearSearch("albums")
        self.searchText = ""
        self.sort = ListSearchPrefs.loadSort("albums", fallback: .updatedDesc)
        // RootView 切 tab / 导航栈 push 时页面并不卸载（ZStack + opacity 常驻），
        // onDisappear 不触发，所以用通知清。只置空，reload 交给页面 onChange 防抖。
        leaveCancellable = NotificationCenter.default.publisher(for: .listPageShouldResetSearch)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self, !self.searchText.isEmpty else { return }
                    self.searchText = ""
                }
            }
    }

    @MainActor
    func loadLibraries() async {
        guard let client else {
            errorMessage = "未连接服务器"
            return
        }
        // 固定库模式：库已指定，直接加载
        if let lib = fixedLibrary {
            libraries = [lib]
            selectedLibID = lib.id
            guard albums.isEmpty else { return }
            await reload()
            return
        }
        do {
            let libs = try await client.photoLibraries()
            libraries = libs
            if selectedLibID == nil { selectedLibID = libs.first?.id }

            // ⚠️ 从相册详情返回本页时，SwiftUI 可能再次触发本页的 .task。
            // 若此时走 reload()，会先把 albums 清空 —— ScrollView 内容变空后弹回顶部，
            // 等新数据回来滚动位置已经丢了，表现就是「返回闪一下、跳回列表顶部」。
            // 所以已有数据时直接跳过，保留列表内容与滚动位置，做到「从哪进的返回还在哪」。
            // 真正需要重置列表的场景（切换媒体库）仍由 selectLibrary 显式调 reload。
            guard albums.isEmpty else { return }

            await reload()
        } catch {
            errorMessage = "加载媒体库失败 · \(describe(error))"
        }
    }

    @MainActor
    func selectLibrary(_ id: Int) async {
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
        albums = []
        page = 1
        hasMore = true
        await loadMore()
    }

    /// 下拉刷新：保留旧列表，加载第一页后替换（避免闪空）。
    /// ⚠️ 不碰 isLoading（触发 body 重算会让 .refreshable 的刷新 Task 被取消），
    /// 刷新指示由系统 refreshable 转圈承担。
    @MainActor
    func refresh() async {
        guard let client, let libID = selectedLibID, !isLoading else { return }
        page = 1
        hasMore = true
        do {
            let (items, total) = try await client.fetchAlbums(libID: libID, page: page, size: pageSize, sort: sort.rawValue, q: searchText.isEmpty ? nil : searchText)
            totalCount = total
            albums = items
            page += 1
            hasMore = !items.isEmpty && albums.count < total
        } catch {
            errorMessage = "加载相册失败 · \(describe(error))"
        }
    }

    @MainActor
    func loadMore(replacing: Bool = false) async {
        guard let client, let libID = selectedLibID, !isLoading, hasMore else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let (items, total) = try await client.fetchAlbums(libID: libID, page: page, size: pageSize, sort: sort.rawValue, q: searchText.isEmpty ? nil : searchText)
            totalCount = total
            if replacing {
                albums = items
            } else {
                albums.append(contentsOf: items)
            }
            page += 1
            hasMore = !items.isEmpty && albums.count < total
        } catch {
            errorMessage = "加载相册失败 · \(describe(error))"
        }
    }

    private func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

// MARK: - 相册列表页
// 对齐网页端 AlbumListPage：相册网格（封面 + 标题 + 张数），点进相册看照片
struct AlbumListView: View {
    let library: Library?

    @StateObject private var viewModel: AlbumListViewModel
    @StateObject private var layout: CardLayoutController
    /// 捏合手势起始宽度
    @State private var pinchStartWidth: CGFloat = 0
    /// 搜索防抖任务：切走清空时要取消上一次输入挂起的 reload，
    /// 否则两个 Task 竞争，可能又把列表刷回搜索结果。
    @State private var searchDebounce: Task<Void, Never>? = nil
    /// 窄屏（iPhone）下隐藏滑块与计数 —— 一行塞不下时优先让出冗余信息（捏合也能缩放）
    @Environment(\.horizontalSizeClass) private var hSizeClass

    /// 根据容器宽算列布局（对齐网页版 minmax(size,1fr)：卡片填满整列不留空隙）
    private func gridLayout(containerWidth: CGFloat) -> (columns: [GridItem], itemWidth: CGFloat) {
        let spacing: CGFloat = 18
        let padding: CGFloat = 16
        let gridW = max(containerWidth - padding * 2, 0)
        let n = max(1, Int((gridW + spacing) / (layout.cardWidth + spacing)))
        let itemW = (gridW - spacing * CGFloat(n - 1)) / CGFloat(n)
        let cols = Array(repeating: GridItem(.flexible(), spacing: spacing), count: n)
        return (cols, itemW)
    }

    init(library: Library? = nil) {
        self.library = library
        _viewModel = StateObject(wrappedValue: AlbumListViewModel(library: library))
        _layout = StateObject(wrappedValue: CardLayoutController(
            baseKey: "albumList", libID: library?.id,
            portraitDefault: 140, landscapeDefault: 210,
            portraitRange: 90...300, landscapeRange: 130...480
        ))
    }

    var body: some View {
        // 网格：GeometryReader 测容器宽，卡片填满列宽（对齐网页版 minmax(size,1fr)）
        GeometryReader { geo in
            let grid = gridLayout(containerWidth: geo.size.width)
            ScrollView {
                // 人物（人脸聚类）：照片的第二种组织方式，与相册并列。
                // 自己拉数据（全局聚类，不按库/排序过滤），见 AlbumPersonsRow
                AlbumPersonsRow()
                    .padding(.horizontal, 16)
                LazyVGrid(columns: grid.columns, spacing: 18) {
                    ForEach(viewModel.albums) { album in
                        NavigationLink(value: album) {
                            AlbumCard(album: album, coverURL: coverURL(for: album, landscape: layout.landscape),
                                      width: grid.itemWidth, landscape: layout.landscape,
                                      showInfo: layout.cardWidth >= CardLayoutController.compactThreshold,
                                      // 封面宽高比跟库设置走（与网页端同一份数据）：
                                      // 横版读 cardAspectRatioLandscape、竖版读 cardAspectRatioPortrait
                                      aspectOverride: layout.landscape
                                          ? viewModel.selectedLibrary?.cardAspectLandscape
                                          : viewModel.selectedLibrary?.cardAspectPortrait)
                        }
                        .buttonStyle(.plain)
                        .task {
                            // 滚到末尾前预取
                            if album.id == viewModel.albums.last?.id {
                                await viewModel.loadMore()
                            }
                        }
                    }
                }
                .padding(16)
                .bottomBarClearance()
                // 列数跳变时用弹簧动画平滑过渡
                .animation(.spring(response: 0.28, dampingFraction: 0.85), value: grid.columns.count)
                if viewModel.isLoading {
                    ProgressView().frame(maxWidth: .infinity).padding()
                }
            }
            // 双指捏合缩放卡片大小（对齐网页版 usePinchToResize）
            .simultaneousGesture(pinchGesture)
        }
        // ⚠️ 导航栏一律保持可见（隐藏会让系统右滑返回失效，而 NavigationStack push 后
        // 不渲染下一层，自定义手势只能推出白屏）。搜索框放 principal 位，导航栏因而
        // 不额外占高度。固定库模式下系统返回按钮自动出现在搜索框左边；
        // 跨库模式（首页 sheet 入口）是栈底没有上一层，系统不会给返回按钮，
        // sheet 的「完成」按钮由外层 HomeView 的 confirmationAction 提供。
        // ⚠️ 系统返回按钮必须留着：藏了它右滑手势会一起没（见 MediaListView 注释）。
        // 跨库模式是栈底没有上一层，系统不会给返回按钮。
        .toolbar {
            // 靠左 + 固定宽度（ListSearchBarItem.width），三个列表页共用同一个组件；
            // 媒体库名跟在搜索框后面（可拉长，宽度不够才尾部省略）
            ListSearchBarItem(text: $viewModel.searchText,
                              placeholder: "搜索相册名…",
                              title: library?.name ?? "相册",
                              narrow: hSizeClass == .compact)
            // 原来网格上方的工具行整行收进导航栏，页面只剩导航栏一行。
            // 跨库模式（sheet）时「完成」按钮来自外层 HomeView，与这里的 trailing 共存。
            // 右侧整组收进一个 ToolbarItem（TrailingToolsItem），间距由 ToolbarMetrics 统一
            TrailingToolsItem {
                sortMenu
                // 只留图标：图标本身够直观，省下的宽度留给搜索框
                ToolChip(label: layout.landscape ? "横版" : "竖版",
                         icon: layout.landscape ? "rectangle" : "rectangle.portrait",
                         highlighted: layout.landscape,
                         iconOnly: true) {
                    layout.toggleOrientation()
                }
                // 固定库模式不显示库筛选
                if library == nil && viewModel.libraries.count > 1 { libraryMenu }
                if hSizeClass == .regular {
                    Text("\(viewModel.albums.count) / \(viewModel.totalCount)")
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
            searchDebounce?.cancel()
            searchDebounce = Task {
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled else { return }
                await viewModel.reload()
            }
        }
        .navigationDestination(for: Album.self) { album in
            AlbumPhotosView(album: album, libID: viewModel.selectedLibID ?? 0)
        }
        // 顶部人物行 → 人物照片页（Person 是 Hashable，与 Album 同为 value 型 destination）
        .navigationDestination(for: Person.self) { person in
            PersonPhotosView(person: person)
        }
        .overlay {
            if viewModel.albums.isEmpty && !viewModel.isLoading {
                ContentUnavailableView(
                    viewModel.errorMessage ?? "暂无相册",
                    systemImage: viewModel.errorMessage == nil ? "photo.on.rectangle" : "exclamationmark.triangle"
                )
            }
        }
        .task { await viewModel.loadLibraries() }
    }

    /// 排序选择（对齐网页版列表页顶部状态栏）
    private var sortMenu: some View {
        ToolMenuChip(label: viewModel.sort.label) {
            ForEach(AlbumListViewModel.Sort.allCases, id: \.self) { s in
                Button {
                    Task { await viewModel.setSort(s) }
                } label: {
                    if viewModel.sort == s { Label(s.label, systemImage: "checkmark") }
                    else { Text(s.label) }
                }
            }
        }
    }

    /// 双指捏合缩放卡片大小。拖动中只改内存，松手才 commit 落盘。
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
            ToolMenuLabel(text: viewModel.selectedLibrary?.name ?? "选择相册库")
        }
        // ⚠️ Menu 是控件，页面上的 .tint(Theme.brand) 会盖掉 label 里的
        // foregroundStyle（标题和展开后的菜单都变品牌色），必须给控件本身换 tint
        .tint(Color.secondary)
    }

    private func coverURL(for album: Album, landscape: Bool = false) -> URL? {
        // 横版用横封面，竖版用竖封面（缺哪个就退回另一个）
        let id = landscape ? (album.coverPhotoId ?? album.coverPhotoIdPortrait) : album.preferredCoverId
        guard let id else { return nil }
        return AppSession.shared.client?.makeURL("/photo", queryItems: [
            URLQueryItem(name: "id", value: "\(id)"),
            URLQueryItem(name: "size", value: "600"),
        ])
    }
}

// MARK: - 相册卡
struct AlbumCard: View {
    let album: Album
    var coverURL: URL?
    var width: CGFloat = 170
    /// 横版封面（16:9）还是竖版（2:3）
    var landscape: Bool = false
    /// 是否显示下方标题区（卡片够大时）。由外层按 cardWidth 判断传入，而非列宽：
    /// 列宽是均分结果、受屏幕宽度影响，用 cardWidth 才能让「小卡片」状态可预测。
    var showInfo: Bool = true
    /// 封面宽高比覆盖（w/h，如 1.5 = 3:2）。来自库设置 cardAspectRatioLandscape/Portrait，
    /// 与网页端同一份数据；nil = 用默认（横 16:9 / 竖 2:3）。
    /// ⚠️ 16:9 的框装 3:2 的照片会上下各裁掉约 8%——封面顶部的大字标题就是这么被切掉的，
    /// 库里设了 3:2 就得跟着用，否则 iOS 比网页端多裁一截。
    var aspectOverride: CGFloat? = nil

    private var coverHeight: CGFloat {
        let ratio = aspectOverride ?? (landscape ? 16.0 / 9.0 : 2.0 / 3.0)
        return width / ratio
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottom) {
                // 封面 + 右下张数角标
                ZStack(alignment: .bottomTrailing) {
                    RemoteImage(url: coverURL, fallbackIcon: "photo.on.rectangle")
                        .imageFilled()
                        .frame(width: width, height: coverHeight)
                        .clipShape(RoundedRectangle(cornerRadius: showInfo ? 10 : 8, style: .continuous))
                    if showInfo {
                        Text("\(album.count)")
                            .font(.caption2.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.black.opacity(0.55), in: Capsule())
                            .padding(7)
                    }
                }

                // 小卡片：底部渐变条 + 标题（对齐网页版的悬浮渐变标题，iOS 无 hover 故常驻）
                if !showInfo {
                    LinearGradient(colors: [.clear, .black.opacity(0.72)], startPoint: .top, endPoint: .bottom)
                        .frame(height: coverHeight * 0.55)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .allowsHitTesting(false)
                    Text(album.title)
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
                    Text(album.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    HStack(spacing: 4) {
                        if let d = album.releaseDate, !d.isEmpty {
                            Text(d)
                            Text("·")
                        }
                        Text("\(album.count) 张")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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
    }
}

// MARK: - 相册列表页顶部的人物行
// 人物是全局人脸聚类（不按媒体库过滤），与相册并列作为「看照片」的第二种组织方式
// （网页端 PersonsPage 是顶级路由，iOS 消费端收进相册分类内，见 IA 决策）。
// 自己持一个 PersonsViewModel：不吃 AlbumListViewModel 的库/排序/搜索状态，
// 也不参与相册网格翻页。加载中/失败/为空都不占位 —— 相册列表才是本页主角。
private struct AlbumPersonsRow: View {
    @StateObject private var viewModel = PersonsViewModel()

    var body: some View {
        Group {
            if !viewModel.items.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(icon: "person.2.fill", title: "人物")
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 12) {
                            ForEach(viewModel.items.prefix(20)) { person in
                                NavigationLink(value: person) {
                                    VStack(spacing: 6) {
                                        avatar(person)
                                        Text(person.displayName)
                                            .font(.caption2)
                                            .lineLimit(1)
                                            .frame(width: 64)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 2)
                    }
                }
                .padding(.bottom, 6)
            }
        }
        .task { await viewModel.loadInitial() }
    }

    /// 封面优先（/person-cover 的上半身标准肖像，原生 3:4）；该簇没产出封面时退回代表脸
    private func avatar(_ person: Person) -> some View {
        RemoteImage(url: coverURL(person), fallbackURL: avatarURL(person),
                    fallbackIcon: "person.fill",
                    fallbackColors: Theme.placeholderGradient(for: .photo))
            .imageFilled(alignment: .top)
            .frame(width: 64, height: 85)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// 人物封面，参数是簇 id
    private func coverURL(_ person: Person) -> URL? {
        AppSession.shared.client?.personCoverURL(person.id)
    }

    /// 回退用的代表脸头像（/face-thumb）
    private func avatarURL(_ person: Person) -> URL? {
        guard let faceId = person.representativeFaceId else { return nil }
        return AppSession.shared.client?.faceThumbURL(faceId)
    }
}

// MARK: - 相册内照片
struct AlbumPhotosView: View {
    let album: Album
    /// 后端 /api/photos 强制要求 lib，缺失会 400
    let libID: Int
    /// 返回回调。非 nil 说明本页是「盖在看图器上的相册层」，顶栏最左给返回按钮
    ///（本层不是 push 进导航栈的，没有系统返回手势，返回靠这个按钮 / 左边缘拖拽）。
    var onBack: (() -> Void)? = nil

    @State private var photos: [Photo] = []
    /// 瀑布流列数：双指捏合缩放，按「相册照片页」记忆（对齐列表页的卡片宽度记忆）
    @State private var columns = PhotoGridPrefs.load("albumPhotos", fallback: 4)
    @State private var isLoading = false
    @State private var page = 1
    @State private var hasMore = true
    @State private var errorMessage: String?
    /// 本相册已加入封面生成队列的照片数（取消会删记录，所以剩下的都算）
    @State private var coverCount: Int?
    /// 看图器里点了封面按钮 → 回本页时刷新计数
    private let coverChanged = NotificationCenter.default.publisher(for: .coverTaskDidChange)

    // MARK: 图片 / 视频分区
    /// 照片是相册主体，默认落在图片；视频按方案B存在独立表，切过去才拉
    private enum MediaTab: String, CaseIterable, Identifiable {
        case photos = "图片"
        case videos = "视频"
        var id: String { rawValue }
        var icon: String { self == .photos ? "photo" : "film" }
    }
    @State private var mediaTab: MediaTab = .photos
    @State private var videos: [AlbumVideo] = []
    @State private var videoErrorMessage: String?
    /// 🔴 点击瞬间零网络构造请求、立刻弹全屏；ffprobe 探测 + 开 HLS 会话的等待
    ///    交给 PlayerHostView 在屏内显示（旧写法先 await resolvePlayback 再弹屏，点击像卡死）
    @State private var playRequest: PlaybackRequest?
    /// VidHub 外播：相册视频格式杂，内置播放器解不动的交给它
    @StateObject private var vidHub = VidHubLauncher()

    /// 顶栏分母（相册总张数）。相册接口没给 count 时退回已加载张数，
    /// 免得顶栏出现「120 / 0」这种明显不对的分母。
    private var totalCount: Int { album.count > 0 ? album.count : photos.count }

    private var client: APIClient? { AppSession.shared.client }

    var body: some View {
        VStack(spacing: 0) {
            switch mediaTab {
            case .photos: photosTab
            case .videos: videosTab
            }
        }
        // ⚠️ 只忽略底部：tab 胶囊仍留在导航栏下方的安全区里
        .ignoresSafeArea(edges: .bottom)
        .navigationBarTitleDisplayMode(.inline)
        // ⚠️ 相册名**不**用 navigationTitle：它是居中的，而且要跟系统返回按钮抢位。
        // 改放 leading 位 —— 紧跟返回按钮右边，跟相册列表页「库名在左、计数在右」同一套排版。
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                HStack(spacing: 4) {
                    if let onBack {
                        Button(action: onBack) {
                            HStack(spacing: 2) {
                                Image(systemName: "chevron.left")
                                    .font(.system(size: 15, weight: .semibold))
                                Text("返回")
                                    .font(.subheadline.weight(.semibold))
                            }
                            .foregroundStyle(Theme.brand)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    Text(album.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        // 与 ListSearchBarItem 里库名同一套保险：至少 120pt（≈8 个汉字），
                        // 空间再紧也不会被压没；layoutPriority 让相册名优先拿到宽度。
                        // ⚠️ alignment 必须 .leading：frame 默认居中，名字短时会离返回按钮老远。
                        .frame(minWidth: onBack == nil ? 120 : 90, alignment: .leading)
                        .layoutPriority(1)
                }
            }
            .withoutGlass()

            // 图片 / 视频 tab 放在系统顶栏正中（principal），不是内容区顶部那一条
            ToolbarItem(placement: .principal) {
                mediaTabBar
            }
            .withoutGlass()

            TrailingToolsItem {
                // AI 封面个数（可点：手动刷新一次，看图器里改过也能立刻对上）
                // 视频 tab 没有"生成封面"这件事，不显示
                if mediaTab == .photos, let n = coverCount {
                    ToolChip(label: "封面 \(n)", icon: "photo.on.rectangle",
                             // 有封面就绿 —— 与看图器里那个封面标记同一个颜色语义
                             tintColor: n > 0 ? .green : nil) {
                        Task { await loadCoverCount() }
                    }
                }
                // 图片 tab：已加载 / 总数；视频 tab：视频是一次性全量返回，直接报个数
                Text(mediaTab == .photos ? "\(photos.count) / \(totalCount)" : "\(videos.count) 个视频")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    // ⚠️ 不加 fixedSize：工具栏空间紧张时会被压缩换行，撑高导航栏
                    .fixedSize(horizontal: true, vertical: false)
                    .lineLimit(1)
                    .frame(minWidth: ToolbarMetrics.countMinWidth, alignment: .trailing)
                    .padding(.leading, ToolbarMetrics.countGap)
            }
        }
        .overlay {
            if mediaTab == .photos, photos.isEmpty {
                if let errorMessage {
                    ContentUnavailableView(errorMessage, systemImage: "exclamationmark.triangle")
                } else {
                    ProgressView("加载照片…")
                }
            } else if mediaTab == .videos, videos.isEmpty {
                if let videoErrorMessage {
                    ContentUnavailableView(videoErrorMessage, systemImage: "exclamationmark.triangle")
                } else {
                    ProgressView("加载视频…")
                }
            }
        }
        .task {
            await loadMore()
            await loadCoverCount()
            await loadVideos()
        }
        // 🔴 点击即弹：PlaybackRequest 零网络构造，PlayerHostView 自己跑探测并显示准备状态
        .fullScreenCover(item: $playRequest) { request in
            PlayerHostView(request: request)
        }
        .onDisappear { vidHub.cancel() }
        .alert("未安装 VidHub", isPresented: Binding(
            get: { vidHub.vidHubMissing },
            set: { if !$0 { vidHub.vidHubMissing = false } }
        )) {
            Button("去 App Store 找") {
                if let u = URL(string: "https://apps.apple.com/cn/search?term=vidhub") {
                    UIApplication.shared.open(u)
                }
            }
            Button("好", role: .cancel) {}
        } message: {
            Text("装好 VidHub 后，视频卡片右上角的按钮会把文件交给它播放（MKV / AVI / HEVC 等内置播放器放不了的格式都能解）。")
        }
        .alert("外播失败", isPresented: Binding(
            get: { vidHub.error != nil },
            set: { if !$0 { vidHub.error = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(vidHub.error ?? "")
        }
        // 看图器里加入/取消封面后回到本页，计数要跟着变
        .onReceive(coverChanged) { _ in
            Task { await loadCoverCount() }
        }
        // ⚠️ 每个 tab / 每个 push 进来的页面都要自己垫一层背景：
        // NavigationStack 只渲染栈顶那一层，App 根的背景透不进来。
        // 缺了它，退出看图器（fullScreenCover）时露出的是一片白底。
        .appBackground()    }

    @MainActor
    private func loadMore() async {
        guard let client = AppSession.shared.client, !isLoading, hasMore else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let batch = try await client.fetchAlbumPhotos(albumID: album.id, libID: libID, page: page)
            photos.append(contentsOf: batch)
            page += 1
            hasMore = !batch.isEmpty
        } catch {
            errorMessage = "加载照片失败 · \(((error as? LocalizedError)?.errorDescription) ?? error.localizedDescription)"
        }
    }

    /// 拉取本相册的封面任务数。失败时保持 nil（顶栏不显示这一项），
    /// 不显示一个错误的 0 —— 「0 张」和「没查到」是两回事。
    @MainActor
    private func loadCoverCount() async {
        guard let client = AppSession.shared.client else { return }
        do {
            coverCount = try await client.fetchCoverTaskCount(albumId: album.id).total
        } catch {
            coverCount = nil
        }
    }

    // MARK: - 图片 / 视频分区

    /// 顶栏正中的分段胶囊（placement: .principal）。样式对齐 PeopleHub / 历史拍摄集详情页：
    /// 品牌色淡底 + 图标 + 数量；不用系统 segmented（灰底板跟全站顶栏节奏不合）。
    /// 字重恒定，避免切换时中文字重变化让胶囊宽度跳动。
    /// ⚠️ 顶栏里不要再垫 material 背景/分隔线（导航栏自己有），否则成了"第二条顶栏"。
    private var mediaTabBar: some View {
        HStack(spacing: 8) {
            ForEach(MediaTab.allCases) { item in
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { mediaTab = item }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: item.icon)
                            .font(.system(size: 12, weight: .semibold))
                        Text(item.rawValue)
                        Text(tabCount(item))
                            .font(.caption2).monospacedDigit()
                            .foregroundStyle(mediaTab == item ? Theme.brand : Color.secondary)
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(mediaTab == item ? Theme.brand : Color.secondary)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(mediaTab == item ? Theme.brand.opacity(0.15) : Color.clear,
                                in: Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        // 顶栏空间紧张时不许压缩换行（换行会撑高导航栏）
        .fixedSize(horizontal: true, vertical: false)
    }

    private func tabCount(_ item: MediaTab) -> String {
        switch item {
        case .photos: return "\(totalCount)"
        case .videos: return "\(videos.count)"
        }
    }

    /// 照片 tab：网格原样保留，分页 / 看图器 / 封面计数一个都不动
    private var photosTab: some View {
        PhotoGrid(
            photos: photos,
            columns: columns,
            onColumnsChange: { columns = $0; PhotoGridPrefs.save("albumPhotos", $0) },
            onSelect: { photo in
                guard let i = photos.firstIndex(where: { $0.id == photo.id }) else { return }
                // 全局 overlay 呈现（见 PhotoViewerPresenter 注释）。
                // 网格翻页后要把新数组同步给看图器，否则翻不到新加载的图
                PhotoViewerPresenter.shared.show(photos, index: i, hasMore: hasMore, onLoadMore: {
                    Task {
                        await loadMore()
                        PhotoViewerPresenter.shared.updatePhotos(photos)
                    }
                })
            },
            onReachEnd: { Task { await loadMore() } }
        )
        // 根视图模式的 PhotoGrid 自己滚；在 VStack 里要明确吃满 tab 下方的剩余高度
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 视频 tab：后端一次性全量返回，横滑轨足够（与老拍摄集同量级）
    @ViewBuilder
    private var videosTab: some View {
        if !videos.isEmpty {
            VStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(videos) { video in
                            albumVideoCard(video)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func albumVideoCard(_ video: AlbumVideo) -> some View {
        // 卡宽约屏宽 60%：一屏露出一个半，暗示可以横滑
        let width: CGFloat = 232
        return VStack(alignment: .leading, spacing: 6) {
            // ⚠️ 播放与 VidHub 两个按钮必须并列在 ZStack 里，不能嵌套 Button：
            // 嵌套时点击一律被外层吞掉，VidHub 永远点不到（老拍摄集踩过）
            ZStack(alignment: .topTrailing) {
                Button {
                    startPlayback(video)
                } label: {
                    ZStack {
                        LinearGradient(colors: [Theme.brand.opacity(0.45), Theme.brand.opacity(0.08)],
                                       startPoint: .top, endPoint: .bottom)
                        Image(systemName: "play.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .frame(width: width, height: width * 9 / 16)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(alignment: .bottomTrailing) {
                        if let duration = video.durationText {
                            Text(duration)
                                .font(.caption2.weight(.medium)).monospacedDigit()
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(.black.opacity(0.55), in: Capsule())
                                .padding(6)
                        }
                    }
                }
                .buttonStyle(.plain)

                Button {
                    playInVidHub(video)
                } label: {
                    Label("VidHub", systemImage: "arrow.up.right")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.black.opacity(0.5), in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(6)
            }

            Text(video.title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.tail)
                .frame(width: width, alignment: .leading)
        }
    }

    @MainActor
    private func loadVideos() async {
        guard let client else { return }
        do {
            videos = try await client.fetchAlbumVideos(albumID: album.id)
            videoErrorMessage = nil
        } catch {
            videos = []
            videoErrorMessage = "加载视频失败 · \(((error as? LocalizedError)?.errorDescription) ?? error.localizedDescription)"
        }
    }

    /// 零网络构造请求，点击瞬间就弹全屏。真正的 ffprobe 探测 / HLS 会话由
    /// PlayerHostView 在全屏里跑，并显示「正在准备…」+ 取消 / 重试，
    /// 不再让列表页看起来卡死（旧写法先 await resolvePlayback 再弹屏）。
    private func startPlayback(_ video: AlbumVideo) {
        playRequest = PlaybackRequest(path: video.filePath,
                                      title: video.title,
                                      assetType: nil,
                                      assetID: nil,
                                      startAt: nil,
                                      knownDuration: video.duration)
    }

    /// VidHub 外播：带 ?token= 的直链，用它自己的解码器，格式杂时比内置快得多
    private func playInVidHub(_ video: AlbumVideo) {
        guard let url = client?.albumVideoExternalURL(video) else { return }
        vidHub.play(url: url, title: video.title)
    }
}

extension Notification.Name {
    /// 封面生成队列发生变化（看图器里加入/取消）
    static let coverTaskDidChange = Notification.Name("CoverTaskDidChange")
}
