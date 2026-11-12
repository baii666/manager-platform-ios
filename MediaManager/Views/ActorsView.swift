import SwiftUI
import UIKit

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

/// 「打开整个演员库」路由（影视列表工具栏的「演员」chip）。
/// ⚠️ 列表页原来用 `navigationDestination(isPresented: $showActors)` 推演员库，
/// 那是绑定型、不写 NavigationPath；同栈里后面任何 value 型 append（例如详情页
/// 点演员推 ActorRoute）都会让系统重算栈，把绑定层重新压回栈顶 →
/// 「跳到演员又跳回电影详情」。统一改成 path 驱动的价值类型。
struct ActorLibraryRoute: Hashable {}

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
        // 🔴 embedded（人物 tab 的 TabView(.page) 分页）时不能自己注册：
        // page 内部的 destination 不会进外层 NavigationStack，点头像会完全没反应。
        // 那种情况由 PeopleHubView 在分页外层统一注册 ActorRoute。
        // 独立进来（电影列表 / 影视详情）时仍由本页自己注册。
        .navigationDestinationIf(!embedded, for: ActorRoute.self) { route in
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
        VStack(spacing: 0) {
            // 图区：2:3 竖版（对齐网页版 ActorsPage 卡片），clear 撑比例、图填满
            Color.clear
                .aspectRatio(2 / 3, contentMode: .fit)
                .overlay {
                    RemoteImage(url: actor.thumbURL, fallbackIcon: "person.fill",
                                fallbackColors: [Color.gray.opacity(0.3), Color.gray.opacity(0.1)])
                        .imageFilled(alignment: .top)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(actor.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(actor.movieCount + actor.seriesCount > 0
                     ? "电影 \(actor.movieCount) · 剧集 \(actor.seriesCount)"
                     : "暂无作品")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .appSurface(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        // 边界只是一条细线，不是厚边框
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
        }
    }
}

// MARK: - 演员详情页
// 主要设备是 13 寸 iPad（横屏 1024pt 满宽、无侧边栏），按 horizontalSizeClass 分两套：
//  · regular（iPad）：左 280pt 常驻资料栏 + 右作品网格，两栏各自独立滚动。
//    单条全宽 ScrollView 在 1024pt 上正文行长近 1000pt，头像 96pt 也小得不成比例。
//  · compact（iPhone）：保留原来的纵向单栏结构。
// 🔴 作品网格一律用容器宽算列数：原来写死 3 列且用 UIScreen.main.bounds.width 算卡片宽，
//    iPad 上每列约 330pt、海报被拉到近 500pt 高，分屏 / Split View 下宽度还会算错。
// biography 是「【姓名】…\n【生日】…」结构化脏串（含 HTML 链接），解析成属性表；
// 纯文本简介（日文维基那种）没有【】时回退到可展开原文，不丢信息。
// /api/actors/:id 的 movies 一次返回几百条不分页，年份 / 评分筛选与排序全在本地做。
struct ActorDetailView: View {
    let actorId: Int
    @StateObject private var viewModel: ActorDetailViewModel
    @State private var overviewExpanded = false
    /// 左栏资料默认收起，点「资料」才展开；与人物详情页一致
    @State private var profileExpanded = false
    @State private var yearFilter: Int? = nil
    @State private var minRating: Double = 0
    @State private var workSort: ActorWorkSort = .yearDesc

    @Environment(\.horizontalSizeClass) private var hSizeClass

    private var isWide: Bool { hSizeClass == .regular }
    private var sidebarWidth: CGFloat { 280 }
    private var panePadding: CGFloat { isWide ? 20 : 16 }

    init(actorId: Int) {
        self.actorId = actorId
        _viewModel = StateObject(wrappedValue: ActorDetailViewModel(actorId: actorId))
    }

    var body: some View {
        Group {
            if let profile = viewModel.profile {
                if isWide {
                    wideContent(profile)
                } else {
                    narrowContent(profile)
                }
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
        // 顶 bar 保持实心：左右两栏的内容都不能滚到导航栏底下透出来
        .toolbarBackground(.visible, for: .navigationBar)
        .appBackground()
        .task { await viewModel.load() }
        // ⚠️ destination 挂 body 根（Group）上，不能放进条件分支 / ScrollView 内部：
        //    那一层会随加载状态与滚动重建，点击瞬间可能丢掉注册 → 「点了没反应」。
        //    关联演员 / 作品都走 ActorRoute / MediaItem 两种 value 继续 push。
        .navigationDestination(for: ActorRoute.self) { route in
            ActorDetailView(actorId: route.id)
        }
        .navigationDestination(for: MediaItem.self) { item in
            MediaDetailView(media: item)
        }
    }

    // MARK: iPad 双栏

    private func wideContent(_ profile: ActorProfile) -> some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                ScrollView {
                    profileColumn(profile)
                        .padding(panePadding)
                        .bottomBarClearance()
                }
                .frame(width: sidebarWidth)
                .background(Color.primary.opacity(0.04))
                // 资料栏只在顶 bar 之下滚动，不越到导航栏区域
                .clipped()

                Rectangle()
                    .fill(Color(uiColor: .separator).opacity(0.6))
                    .frame(width: 0.5)

                // 工具行由 worksPane 的 safeAreaInset 自己顶到导航栏正下方
                worksPane(containerWidth: geo.size.width - sidebarWidth - 0.5)
                    .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    /// 右栏顶端常驻工具行（两页同款：一行放完筛选排序，右侧 已加载/总数）
    private var pinnedFilterBar: some View {
        filterBar
            .padding(.horizontal, panePadding)
            .padding(.vertical, 10)
            .background(.regularMaterial)
            .overlay(alignment: .bottom) { Divider().opacity(0.6) }
    }

    /// 左侧常驻资料栏：头像放大到 160pt，资料 / 简介 / 关联演员竖向排布。
    /// 长尾演员 92% 没有头像，用姓名首字母占位，避免宽屏资料栏空一大块。
    private func profileColumn(_ profile: ActorProfile) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            avatar(profile, size: 160)
                .frame(maxWidth: .infinity, alignment: .center)

            VStack(alignment: .leading, spacing: 6) {
                Text(profile.title)
                    .font(.title.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if !profile.name.isEmpty, profile.name != profile.title {
                    Text(profile.name)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if let birthday = profile.birthday, !birthday.isEmpty {
                    Label(birthday, systemImage: "calendar")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("电影 \(viewModel.movies.count) 部")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            profileToggle
            // 资料需要时点开，默认收起；与人物详情页的「资料」按钮同款
            if profileExpanded {
                if !profile.aliases.isEmpty { aliasesBlock(profile.aliases) }
                if let bio = profile.biography, !bio.isEmpty { bioBlock(bio) }
                if !profile.linkedActors.isEmpty { linkedGrid(profile.linkedActors) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var profileToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) { profileExpanded.toggle() }
        } label: {
            HStack(spacing: 3) {
                Text(profileExpanded ? "收起资料" : "资料")
                    .font(.caption.weight(.medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(profileExpanded ? 180 : 0))
            }
            .foregroundStyle(.secondary)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 右侧作品区：顶部筛选条 + 自适应网格。容器宽由外层 GeometryReader 量得。
    /// 右侧作品区：工具行用 safeAreaInset 顶在导航栏正下方（与左栏顶部对齐），
    /// 网格内容自动避开；容器宽由外层 GeometryReader 量得。
    private func worksPane(containerWidth: CGFloat) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                worksGrid(works: filteredWorks, type: "movie", containerWidth: containerWidth)
                // series 目前恒为空（media 表没有 tv 类型），有数据时才追加，不留空标题
                if !viewModel.series.isEmpty {
                    Text("剧集").font(.title3.weight(.semibold))
                    worksGrid(works: viewModel.series, type: "tv", containerWidth: containerWidth)
                }
            }
            .padding(panePadding)
            .bottomBarClearance()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .top, spacing: 0) { pinnedFilterBar }
    }

    // MARK: iPhone 单栏

    private func narrowContent(_ profile: ActorProfile) -> some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header(profile)
                    profileToggle
                    if profileExpanded {
                        if let bio = profile.biography, !bio.isEmpty { bioBlock(bio) }
                        if !profile.linkedActors.isEmpty { linkedStrip(profile.linkedActors) }
                    }
                    worksGrid(works: filteredWorks, type: "movie", containerWidth: geo.size.width)
                    if !viewModel.series.isEmpty {
                        Text("剧集").font(.headline)
                        worksGrid(works: viewModel.series, type: "tv", containerWidth: geo.size.width)
                    }
                }
                .padding(panePadding)
                .bottomBarClearance()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // iPhone 同款：工具行顶在导航栏正下方，不随内容滚走
            .safeAreaInset(edge: .top, spacing: 0) { pinnedFilterBar }
        }
    }

    private func header(_ profile: ActorProfile) -> some View {
        HStack(alignment: .top, spacing: 16) {
            avatar(profile, size: 96)
            VStack(alignment: .leading, spacing: 5) {
                Text(profile.title)
                    .font(.title2.weight(.semibold))
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
                Text("电影 \(viewModel.movies.count) 部")
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

    // MARK: 共用组件

    @ViewBuilder
    private func avatar(_ profile: ActorProfile, size: CGFloat) -> some View {
        if let url = profile.thumbURL {
            RemoteImage(url: url, fallbackIcon: "person.fill",
                        fallbackColors: [Color.gray.opacity(0.3), Color.gray.opacity(0.1)])
                .imageFilled(alignment: .top)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.09, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: size * 0.09, style: .continuous)
                .fill(Theme.brand.opacity(0.16))
                .frame(width: size, height: size)
                .overlay {
                    Text(String(profile.title.prefix(1)).uppercased())
                        .font(.system(size: size * 0.38, weight: .medium))
                        .foregroundStyle(Theme.brand)
                }
        }
    }

    private func aliasesBlock(_ aliases: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("别名")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(aliases.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 结构化简介 → 属性表；无【】的纯文本 → 4 行可展开原文。
    /// 属性表下再给一个「查看原始简介」，保证脏串里的信息一条不丢。
    private func bioBlock(_ raw: String) -> some View {
        let fields = parseBioFields(raw)
        return VStack(alignment: .leading, spacing: 10) {
            Text(fields.isEmpty ? "简介" : "资料")
                .font(isWide ? .title3 : .headline)
            if fields.isEmpty {
                Text(raw)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(overviewExpanded ? nil : 4)
                    .fixedSize(horizontal: false, vertical: true)
                if raw.count > 80 {
                    Button(overviewExpanded ? "收起" : "展开全部") {
                        overviewExpanded.toggle()
                    }
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Theme.brand)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(fields) { field in
                        HStack(alignment: .top, spacing: 8) {
                            Text(field.key)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 48, alignment: .leading)
                            Text(field.value)
                                .font(.caption)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Button(overviewExpanded ? "收起原文" : "查看原始简介") {
                    overviewExpanded.toggle()
                }
                .font(.footnote.weight(.medium))
                .foregroundStyle(Theme.brand)
                if overviewExpanded {
                    Text(raw)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// 每行形如「【生日】1989-07-09 (36岁)」。链接类字段（官网/博客/Twitter）
    /// 剥完标签只剩一串 URL，占地方又没法点，直接跳过；其余去 HTML 标签、把 | 换成中点。
    private func parseBioFields(_ raw: String) -> [BioField] {
        let linkKeys: Set<String> = ["官网", "博客", "Twitter", "微博", "Instagram"]
        var fields: [BioField] = []
        for line in raw.split(whereSeparator: { $0.isNewline }) {
            let s = String(line)
            guard s.hasPrefix("【"), let close = s.firstIndex(of: "】") else { continue }
            let key = String(s[s.index(after: s.startIndex)..<close])
            guard !linkKeys.contains(key) else { continue }
            var value = String(s[s.index(after: close)...])
                .replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "|", with: " · ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, !value.hasPrefix("http") else { continue }
            if value.count > 120 { value = String(value.prefix(120)) + "…" }
            fields.append(BioField(key: key, value: value))
        }
        return fields
    }

    private struct BioField: Identifiable {
        let key: String
        let value: String
        var id: String { key + value }
    }

    private func linkedGrid(_ linked: [ActorItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("关联演员").font(.title3.weight(.semibold))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 10)], spacing: 12) {
                ForEach(linked) { actor in
                    NavigationLink(value: ActorRoute(id: actor.id)) {
                        VStack(spacing: 5) {
                            RemoteImage(url: actor.thumbURL, fallbackIcon: "person.fill",
                                        fallbackColors: [Color.gray.opacity(0.3), Color.gray.opacity(0.1)])
                                .imageFilled(alignment: .top)
                                .frame(width: 44, height: 44)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            Text(actor.title)
                                .font(.caption2)
                                .lineLimit(1)
                                .frame(width: 68)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func linkedStrip(_ linked: [ActorItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("关联演员").font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(linked) { actor in
                        NavigationLink(value: ActorRoute(id: actor.id)) {
                            VStack(spacing: 6) {
                                RemoteImage(url: actor.thumbURL, fallbackIcon: "person.fill",
                                            fallbackColors: [Color.gray.opacity(0.3), Color.gray.opacity(0.1)])
                                    .imageFilled(alignment: .top)
                                    .frame(width: 56, height: 56)
                                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
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

    // MARK: 筛选 / 排序（本地，movies 一次返回不分页）

    private var availableYears: [Int] {
        Array(Set(viewModel.movies.compactMap { $0.year })).sorted(by: >)
    }

    private var filteredWorks: [ActorWork] {
        var list = viewModel.movies
        if let y = yearFilter { list = list.filter { $0.year == y } }
        if minRating > 0 { list = list.filter { ($0.rating ?? 0) >= minRating } }
        switch workSort {
        case .yearDesc: list.sort { ($0.year ?? 0) > ($1.year ?? 0) }
        case .yearAsc: list.sort { ($0.year ?? 0) < ($1.year ?? 0) }
        case .ratingDesc: list.sort { ($0.rating ?? 0) > ($1.rating ?? 0) }
        case .titleAsc: list.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
        return list
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            Menu {
                Button("全部年份") { yearFilter = nil }
                ForEach(availableYears, id: \.self) { y in
                    Button("\(y) 年") { yearFilter = y }
                }
            } label: {
                filterLabel(yearFilter.map { "\($0) 年" } ?? "全部年份")
            }
            .tint(Color.secondary)

            Menu {
                Button("不限评分") { minRating = 0 }
                ForEach([6.0, 7.0, 8.0], id: \.self) { r in
                    Button("≥ \(Int(r)) 分") { minRating = r }
                }
            } label: {
                filterLabel(minRating > 0 ? "≥ \(Int(minRating)) 分" : "全部评分")
            }
            .tint(Color.secondary)

            Menu {
                ForEach(ActorWorkSort.allCases) { s in
                    Button {
                        workSort = s
                    } label: {
                        if workSort == s { Label(s.label, systemImage: "checkmark") }
                        else { Text(s.label) }
                    }
                }
            } label: {
                filterLabel(workSort.label)
            }
            .tint(Color.secondary)

            Spacer(minLength: 0)
            // 右侧固定显示「当前数/总数」，不随网格滚动
            Text("\(filteredWorks.count)/\(viewModel.movies.count) 部")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private func filterLabel(_ text: String) -> some View {
        HStack(spacing: 4) {
            Text(text)
                .font(.caption.weight(.medium))
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .foregroundStyle(.secondary)
    }

    /// 按容器宽算列数与卡片宽（对齐 MediaListView.gridLayout）：
    /// iPad 满宽右栏约 740pt → 4 列（卡片 ~165pt），12.9 寸可到 6 列；iPhone 仍约 3 列。
    /// 用普通函数 + AnyView（与本文件旧版 worksSection 同构），不依赖 result builder 内的局部变量声明。
    private func worksGrid(works: [ActorWork], type: String, containerWidth: CGFloat) -> some View {
        guard !works.isEmpty else {
            return AnyView(
                ContentUnavailableView("没有符合条件的作品", systemImage: "film")
                    .frame(maxWidth: .infinity, minHeight: 220)
            )
        }
        let spacing: CGFloat = 14
        let gridW = max(containerWidth - panePadding * 2, 0)
        let target: CGFloat = isWide ? 150 : 110
        let n = max(1, Int((gridW + spacing) / (target + spacing)))
        let itemW = max(60, (gridW - spacing * CGFloat(n - 1)) / CGFloat(n))
        let columns = Array(repeating: GridItem(.flexible(), spacing: spacing), count: n)
        return AnyView(
            LazyVGrid(columns: columns, spacing: spacing) {
                ForEach(works) { work in
                    // 作品 → MediaItem，复用列表页同一张 MediaCard + 同一个影视详情页
                    let item = MediaItem(id: work.id, title: work.title, year: work.year,
                                         type: type, libraryId: work.libraryId, rating: work.rating)
                    NavigationLink(value: item) {
                        MediaCard(item: item, coverURL: work.posterURL, width: itemW)
                    }
                    .buttonStyle(.plain)
                }
            }
            .animation(.spring(response: 0.28, dampingFraction: 0.85), value: n)
        )
    }
}

/// 作品排序档位（本地排序，不动后端契约）
private enum ActorWorkSort: String, CaseIterable, Identifiable {
    case yearDesc, yearAsc, ratingDesc, titleAsc
    var id: String { rawValue }
    var label: String {
        switch self {
        case .yearDesc: return "年份 ↓"
        case .yearAsc: return "年份 ↑"
        case .ratingDesc: return "评分 ↓"
        case .titleAsc: return "标题 A–Z"
        }
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

// MARK: - 条件路由注册
// TabView(.page)（UIPageViewController）的 page 内部声明的 navigationDestination
// 不会注册到外层 NavigationStack，NavigationLink 点了完全没反应 —— 媒体库 tab 和
// 人物 tab 都踩过。分页里的页面因此把路由交给宿主统一注册，独立使用时才自己注册。
private extension View {
    @ViewBuilder
    func navigationDestinationIf<D: Hashable, C: View>(_ enabled: Bool, for type: D.Type,
                                                       @ViewBuilder destination: @escaping (D) -> C) -> some View {
        if enabled {
            navigationDestination(for: type, destination: destination)
        } else {
            self
        }
    }
}
