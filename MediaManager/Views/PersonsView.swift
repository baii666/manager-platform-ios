import SwiftUI

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
                    .task {
                        if person.id == viewModel.items.last?.id { await viewModel.loadMore() }
                    }
                }
            }
            .padding(16)
            .bottomBarClearance()
            if viewModel.isLoading {
                ProgressView().frame(maxWidth: .infinity).padding()
            }
        }
        .navigationTitle("人物")
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
        .navigationDestination(for: Person.self) { person in
            PersonPhotosView(person: person)
        }
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
    /// 后端返回的作品总数
    let total: Int
    /// 已加载条数（首批还没回来时用它兜底）
    let loaded: Int

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

    var body: some View {
        HStack(spacing: 14) {
            RemoteImage(url: avatarURL, fallbackIcon: "person.fill",
                        fallbackColors: Theme.placeholderGradient(for: .photo))
                .imageFilled()
                .frame(width: 68, height: 68)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 6) {
                Text(person.displayName)
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
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) {
            Divider().frame(maxWidth: .infinity).opacity(0.6)
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

    var body: some View {
        VStack(spacing: 0) {
            // 人物信息区固定在最上方，不随下面的瀑布流滚走
            PersonPhotosHeader(person: person, total: total, loaded: photos.count)

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
        // 通用标题让导航栏一定有系统返回按钮；具体人物信息在下面的置顶信息区
        .navigationTitle("人物")
        .navigationBarTitleDisplayMode(.inline)
        // 名字/数量已在顶部信息区，导航栏不再重复一遍标题和计数
        .task { await loadMore() }
        .appBackground()
    }

    @MainActor
    private func loadMore() async {
        guard let client = AppSession.shared.client, !isLoading, hasMore else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let (batch, totalCount) = try await client.fetchPersonPhotos(personId: person.id, page: page)
            photos.append(contentsOf: batch)
            total = totalCount
            page += 1
            hasMore = !batch.isEmpty
        } catch {
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

    private var client: APIClient? { AppSession.shared.client }

    @MainActor
    func loadInitial() async {
        // 同 AlbumListView：从照片页返回时 .task 可能重跑，已有数据就跳过，保住滚动位置
        guard items.isEmpty else { return }
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
            let (batch, total) = try await client.fetchPersons(page: page, size: pageSize)
            totalCount = total
            items.append(contentsOf: batch)
            page += 1
            hasMore = !batch.isEmpty && items.count < total
        } catch {
            errorMessage = "加载失败 · \(describe(error))"
        }
    }

    private func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
