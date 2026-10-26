import SwiftUI

// MARK: - 演员导航值
// ⚠️ 不用裸 Int 当 navigation value：library tab 的导航栈里会有别的 Int destination，
// 同类型撞车会互相顶掉。包一层结构体，类型即命名空间。
struct ActorRoute: Hashable {
    let id: Int
}

// MARK: - 演员库
// 对齐网页端 ActorsPage：演员网格（头像 + 姓名 + 作品数）+ 搜索。
// 入口：电影/剧集列表页工具栏「演员」chip；演员详情里也可继续跳关联演员。
struct ActorsView: View {
    @StateObject private var viewModel = ActorsViewModel()

    var body: some View {
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
        .navigationTitle("演员")
        .navigationBarTitleDisplayMode(.inline)
        .appBackground()
        .searchable(text: $viewModel.searchText, prompt: "搜索演员…")
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

    init() {
        // 还原上次的搜索词 / 排序 / 方向（没记过就用默认值）
        self.searchText = ListSearchPrefs.loadSearch(prefsPage)
        self.sort = ListSearchPrefs.loadSort(prefsPage, fallback: .count)
        self.descending = ListSearchPrefs.loadDescending(prefsPage, fallback: true)
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
