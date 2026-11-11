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

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 14)], spacing: 14) {
                ForEach(viewModel.items) { person in
                    NavigationLink(value: person) {
                        PersonCard(person: person)
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
        // 🔴 这里不注册 navigationDestination：本页只作为「人物」tab 的
        // TabView(.page) 分页使用，page 内部注册的路由不会生效（点了没反应），
        // Person 的路由统一由外层 PeopleHubView 注册。若将来要独立使用本页，
        // 记得在调用方的 NavigationStack 里补 for: Person.self。
    }
}

// MARK: - 人物卡
private struct PersonCard: View {
    let person: Person

    /// 代表脸头像（/face-thumb）。没有代表脸时 RemoteImage 走占位图标
    private var avatarURL: URL? {
        guard let faceId = person.representativeFaceId else { return nil }
        return AppSession.shared.client?.faceThumbURL(faceId)
    }

    var body: some View {
        VStack(spacing: 8) {
            RemoteImage(url: avatarURL, fallbackIcon: "person.fill",
                        fallbackColors: Theme.placeholderGradient(for: .photo))
                .imageFilled()
                .frame(width: 84, height: 84)
                .clipShape(Circle())
            Text(person.displayName)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            Text("\(person.faceCount) 张")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .appSurface(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - 人物页顶部信息区
// 固定在瀑布流上方（不随滚动）：头像 + 名字 + 作品数 / 人脸数。
// 下面的瀑布流就是「这个人物的作品」，两者用一条细分隔线隔开。
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

    /// 头像优先级：聚类代表脸 → 代表照片 → 占位图标
    private var avatarURL: URL? {
        let client = AppSession.shared.client
        if let faceId = person.representativeFaceId {
            return client?.faceThumbURL(faceId)
        }
        if let photoId = person.representativePhotoId {
            return client?.makeURL("/photo", queryItems: [
                URLQueryItem(name: "id", value: "\(photoId)"),
                URLQueryItem(name: "size", value: "600"),
            ])
        }
        return nil
    }

    /// 首批还没回来时别闪一个「0 张作品」
    private var worksText: String {
        if total > 0 { return "\(total) 张作品" }
        if loaded > 0 { return "\(loaded) 张作品" }
        return "作品加载中…"
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
            HStack(spacing: 14) {
                RemoteImage(url: avatarURL, fallbackIcon: "person.fill",
                            fallbackColors: Theme.placeholderGradient(for: .photo))
                    .imageFilled()
                    .frame(width: 68, height: 68)
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: 5) {
                    Text(displayName)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    HStack(spacing: 6) {
                        Text(worksText)
                        if person.faceCount > 0 {
                            Text("·")
                            Text("\(person.faceCount) 张人脸")
                        }
                    }
                    .font(.caption)
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
                details(profile)
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

    /// 展开后的结构化资料。没有的字段直接不出现，不留「—」占位
    private func details(_ p: PersonProfile) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if let aka = p.aliasesText { detailRow("别名", aka, lines: 2) }
            if let born = combine(p.bornText, p.birthplaceText) { detailRow("出生", born) }
            if let size = combine(p.heightText, p.weightText) { detailRow("身材", size) }
            if let m = p.measurementsText { detailRow("三围", m) }
            if let look = p.appearanceText { detailRow("外貌", look) }
            if let body = p.bodyTypeText { detailRow("体型", body) }
            if let url = p.sourceURL {
                Link(destination: url) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        detailLabel("来源")
                        HStack(spacing: 3) {
                            Text("thenude.com")
                                .font(.caption)
                                .underline()
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

    private func detailRow(_ label: String, _ value: String, lines: Int = 1) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            detailLabel(label)
            Text(value)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(lines)
                .truncationMode(.tail)
        }
    }

    private func detailLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .frame(width: 34, alignment: .leading)
    }

    private func combine(_ a: String?, _ b: String?) -> String? {
        let vals = [a, b].compactMap { $0 }
        return vals.isEmpty ? nil : vals.joined(separator: " · ")
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

    var body: some View {
        VStack(spacing: 0) {
            // 人物信息区固定在最上方，不随下面的瀑布流滚走
            PersonPhotosHeader(person: person, profile: profile,
                               total: total, loaded: photos.count)

            PhotoGrid(
                photos: photos,
                columns: columns,
                onColumnsChange: { columns = $0; PhotoGridPrefs.save("personPhotos", $0) },
                onSelect: { photo in
                    guard let i = photos.firstIndex(where: { $0.id == photo.id }) else { return }
                    PhotoViewerPresenter.shared.show(photos, index: i, hasMore: hasMore, onLoadMore: {
                        Task {
                            await loadMore()
                            PhotoViewerPresenter.shared.updatePhotos(photos)
                        }
                    })
                },
                onReachEnd: { Task { await loadMore() } }
            )
            // UICollectionView 在 VStack 里需要明确拿到剩余空间，否则会塌成 0 高
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // 加载/错误提示只盖住瀑布流区域，顶部人物信息始终可见
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
        .ignoresSafeArea(edges: .bottom)
        // 标题留空：人物姓名与数量已经在下面的置顶信息区，导航栏只负责返回
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
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
}

// MARK: - 人物 VM
final class PersonsViewModel: ObservableObject {
    @Published var items: [Person] = []
    @Published var totalCount = 0
    @Published var isLoading = false
    @Published var errorMessage: String?

    private var page = 1
    private let pageSize = 60
    private var hasMore = true
    /// 刷新代际：下拉刷新成功后 +1，让刷新前发出的分页请求结果作废，避免旧页混进新列表
    private var generation = 0

    private var client: APIClient? { AppSession.shared.client }

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
