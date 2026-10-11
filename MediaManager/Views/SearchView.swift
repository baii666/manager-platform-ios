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

    static func clear() { UserDefaults.standard.removeItem(forKey: key) }
}

// MARK: - 搜索页
// 对齐网页端搜索：分类 Tab（全部/影视/相册/照片/拍摄集）+ 每类无限滚动 + 结果直达详情
struct SearchView: View {
    /// 看图器走哪条路。默认全局 overlay（PhotoViewerPresenter，退出丝滑）；
    /// ⚠️ 本页若在 **sheet** 里（首页的搜索按钮就是 sheet），全局 overlay 会被 sheet
    /// 盖住看不见 —— 此时传 false，退回本页自己的 fullScreenCover。
    var useGlobalViewer = false

    @State private var query = ""
    /// 真正拿去请求的词（防抖后写入），避免每敲一个字都打接口
    @State private var activeQuery = ""
    @State private var selectedTab: Tab = .all
    @State private var results: [SearchItem] = []
    @State private var totals: [String: Int] = [:]
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var page = 1
    @State private var hasMore = false
    @State private var history: [String] = SearchHistoryStore.load()
    @State private var debounceTask: Task<Void, Never>?

    // 导航目标
    @State private var movieTarget: MediaItem?
    @State private var albumTarget: Album?
    @State private var albumLibID: Int = 0
    @State private var shootTarget: Shoot?
    /// sheet 模式（useGlobalViewer = false）下的看图器目标
    @State private var localPhoto: Photo?

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

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 16)]

    var body: some View {
        VStack(spacing: 0) {
            searchField
            if !totals.isEmpty || selectedTab != .all { categoryBar }
            Divider()
            content
        }
        .navigationTitle("搜索")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: query) { scheduleSearch() }
        .onSubmit(of: .text) { runSearch(query) }
        // ⚠️ 每个 tab / 每个 push 进来的页面都要自己垫一层背景：
        // NavigationStack 只渲染栈顶那一层，App 根的背景透不进来
        .appBackground()
        .navigationDestination(item: $movieTarget) { MediaDetailView(media: $0) }
        .navigationDestination(item: $albumTarget) { AlbumPhotosView(album: $0, libID: albumLibID) }
        .navigationDestination(item: $shootTarget) { ShootDetailView(shoot: $0) }
        .fullScreenCover(item: $localPhoto) { photo in
            PhotoViewerView(photos: [photo], index: 0, onClose: { localPhoto = nil })
        }
    }

    // MARK: 搜索框

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索影视 / 相册 / 照片 / 拍摄集", text: $query)
                .textFieldStyle(.plain)
                .submitLabel(.search)
                .autocorrectionDisabled()
            if isLoading {
                ProgressView().controlSize(.small)
            }
            if !query.isEmpty {
                Button {
                    query = ""
                    activeQuery = ""
                    results = []
                    totals = [:]
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .appSurface(in: Capsule())
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    // MARK: 分类 Tab

    private var categoryBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Tab.allCases, id: \.self) { tab in
                    let count = tab.totalKeys.reduce(0) { $0 + (totals[$1] ?? 0) }
                    Button {
                        selectedTab = tab
                        Task { await reload() }
                    } label: {
                        HStack(spacing: 5) {
                            Text(tab.label)
                            if count > 0 {
                                Text("\(count)").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .font(.subheadline.weight(selectedTab == tab ? .semibold : .regular))
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(selectedTab == tab ? Theme.brand.opacity(0.15) : .clear,
                                    in: Capsule())
                        .foregroundStyle(selectedTab == tab ? Theme.brand : .primary)
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 6)
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
            ContentUnavailableView("没有匹配结果", systemImage: "tray")
                .frame(maxWidth: .infinity, minHeight: 300)
        } else if selectedTab == .all {
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
                                Task { await reload() }
                            } label: {
                                Text("查看全部").font(.caption)
                            }
                        }
                        .padding(.horizontal, 16)

                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 12) {
                                ForEach(section.items) { item in
                                    SearchCard(item: item, client: client) { route(item) }
                                        .frame(width: 150)
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                    }
                }
            }
            .padding(.vertical, 16)
        }
    }

    /// 单类型：竖向网格 + 触底加载更多
    private var flatResults: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(results) { item in
                    SearchCard(item: item, client: client) { route(item) }
                        .task {
                            if item.id == results.last?.id { await loadMore() }
                        }
                }
            }
            .padding(16)
            if isLoading {
                ProgressView().frame(maxWidth: .infinity).padding()
            }
        }
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

    /// 输入防抖：350ms 内连续输入只发一次请求
    @MainActor
    private func scheduleSearch() {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            runSearch(query)
        }
    }

    @MainActor
    private func runSearch(_ text: String) {
        debounceTask?.cancel()
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        activeQuery = q
        selectedTab = .all
        guard !q.isEmpty else {
            results = []; totals = [:]; return
        }
        SearchHistoryStore.add(q)
        history = SearchHistoryStore.load()
        Task { await reload() }
    }

    @MainActor
    private func reload() async {
        guard let client, !activeQuery.isEmpty else {
            results = []; totals = [:]; return
        }
        errorMessage = nil
        page = 1; hasMore = true; results = []
        // 分类计数（/totals 有 5s 服务端缓存，切 Tab 不会重复打爆）
        do { totals = try await client.searchTotals(query: activeQuery) } catch { totals = [:] }
        await loadMore()
    }

    private let pageSize = 30

    @MainActor
    private func loadMore() async {
        guard let client, !isLoading, hasMore else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            // 「全部」只取每类一批做总览，翻页交给各分类页
            let size = selectedTab == .all ? 8 : pageSize
            let p = try await client.searchGrouped(
                query: activeQuery, types: selectedTab.requestTypes, page: page, size: size)
            if page == 1 { results = p.items } else { results.append(contentsOf: p.items) }
            page += 1
            hasMore = selectedTab == .all ? false : p.hasMore
        } catch {
            errorMessage = "搜索失败 · \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
        }
    }

    // MARK: 路由

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
        switch item.type {
        case "movie", "series", "tv":
            var m = MediaItem(id: item.id)
            m.title = item.titleText
            m.year = item.year
            m.type = item.type == "tv" ? "tv" : "movie"
            m.posterImageId = item.posterImageId
            m.libraryId = item.libraryId
            movieTarget = m
        case "album":
            var a = Album(id: item.id)
            a.folderName = item.folderName ?? item.titleText
            a.displayName = item.displayName
            a.count = item.photoCount ?? 0
            a.coverPhotoId = item.coverPhotoId
            a.coverPhotoIdPortrait = item.coverPhotoIdPortrait
            albumLibID = item.libraryId ?? 0
            albumTarget = a
        case "photo":
            // 搜索结果里的照片整批交给看图器，可以左右翻，而不是只能看孤立的一张
            let photos = results.filter { $0.type == "photo" }.map { makePhoto($0) }
            let index = photos.firstIndex { $0.id == item.id } ?? 0
            if useGlobalViewer {
                PhotoViewerPresenter.shared.show(photos, index: index)
            } else {
                localPhoto = photos[safe: index] ?? makePhoto(item)
            }
        case "shoot":
            var s = Shoot(id: item.id)
            s.displayName = item.titleText
            s.folderName = item.folderName ?? item.titleText
            s.libraryId = item.libraryId ?? 0
            shootTarget = s
        default:
            break
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - 搜索结果卡
private struct SearchCard: View {
    let item: SearchItem
    let client: APIClient?
    var onTap: () -> Void

    private var cover: URL? {
        switch item.type {
        case "movie", "series", "tv":
            // .map 已返回可选，别再 ?? nil（no-op，会招警告）
            return item.posterImageId.flatMap {
                client?.makeURL("/media-image", queryItems: [
                    URLQueryItem(name: "id", value: "\($0)"),
                    URLQueryItem(name: "size", value: "600"),
                ])
            }
        case "album":
            // 竖版封面优先（相册卡片是 2:3），没有再退回横版
            let aid = item.coverPhotoIdPortrait ?? item.coverPhotoId ?? item.id
            return client?.makeURL("/photo", queryItems: [
                URLQueryItem(name: "id", value: "\(aid)"),
                URLQueryItem(name: "size", value: "600"),
            ])
        case "photo":
            return client?.makeURL("/photo", queryItems: [
                URLQueryItem(name: "id", value: "\(item.id)"),
                URLQueryItem(name: "size", value: "600"),
            ])
        default:
            return nil
        }
    }

    private var subtitle: String {
        switch item.type {
        case "movie", "series", "tv":
            return item.year.map { "\($0)" } ?? (item.libraryName ?? "")
        case "album":
            return item.photoCount.map { "\($0) 张" } ?? (item.libraryName ?? "")
        case "photo":
            return item.libraryName ?? "照片"
        case "shoot":
            return item.libraryName ?? "拍摄集"
        default:
            return item.libraryName ?? ""
        }
    }

    private var fallbackColors: [Color] {
        switch item.type {
        case "photo": return Theme.placeholderGradient(for: .photo)
        case "shoot": return Theme.placeholderGradient(for: .shoot)
        case "short": return Theme.placeholderGradient(for: .short)
        default: return Theme.placeholderGradient(for: .media)
        }
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 0) {
                let isPortrait = item.type == "album" || item.type == "movie" || item.type == "series" || item.type == "tv"
                RemoteImage(url: cover, fallbackIcon: fallbackIcon, fallbackColors: fallbackColors)
                    // 搜索结果混合了海报/抽帧封面/照片缩略图，尺寸各不相同，
                    // 必须按容器尺寸渲染，否则会按原图像素撑开、压住相邻卡片
                    .imageFilled()
                    .frame(height: isPortrait ? 200 : 150)
                    .frame(maxWidth: .infinity)
                    .clipped()
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.titleText)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1).truncationMode(.tail)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                }
                .padding(10)
            }
            .appSurface(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.separator))
        }
        .buttonStyle(.plain)
    }

    private var fallbackIcon: String {
        switch item.type {
        case "photo": return "photo"
        case "shoot": return "photo.on.rectangle.angled"
        case "short": return "play.rectangle.fill"
        default: return "film"
        }
    }
}
