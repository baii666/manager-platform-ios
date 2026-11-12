import SwiftUI

// MARK: - 取消类错误（列表加载通用）
/// URLSession 的 async 请求在所属 Task 被取消时抛 URLError(.cancelled)，
/// localizedDescription 正是 "cancelled"。SwiftUI 的 .task / .refreshable 会随
/// cell 复用、列表重绘、页面切走、下拉中途松手取消 Task —— 这是正常生命周期事件，
/// 不能写进 errorMessage：旧实现下拉刷新先清空列表，取消后整页就只剩
/// 「加载失败 · cancelled」。
private func isExpectedCancellation(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    if let urlError = error as? URLError, urlError.code == .cancelled { return true }
    let nsError = error as NSError
    if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return true }
    return Task.isCancelled
}

// MARK: - 人物页（人脸聚类）
// 对齐网页端 PersonsPage：人物网格（代表脸头像 + 姓名 + 照片数），点进看该人物的全部照片。
// 入口：相册列表页顶部「人物」行、首页发现区「人物」卡。
// ⚠️ 人物是跨媒体库的全局聚类（face_cluster_persons_* 分表），不属于任何一个库，
// 所以本页自己拉数据，不挂任何库/排序状态。
struct PersonsView: View {
    /// 嵌进「人物」聚合页（PeopleHubView）时由外层统一铺背景与标题。
    var embedded: Bool = false
    @StateObject private var viewModel = PersonsViewModel()

    /// iPad 卡片更大（对齐网页版人物资料页的大卡观感）
    @Environment(\.horizontalSizeClass) private var hSizeClass

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: hSizeClass == .regular ? 210 : 150), spacing: 14)], spacing: 14) {
                ForEach(viewModel.items) { person in
                    NavigationLink(value: person) {
                        PersonCard(person: person, profile: viewModel.profileFacts[person.id])
                    }
                    .buttonStyle(.plain)
                    // ⚠️ 别用 .task：SwiftUI 会在 cell 复用 / items 重绘时取消它，
                    // 连带取消正在跑的 URLSession 请求（URLError.cancelled），
                    // 于是滑到底那一页静默丢掉、还写一条 cancelled 错误。
                    // 改 onAppear + 非结构化 Task，去重交给 VM 的 isLoading。
                    .onAppear {
                        if person.id == viewModel.items.last?.id {
                            Task { await viewModel.loadMore() }
                        }
                    }
                }
            }
            .padding(16)
            .bottomBarClearance()
            if viewModel.isLoading {
                ProgressView().frame(maxWidth: .infinity).padding()
            }
        }
        // 嵌进「人物」聚合页时不写标题：顶栏交给外层那段「照片人物 / 影视演员」分段，
        // 独立从相册页 push 进来时才需要「人物」标题
        .navigationTitle(embedded ? "" : "人物")
        .navigationBarTitleDisplayMode(.inline)
        // ⚠️ 每个 push 进来的页面都要自己垫一层背景：NavigationStack 只渲染栈顶那一层。
        // 嵌进「人物」聚合页时由外层统一铺，否则背景图模式会压暗两次。
        .background { if !embedded { AppBackgroundView() } }
        .refreshing { await viewModel.reload() }
        .overlay {
            if viewModel.items.isEmpty && !viewModel.isLoading {
                ContentUnavailableView(
                    viewModel.errorMessage ?? "暂无人物",
                    systemImage: viewModel.errorMessage == nil ? "person.2.fill" : "exclamationmark.triangle"
                )
            }
        }
        .task { await viewModel.loadInitial() }
        // 档案资料独立拉一次，失败不影响列表
        .task { await viewModel.loadFacts() }
        // 🔴 这里不注册 navigationDestination：本页只作为「人物」tab 的
        // TabView(.page) 分页使用，page 内部注册的路由不会生效（点了没反应），
        // Person 的路由统一由外层 PeopleHubView 注册。若将来要独立使用本页，
        // 记得在调用方的 NavigationStack 里补 for: Person.self。
    }
}

// MARK: - 人物卡
// 对齐网页版人物资料页 ProfileCard：封面原生 3:4 完整显示，
// 图上左上「N 脸」黑胶囊、右上相似度胶囊；图下名字 + 出生/身高/出生地最多两行。
// 卡片边界只是一条 0.5pt 细描边 + 薄底板，不是厚边框。
private struct PersonCard: View {
    let person: Person
    /// 已挂档案的资料（无档案传 nil，卡片就不显示资料行 / 相似度）
    var profile: PersonProfile? = nil

    private var displayName: String { profile?.displayName ?? person.displayName }

    /// 与网页版同款三事实：出生 → 身高 → 出生地，最多展示 2 行
    private var facts: [(icon: String, text: String)] {
        guard let p = profile else { return [] }
        var list: [(String, String)] = []
        if let born = p.bornText { list.append(("birthday.cake", born)) }
        if let height = p.heightText { list.append(("ruler", height)) }
        if let birth = p.birthplaceText { list.append(("mappin.and.ellipse", birth)) }
        return list.prefix(2).map { ($0.0, $0.1) }
    }

    /// 相似度胶囊底色：≥0.75 绿、≥0.62 琥珀、其余黑（网页版同规则）
    private func simColor(_ sim: Double) -> Color {
        sim >= 0.75 ? Color.green.opacity(0.75)
            : sim >= 0.62 ? Color.orange.opacity(0.75)
            : Color.black.opacity(0.55)
    }

    var body: some View {
        VStack(spacing: 0) {
            // 图区：封面原生 3:4，clear 撑比例、图 overlay 填满（object-top）
            Color.clear
                .aspectRatio(3 / 4, contentMode: .fit)
                .overlay {
                    RemoteImage(url: personCoverURL(person), fallbackURL: personFaceURL(person),
                                fallbackIcon: "person.fill",
                                fallbackColors: Theme.placeholderGradient(for: .photo))
                        .imageFilled(alignment: .top)
                }
                .overlay(alignment: .topLeading) {
                    if person.faceCount > 0 {
                        imageCapsule("\(person.faceCount.formatted()) 脸")
                            .padding(6)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if let sim = profile?.thenudeSim, sim > 0 {
                        imageCapsule("\(Int((sim * 100).rounded()))%")
                            .background(simColor(sim), in: Capsule())
                            .padding(6)
                    }
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(displayName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                ForEach(facts.indices, id: \.self) { i in
                    HStack(spacing: 4) {
                        Image(systemName: facts[i].icon)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.tertiary)
                        Text(facts[i].text)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
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

    /// 图上的小胶囊：黑底白字 11 号
    private func imageCapsule(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.black.opacity(0.55), in: Capsule())
    }
}

// MARK: - 人物页顶部信息区
// 固定在瀑布流上方（不随滚动）：头像 + 名字 + 作品数 / 人脸数。
// 下面的瀑布流就是「这个人物的作品」，两者用一条细分隔线隔开。
// MARK: - 人物资料共用组件（iPhone 顶部条 / iPad 左栏共用）
/// 人物封面（/person-cover），参数是簇 id —— 离线打分流程按簇产出的上半身标准肖像
private func personCoverURL(_ person: Person) -> URL? {
    AppSession.shared.client?.personCoverURL(person.id)
}

/// 封面缺失时的回退图：代表脸（/face-thumb）→ 代表照片
private func personFaceURL(_ person: Person) -> URL? {
    let client = AppSession.shared.client
    if let faceId = person.representativeFaceId { return client?.faceThumbURL(faceId) }
    if let photoId = person.representativePhotoId {
        return client?.makeURL("/photo", queryItems: [
            URLQueryItem(name: "id", value: "\(photoId)"),
            URLQueryItem(name: "size", value: "600"),
        ])
    }
    return nil
}

/// 展开后的结构化资料。没有的字段直接不出现，不留「—」占位
private func personDetails(_ p: PersonProfile) -> some View {
    VStack(alignment: .leading, spacing: 5) {
        if let aka = p.aliasesText { personDetailRow("别名", aka, lines: 2) }
        if let born = personCombine(p.bornText, p.birthplaceText) { personDetailRow("出生", born) }
        if let size = personCombine(p.heightText, p.weightText) { personDetailRow("身材", size) }
        if let m = p.measurementsText { personDetailRow("三围", m) }
        if let look = p.appearanceText { personDetailRow("外貌", look) }
        if let body = p.bodyTypeText { personDetailRow("体型", body) }
        if let url = p.sourceURL {
            Link(destination: url) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    personDetailLabel("来源")
                    HStack(spacing: 3) {
                        Text("thenude.com").font(.caption).underline()
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(.secondary)
                }
            }
        }
    }
    .padding(.top, 2)
}

private func personDetailRow(_ label: String, _ value: String, lines: Int = 1) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
        personDetailLabel(label)
        Text(value)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(lines)
            .truncationMode(.tail)
    }
}

private func personDetailLabel(_ text: String) -> some View {
    Text(text)
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .frame(width: 34, alignment: .leading)
}

private func personCombine(_ a: String?, _ b: String?) -> String? {
    let vals = [a, b].compactMap { $0 }
    return vals.isEmpty ? nil : vals.joined(separator: " · ")
}

/// 人物照片页的排序（Photo 没有拍摄时间，能排的只有文件名与后端默认顺序）
private enum PersonPhotoSort: String, CaseIterable, Identifiable {
    case original = "默认顺序"
    case nameAsc = "文件名 ↑"
    case nameDesc = "文件名 ↓"
    var id: String { rawValue }
}

private struct PersonPhotosHeader: View {
    let person: Person
    /// 外部档案：约 96% 的聚类人物没匹配到（接口 200 但 meta 为空），
    /// 这种人物顶部保持原来的一行信息，不出现「资料」入口
    let profile: PersonProfile?
    /// 后端返回的作品总数
    let total: Int
    /// 已加载条数（首批还没回来时用它兜底）
    let loaded: Int

    /// 资料默认收起：展开后字段多，会把下面的瀑布流挤掉一半
    @State private var expanded = false

    /// 头像优先级：封面 → 聚类代表脸 → 代表照片 → 占位图标
    private var coverURL: URL? { personCoverURL(person) }

    /// 首批还没回来时别闪一个「0 张照片」
    private var photosText: String {
        if total > 0 { return "\(total) 张照片" }
        if loaded > 0 { return "\(loaded) 张照片" }
        return "照片加载中…"
    }

    /// 对齐网页版 PersonDetailView：人脸数在前，「N 张人脸 · N 张照片」
    private var infoLine: String {
        if person.faceCount > 0 { return "\(person.faceCount) 张人脸 · \(photosText)" }
        return photosText
    }

    private var displayName: String {
        profile?.displayName ?? person.displayName
    }

    /// 收起时的一行摘要；展开后资料区已写同样内容，不重复
    private var summaryLine: String? {
        guard let p = profile else { return nil }
        let parts = [p.bornText, p.heightText, p.measurementsText].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                RemoteImage(url: coverURL, fallbackURL: personFaceURL(person),
                            fallbackIcon: "person.fill",
                            fallbackColors: Theme.placeholderGradient(for: .photo))
                    .imageFilled(alignment: .top)
                    .frame(width: 80, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 5) {
                    Text(displayName)
                        .font(.title2.weight(.bold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(infoLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if !expanded, let summaryLine {
                        Text(summaryLine)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Spacer(minLength: 0)
                if let profile, profile.hasDetails {
                    toggleButton
                }
            }

            if expanded, let profile, profile.hasDetails {
                personDetails(profile)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) {
            Divider().frame(maxWidth: .infinity).opacity(0.6)
        }
    }

    private var toggleButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
        } label: {
            HStack(spacing: 3) {
                Text(expanded ? "收起" : "资料")
                    .font(.caption.weight(.medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(expanded ? 180 : 0))
            }
            .foregroundStyle(.secondary)
            .padding(.leading, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

}

// MARK: - iPad 人物详情左资料栏（与演员详情页 profileColumn 同构，280pt）
private struct PersonSidebar: View {
    let person: Person
    let profile: PersonProfile?
    let total: Int
    let loaded: Int

    /// 资料默认收起，需要时点「资料」展开
    @State private var expanded = false

    private var displayName: String { profile?.displayName ?? person.displayName }
    /// 对齐网页版文案：照片数（不再是「作品」）
    private var photosText: String {
        if total > 0 { return "\(total) 张照片" }
        if loaded > 0 { return "\(loaded) 张照片" }
        return "照片加载中…"
    }

    /// 与网页版一致：人脸数在前，「N 张人脸 · N 张照片」
    private var infoLine: String {
        if person.faceCount > 0 { return "\(person.faceCount) 张人脸 · \(photosText)" }
        return photosText
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            avatar.frame(maxWidth: .infinity, alignment: .center)

            VStack(alignment: .leading, spacing: 6) {
                Text(displayName)
                    .font(.title.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(infoLine).font(.subheadline).foregroundStyle(.secondary)
            }

            if let profile, profile.hasDetails {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 3) {
                        Text(expanded ? "收起资料" : "资料")
                            .font(.caption.weight(.medium))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if expanded { personDetails(profile) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var avatar: some View {
        if let url = personCoverURL(person) {
            RemoteImage(url: url, fallbackURL: personFaceURL(person),
                        fallbackIcon: "person.fill",
                        fallbackColors: Theme.placeholderGradient(for: .photo))
                .imageFilled(alignment: .top)
                .frame(width: 160, height: 160)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Theme.brand.opacity(0.16))
                .frame(width: 160, height: 160)
                .overlay {
                    Text(String(displayName.prefix(1)).uppercased())
                        .font(.system(size: 60, weight: .medium))
                        .foregroundStyle(Theme.brand)
                }
        }
    }
}

// MARK: - 人物照片页
// 某个聚类人物的全部照片。复用全局看图器（PhotoViewerPresenter）——
// 与相册内照片页同一套呈现，翻页加载后同步 updatePhotos。
struct PersonPhotosView: View {
    let person: Person

    @State private var photos: [Photo] = []
    /// 瀑布流列数：双指捏合缩放，按「人物照片页」记忆
    @State private var columns = PhotoGridPrefs.load("personPhotos", fallback: 4)
    @State private var isLoading = false
    @State private var page = 1
    @State private var hasMore = true
    @State private var errorMessage: String?
    /// 后端给的作品总数（不是已加载条数）：顶部信息区显示它，翻页时不跳动
    @State private var total = 0
    /// 外部人物档案（thenude）。多数人物没有（meta 为空），顶部退回原来的一行信息
    @State private var profile: PersonProfile?
    /// 只请求一次：.task 在页面重新出现时可能重跑，避免重复请求
    @State private var profileLoaded = false
    /// 右栏顶端固定工具行：排序（Photo 无拍摄时间，只排文件名 / 默认顺序）
    @State private var photoSort: PersonPhotoSort = .original

    @Environment(\.horizontalSizeClass) private var hSizeClass
    private var isWide: Bool { hSizeClass == .regular }
    /// 与演员详情页同一套分栏宽度 / 内边距，两页视觉一致
    private var sidebarWidth: CGFloat { 280 }
    private var panePadding: CGFloat { isWide ? 20 : 16 }

    var body: some View {
        Group {
            if isWide { wideContent } else { narrowContent }
        }
        // 标题留空：姓名在左栏 / 顶部资料条，导航栏只负责返回
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        // 顶 bar 保持实心：左栏与固定工具行都不许盖到导航栏
        .toolbarBackground(.visible, for: .navigationBar)
        .ignoresSafeArea(edges: .bottom)
        // 两个 task 并发：资料很轻，先回来也不会拖慢照片首屏
        .task { await loadProfile() }
        .task { await loadMore() }
        .appBackground()
    }

    /// 资料是可选增强：没有档案的人物返回 200 + 空 meta，网络失败也静默忽略
    @MainActor
    private func loadProfile() async {
        guard !profileLoaded, let client = AppSession.shared.client else { return }
        profileLoaded = true
        profile = try? await client.fetchPersonProfile(personId: person.id)
    }

    @MainActor
    private func loadMore() async {
        guard let client = AppSession.shared.client, !isLoading, hasMore else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let (batch, totalCount) = try await client.fetchPersonPhotos(personId: person.id, page: page)
            // 页面已切走 / 任务已取消时别再改 UI，也别把取消写成失败
            guard !Task.isCancelled else { return }
            photos.append(contentsOf: batch)
            total = totalCount
            page += 1
            hasMore = !batch.isEmpty
            errorMessage = nil
        } catch {
            guard !isExpectedCancellation(error) else { return }
            errorMessage = "加载照片失败 · \(((error as? LocalizedError)?.errorDescription) ?? error.localizedDescription)"
        }
    }

    /// 排序只改显示顺序，不动 photos 本体（分页追加 / 去重逻辑保持原样）
    private var displayPhotos: [Photo] {
        switch photoSort {
        case .original: return photos
        case .nameAsc:
            return photos.sorted {
                ($0.fileName ?? "").localizedStandardCompare($1.fileName ?? "") == .orderedAscending
            }
        case .nameDesc:
            return photos.sorted {
                ($0.fileName ?? "").localizedStandardCompare($1.fileName ?? "") == .orderedDescending
            }
        }
    }

    /// 右侧固定显示「已加载数/总数」，分页时左值递增
    private var countText: String {
        let t = total > 0 ? "\(total)" : (photos.count > 0 ? "\(photos.count)" : "—")
        return "\(photos.count)/\(t)"
    }

    // MARK: iPad 双栏（左 280pt 资料栏 + 右照片网格，共用同一条顶 bar）
    private var wideContent: some View {
        VStack(spacing: 0) {
            // 一条横跨两栏的顶 bar，贴在导航栏正下方；两栏内容从同一条线开始
            pinnedToolBar
            HStack(spacing: 0) {
                ScrollView {
                    PersonSidebar(person: person, profile: profile, total: total, loaded: photos.count)
                        .padding(panePadding)
                        .bottomBarClearance()
                }
                .frame(width: sidebarWidth)
                .background(Color.primary.opacity(0.04))

                Rectangle()
                    .fill(Color.primary.opacity(0.15))
                    .frame(width: 0.5)

                photoGrid
                    // UICollectionView 在 HStack 里需要明确拿到剩余空间，否则会塌成 0 高
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: iPhone 单栏（顶部资料条 + 固定工具行 + 网格）
    private var narrowContent: some View {
        VStack(spacing: 0) {
            PersonPhotosHeader(person: person, profile: profile,
                               total: total, loaded: photos.count)
            photoGrid
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // 工具行顶在资料条正下方，不随网格滚走
                .safeAreaInset(edge: .top, spacing: 0) { pinnedToolBar }
        }
    }

    /// 固定在顶端的一行：排序 / 列数放同一行，最右显示 已加载/总数
    private var pinnedToolBar: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(PersonPhotoSort.allCases) { s in
                    Button {
                        photoSort = s
                    } label: {
                        if photoSort == s { Label(s.rawValue, systemImage: "checkmark") }
                        else { Text(s.rawValue) }
                    }
                }
            } label: {
                toolLabel(photoSort.rawValue)
            }
            .tint(Color.secondary)

            Menu {
                ForEach([2, 3, 4, 5, 6], id: \.self) { n in
                    Button("\(n) 列") {
                        columns = n
                        PhotoGridPrefs.save("personPhotos", n)
                    }
                }
            } label: {
                toolLabel("\(columns) 列")
            }
            .tint(Color.secondary)

            Spacer(minLength: 0)
            Text(countText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, panePadding)
        .padding(.vertical, 10)
        // 与左栏同一层浅底色，整条 bar 融为页面一部分（regularMaterial 在灰底上发灰）
        .background(Color.primary.opacity(0.04))
        .overlay(alignment: .bottom) { Divider().opacity(0.6) }
    }

    private func toolLabel(_ text: String) -> some View {
        HStack(spacing: 4) {
            Text(text).font(.caption.weight(.medium))
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.06), in: Capsule())
    }

    private var photoGrid: some View {
        PhotoGrid(
            photos: displayPhotos,
            columns: columns,
            onColumnsChange: { columns = $0; PhotoGridPrefs.save("personPhotos", $0) },
            onSelect: { photo in
                let list = self.displayPhotos
                guard let i = list.firstIndex(where: { $0.id == photo.id }) else { return }
                PhotoViewerPresenter.shared.show(list, index: i, hasMore: hasMore, onLoadMore: {
                    Task {
                        await self.loadMore()
                        PhotoViewerPresenter.shared.updatePhotos(self.displayPhotos)
                    }
                })
            },
            onReachEnd: { Task { await self.loadMore() } }
        )
        // 加载/错误提示只盖住网格区域，左栏资料与顶端工具行始终可见
        .overlay {
            if photos.isEmpty {
                if let errorMessage {
                    ContentUnavailableView(errorMessage, systemImage: "exclamationmark.triangle")
                } else {
                    ProgressView("加载照片…")
                }
            }
        }
    }
}

// MARK: - 人物 VM
final class PersonsViewModel: ObservableObject {
    @Published var items: [Person] = []
    @Published var totalCount = 0
    @Published var isLoading = false
    @Published var errorMessage: String?
    /// 已挂档案人物的资料（出生/身高/出生地/相似度），按簇 id 索引。
    /// 卡片用它显示网页版人物资料页同款的数据行；没挂档案的人物卡片少两行小字。
    @Published var profileFacts: [Int: PersonProfile] = [:]

    private var page = 1
    private let pageSize = 60
    private var hasMore = true
    /// 刷新代际：下拉刷新成功后 +1，让刷新前发出的分页请求结果作废，避免旧页混进新列表
    private var generation = 0
    /// 档案列表只拉一次（数据不随分页变化）
    private var factsLoaded = false

    private var client: APIClient? { AppSession.shared.client }

    /// 一次拉全档案列表（约 976 条，接口 size 上限 300 → 最多 4 页并发）。
    /// 失败静默：档案只是卡片上的增强数据，不该拖垮列表本身。
    @MainActor
    func loadFacts() async {
        guard !factsLoaded, let client else { return }
        factsLoaded = true
        do {
            let (_, total) = try await client.fetchPersonProfiles(page: 1)
            let pages = max(1, Int(ceil(Double(total) / 300.0)))
            var dict: [Int: PersonProfile] = [:]
            try await withThrowingTaskGroup(of: [PersonProfile].self) { group in
                for p in 1...pages {
                    group.addTask {
                        try await client.fetchPersonProfiles(page: p, size: 300).items
                    }
                }
                for try await batch in group {
                    for profile in batch { dict[profile.id] = profile }
                }
            }
            profileFacts = dict
        } catch {
            // 取消 / 失败都允许下次进页面重试
            factsLoaded = false
        }
    }

    @MainActor
    func loadInitial() async {
        // 同 AlbumListView：从照片页返回时 .task 可能重跑，已有数据就跳过，保住滚动位置
        guard items.isEmpty else { return }
        await reload()
    }

    @MainActor
    func reload() async {
        // ⚠️ 不要在请求前清空 items：.refreshable 的 Task 会被系统取消
        //（下拉中途松手 / 切 tab / 页面重绘），URLSession 抛 URLError.cancelled。
        // 旧实现清空后整页只剩「加载失败 · cancelled」。改成拿回数据再整体替换，
        // 取消或真失败时都保留原列表。
        await loadMore(replacing: true)
    }

    @MainActor
    func loadMore(replacing: Bool = false) async {
        guard let client, !isLoading, (replacing || hasMore) else { return }
        if replacing {
            page = 1
            hasMore = true
            errorMessage = nil
        }
        let gen = generation
        // 请求发起时的页码快照：刷新换代后旧请求回来也不能把 page 改回旧值
        let requestedPage = page
        isLoading = true
        defer { isLoading = false }
        do {
            let (batch, total) = try await client.fetchPersons(page: requestedPage, size: pageSize)
            // 刷新已换代的旧分页结果、以及已被取消的任务，都不要再改 UI
            guard gen == generation, !Task.isCancelled else { return }
            if replacing {
                generation += 1   // 作废刷新前发出的分页请求
                items = batch
            } else {
                items.append(contentsOf: batch)
            }
            totalCount = total
            page = requestedPage + 1
            hasMore = !batch.isEmpty && items.count < total
            errorMessage = nil
        } catch {
            // 取消是正常生命周期事件，不是加载失败；真失败才提示
            guard !isExpectedCancellation(error) else { return }
            errorMessage = "加载失败 · \(describe(error))"
        }
    }

    private func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
