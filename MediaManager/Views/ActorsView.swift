import SwiftUI

// MARK: - 演员导航值
// ⚠️ 不用裸 Int 当 navigation value：library tab 的导航栈里会有别的 Int destination，
// 同类型撞车会互相顶掉。包一层结构体，类型即命名空间。
struct ActorRoute: Hashable {
    let id: Int
}

/// 「按名字搜演员」路由。影视详情里的演员卡片如果后端没给数字 id（走
/// `media.actors` JSON fallback 的老数据），就没法拼 /api/actors/:id，
/// 卡片以前只能画成不可点的静态图 —— 表现为「点了没反应」。
/// 退一步跳进演员库、把名字预填进搜索框，用户照样能找到本人；
/// 用独立类型避免和 ActorRoute 的 Int destination 撞车。
struct ActorSearchRoute: Hashable {
    let name: String
}

// MARK: - 演员库
// 对齐网页端 ActorsPage：演员网格（头像 + 姓名 + 作品数）+ 搜索。
// 入口：电影/剧集列表页工具栏「演员」chip；演员详情里也可继续跳关联演员。
struct ActorsView: View {
    /// 嵌进「人物」聚合页（PeopleHubView）时由外层统一提供标题与背景。
    /// 独立从电影列表「演员」chip 进来时仍是完整的演员页。
    var embedded: Bool = false
    /// 搜索与排序改到内容区（见 init 注释），导航栏被收掉时用
    var inlineControls: Bool = false
    @StateObject private var viewModel: ActorsViewModel

    /// `initialSearch`：从影视详情的无 id 演员卡片进来时预填的搜索词。
    /// ⚠️ @StateObject 只能在第一次创建时带初值，所以放到自定义 init 里传，
    ///    不能等 onAppear 再改 viewModel.searchText（人物页里的 VM 是常驻的）。
    ///
    /// `inlineControls`：宿主把导航栏收掉时（人物 tab 的顶栏只放分段）为 true。
    /// `.searchable` 和排序胶囊都挂在导航栏上，栏一收就一起看不见了 ——
    /// 这时改在内容区顶部自己画一行「搜索 + 排序」，功能不丢。
    init(embedded: Bool = false, initialSearch: String? = nil, inlineControls: Bool = false) {
        self.embedded = embedded
        self.inlineControls = inlineControls
        _viewModel = StateObject(wrappedValue: ActorsViewModel(initialSearch: initialSearch))
    }

    var body: some View {
        Group {
            if inlineControls {
                content
            } else {
                content.searchable(text: $viewModel.searchText, prompt: "搜索演员…")
            }
        }
        .navigationTitle(embedded ? "" : "演员")
        .navigationBarTitleDisplayMode(.inline)
        // 嵌进「人物」聚合页时由外层统一铺背景，避免背景图模式下压暗两次
        .background { if !embedded { AppBackgroundView() } }
        .refreshing { await viewModel.reload() }
        .toolbar {
            // 排序字段（与电影/相册/拍摄集/短视频列表同一套 ToolMenuChip 胶囊样式）
            ToolbarItem(placement: .topBarTrailing) {
                ToolMenuChip(label: viewModel.sort.label) {
                    ForEach(ActorsViewModel.Sort.allCases, id: \.self) { s in
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
        }
        // 搜索防抖 350ms（与三个列表页同一套）
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
                    viewModel.errorMessage ?? "暂无演员",
                    systemImage: viewModel.errorMessage == nil ? "person.2.fill" : "exclamationmark.triangle"
                )
            }
        }
        .task { await viewModel.loadInitial() }
        .navigationDestination(for: ActorRoute.self) { route in
            ActorDetailView(actorId: route.id)
        }
    }

    // MARK: 网格（+ 可选的内容区控制行）
    private var content: some View {
        VStack(spacing: 0) {
            if inlineControls { inlineControlBar }

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 14)], spacing: 14) {
                    ForEach(viewModel.items) { actor in
                        NavigationLink(value: ActorRoute(id: actor.id)) {
                            ActorCard(actor: actor)
                        }
                        .buttonStyle(.plain)
                        .task {
                            if actor.id == viewModel.items.last?.id { await viewModel.loadMore() }
                        }
                    }
                }
                .padding(16)
                .bottomBarClearance()
                if viewModel.isLoading {
                    ProgressView().frame(maxWidth: .infinity).padding()
                }
            }
        }
    }

    /// 导航栏被收掉时的等价物：搜索框在左、排序 + 升降序胶囊在右。
    /// 胶囊本身沿用导航栏里的「不画底」样式；只有搜索框补一层淡底 ——
    /// 那原本是系统搜索框的样子，搬进内容区得自己给个边界。
    private var inlineControlBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                TextField("搜索演员…", text: $viewModel.searchText)
                    .textFieldStyle(.plain)
                    .font(.subheadline)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                if !viewModel.searchText.isEmpty {
                    Button {
                        viewModel.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(Capsule().fill(Color.primary.opacity(0.06)))

            ToolMenuChip(label: viewModel.sort.label) {
                ForEach(ActorsViewModel.Sort.allCases, id: \.self) { s in
                    Button {
                        Task { await viewModel.setSort(s) }
                    } label: {
                        if viewModel.sort == s { Label(s.label, systemImage: "checkmark") }
                        else { Text(s.label) }
                    }
                }
            }
            ToolChip(label: "降序", icon: viewModel.descending ? "arrow.down" : "arrow.up",
                     highlighted: viewModel.descending, iconOnly: true) {
                Task { await viewModel.toggleDirection() }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
}

// MARK: - 演员卡
private struct ActorCard: View {
    let actor: ActorItem

    var body: some View {
        VStack(spacing: 8) {
            RemoteImage(url: actor.thumbURL, fallbackIcon: "person.fill",
                        fallbackColors: [Color.gray.opacity(0.3), Color.gray.opacity(0.1)])
                .imageFilled()
                .frame(width: 84, height: 84)
                .clipShape(Circle())
            Text(actor.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            Text(actor.movieCount + actor.seriesCount > 0
                 ? "电影 \(actor.movieCount) · 剧集 \(actor.seriesCount)"
                 : "暂无作品")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .appSurface(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - 演员详情页
// 对齐网页端 ActorsPage 详情态：头像 + 姓名/别名 + 简介（可展开）+ 关联演员 +
// 电影/剧集作品网格（点作品进影视详情，与列表页同一张 MediaCard）。
struct ActorDetailView: View {
    let actorId: Int
    @StateObject private var viewModel: ActorDetailViewModel
    @State private var overviewExpanded = false

    init(actorId: Int) {
        self.actorId = actorId
        _viewModel = StateObject(wrappedValue: ActorDetailViewModel(actorId: actorId))
    }

    var body: some View {
        ScrollView {
            if let profile = viewModel.profile {
                VStack(alignment: .leading, spacing: 20) {
                    header(profile)
                    if let bio = profile.biography, !bio.isEmpty { bioSection(bio) }
                    if !profile.linkedActors.isEmpty { linkedSection(profile.linkedActors) }
                    worksSection(title: "电影", works: viewModel.movies, type: "movie")
                    worksSection(title: "剧集", works: viewModel.series, type: "tv")
                }
                .padding(16)
                .bottomBarClearance()
            } else if viewModel.isLoading {
                ProgressView("加载中…").frame(maxWidth: .infinity).padding(.top, 60)
            } else {
                ContentUnavailableView(viewModel.errorMessage ?? "加载失败",
                                      systemImage: "exclamationmark.triangle")
                    .frame(maxWidth: .infinity, minHeight: 400)
            }
        }
        .navigationTitle(viewModel.profile?.title ?? "演员")
        .navigationBarTitleDisplayMode(.inline)
        .appBackground()
        .task { await viewModel.load() }
        // 关联演员 / 作品都走 ActorRoute / MediaItem 两种 value 继续 push
        .navigationDestination(for: ActorRoute.self) { route in
            ActorDetailView(actorId: route.id)
        }
        .navigationDestination(for: MediaItem.self) { item in
            MediaDetailView(media: item)
        }
    }

    // MARK: 头部

    private func header(_ profile: ActorProfile) -> some View {
        HStack(alignment: .top, spacing: 16) {
            RemoteImage(url: profile.thumbURL, fallbackIcon: "person.fill",
                        fallbackColors: [Color.gray.opacity(0.3), Color.gray.opacity(0.1)])
                .imageFilled()
                .frame(width: 96, height: 96)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 5) {
                Text(profile.title)
                    .font(.title2.weight(.semibold))
                // 展示名与原始名不同时才补一行（display_name 是后台人工名）
                if !profile.name.isEmpty, profile.name != profile.title {
                    Text(profile.name)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if let birthday = profile.birthday, !birthday.isEmpty {
                    Text(birthday)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("电影 \(viewModel.movies.count) · 剧集 \(viewModel.series.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !profile.aliases.isEmpty {
                    Text("别名：\(profile.aliases.joined(separator: "、"))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: 简介

    private func bioSection(_ bio: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("简介").font(.headline)
            Text(bio)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(overviewExpanded ? nil : 4)
                .fixedSize(horizontal: false, vertical: true)
            if bio.count > 80 {
                Button(overviewExpanded ? "收起" : "展开全部") {
                    overviewExpanded.toggle()
                }
                .font(.footnote.weight(.medium))
                .foregroundStyle(Theme.brand)
            }
        }
    }

    // MARK: 关联演员

    private func linkedSection(_ linked: [ActorItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("关联演员").font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(linked) { actor in
                        NavigationLink(value: ActorRoute(id: actor.id)) {
                            VStack(spacing: 6) {
                                RemoteImage(url: actor.thumbURL, fallbackIcon: "person.fill",
                                            fallbackColors: [Color.gray.opacity(0.3), Color.gray.opacity(0.1)])
                                    .imageFilled()
                                    .frame(width: 56, height: 56)
                                    .clipShape(Circle())
                                Text(actor.title)
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
    }

    // MARK: 作品

    /// 三列网格，卡片宽度按屏宽估算（列数固定，不需要 MediaListView 那套捏合缩放）
    private func worksSection(title: String, works: [ActorWork], type: String) -> some View {
        guard !works.isEmpty else { return AnyView(EmptyView()) }
        let spacing: CGFloat = 14
        let columns = Array(repeating: GridItem(.flexible(), spacing: spacing), count: 3)
        let width = (UIScreen.main.bounds.width - 32 - spacing * 2) / 3
        return AnyView(
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.headline)
                LazyVGrid(columns: columns, spacing: spacing) {
                    ForEach(works) { work in
                        // 作品 → MediaItem，复用列表页同一张 MediaCard + 同一个影视详情页
                        let item = MediaItem(id: work.id, title: work.title, year: work.year,
                                             type: type, libraryId: work.libraryId, rating: work.rating)
                        NavigationLink(value: item) {
                            MediaCard(item: item, coverURL: work.posterURL, width: width)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        )
    }
}

// MARK: - 演员库 VM
final class ActorsViewModel: ObservableObject {
    /// 排序字段。方向单独一档（descending）—— 后端 /api/actors 是
    /// `sort=<字段>&order=asc|desc` 两个参数，别硬拼成一对枚举。
    enum Sort: String, CaseIterable, Sendable {
        case count, name
        var label: String {
            switch self { case .count: return "作品数"; case .name: return "姓名" }
        }
    }

    @Published var items: [ActorItem] = []
    @Published var totalCount = 0
    @Published var searchText = "" {
        didSet { ListSearchPrefs.saveSearch(prefsPage, searchText) }
    }
    @Published var sort: Sort {
        didSet { ListSearchPrefs.saveSort(prefsPage, raw: sort.rawValue) }
    }
    /// 升/降序。true = 降序（默认）：作品多的在前 / 姓名 Z→A
    @Published var descending: Bool {
        didSet { ListSearchPrefs.saveDescending(prefsPage, descending) }
    }
    @Published var isLoading = false
    @Published var errorMessage: String?

    /// 记忆键按「页」分
    private let prefsPage = "actors"

    private var page = 1
    private let pageSize = 60
    private var hasMore = true

    private var client: APIClient? { AppSession.shared.client }

    init(initialSearch: String? = nil) {
        // 还原上次的排序 / 方向（没记过就用默认值）
        self.sort = ListSearchPrefs.loadSort(prefsPage, fallback: .count)
        self.descending = ListSearchPrefs.loadDescending(prefsPage, fallback: true)
        if let q = initialSearch, !q.isEmpty {
            // 初始化期间给 @Published 赋值不会触发 didSet，所以显式持久化一次，
            // 让下次独立打开演员库也保留这次的搜索词
            self.searchText = q
            ListSearchPrefs.saveSearch(prefsPage, q)
        } else {
            self.searchText = ListSearchPrefs.loadSearch(prefsPage)
        }
    }

    @MainActor
    func loadInitial() async {
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

    @MainActor
    func loadMore() async {
        guard let client, !isLoading, hasMore else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let (batch, total, more) = try await client.fetchActors(
                page: page, size: pageSize, sort: sort.rawValue, descending: descending,
                q: searchText.isEmpty ? nil : searchText)
            totalCount = total
            items.append(contentsOf: batch)
            page += 1
            hasMore = more
        } catch {
            errorMessage = "加载失败 · \(describe(error))"
        }
    }

    private func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

// MARK: - 演员详情 VM
final class ActorDetailViewModel: ObservableObject {
    let actorId: Int
    @Published var profile: ActorProfile?
    @Published var movies: [ActorWork] = []
    @Published var series: [ActorWork] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private var client: APIClient? { AppSession.shared.client }

    init(actorId: Int) {
        self.actorId = actorId
    }

    @MainActor
    func load() async {
        // 从关联演员跳过来时会新建 VM；已加载过就跳过，避免重复请求
        guard !isLoading, profile == nil else { return }
        guard let client else {
            errorMessage = "未连接服务器"
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let (profile, movies, series) = try await client.fetchActorDetail(id: actorId)
            self.profile = profile
            self.movies = movies
            self.series = series
        } catch {
            errorMessage = "加载失败 · \(describe(error))"
        }
    }

    private func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
