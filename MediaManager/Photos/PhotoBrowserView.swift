import SwiftUI

// MARK: - 照片浏览状态（懒加载分页）
final class PhotoBrowserViewModel: ObservableObject {
    @Published var photos: [Photo] = []
    @Published var isLoading = false

    private let provider: DataProviding
    private let pageSize = 60

    init(provider: DataProviding? = nil) {
        self.provider = provider ?? AppSession.shared.client ?? MockDataProvider()
    }

    @MainActor
    func loadInitial() async {
        guard photos.isEmpty else { return }
        await loadMore()
    }

    @MainActor
    func loadMore() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            // ⚠️ 随机照片接口本身随机，`offset` 无意义；翻页去重靠 exclude 把已加载的
            // 照片 id 传给后端排除，否则每次请求都是「全新随机一批」，和已加载大量重叠。
            let batch = try await provider.fetchPhotos(limit: pageSize, offset: 0, exclude: photos.map(\.id))
            photos.append(contentsOf: batch)
        } catch {
            // 忽略：保留已加载内容即可
        }
    }
}

// MARK: - 照片浏览页（瀑布流 + 懒加载 + 大图查看）
struct PhotoBrowserView: View {
    /// 看图器走哪条路。默认全局 overlay（PhotoViewerPresenter，退出丝滑）；
    /// ⚠️ 但本页若被装在 **sheet** 里（「我的 → 照片」），全局 overlay 会被 sheet
    /// 盖在下面看不见 —— 此时传 false，退回本页自己的 fullScreenCover。
    var useGlobalViewer = true
    @State private var localViewerIndex: Int?

    @StateObject private var viewModel = PhotoBrowserViewModel()
    /// 瀑布流列数：双指捏合缩放，按「照片浏览页」记忆
    @State private var columns = PhotoGridPrefs.load("photoBrowser", fallback: 4)

    var body: some View {
        PhotoGrid(
            photos: viewModel.photos,
            columns: columns,
            onColumnsChange: { columns = $0; PhotoGridPrefs.save("photoBrowser", $0) },
            onSelect: { photo in
                guard let i = viewModel.photos.firstIndex(where: { $0.id == photo.id }) else { return }
                if useGlobalViewer {
                    PhotoViewerPresenter.shared.show(viewModel.photos, index: i, hasMore: true, onLoadMore: {
                        Task {
                            await viewModel.loadMore()
                            PhotoViewerPresenter.shared.updatePhotos(viewModel.photos)
                        }
                    })
                } else {
                    localViewerIndex = i
                }
            },
            onReachEnd: {
                Task { await viewModel.loadMore() }
            }
        )
        .ignoresSafeArea(edges: .bottom)
        .navigationTitle("相册")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if viewModel.photos.isEmpty {
                ProgressView("加载照片…")
            }
        }
        .task { await viewModel.loadInitial() }
        .fullScreenCover(isPresented: Binding(
            get: { localViewerIndex != nil },
            set: { if !$0 { localViewerIndex = nil } }
        )) {
            if let index = localViewerIndex {
                PhotoViewerView(
                    photos: viewModel.photos,
                    index: index,
                    hasMore: true,
                    onLoadMore: { Task { await viewModel.loadMore() } },
                    onClose: { localViewerIndex = nil }
                )
            }
        }
        // ⚠️ 每个 tab / 每个 push 进来的页面都要自己垫一层背景：
        // NavigationStack 只渲染栈顶那一层，App 根的背景透不进来。
        .appBackground()
    }
}

// MARK: - 云端浏览器（cloudlib 本地入库轻表：图片瀑布流 + 视频卡片）
// 数据源 = GET /api/cloudlib/items（读本地 cloud_items，零 115、零 X 盘 stat）。
// 图片缩略图走 /thumb、原图走 /raw（都免认证）；视频点开复用 PlayerHostView 全套播放链路。
// 🔴 放在本文件（不新建 .swift）：Windows 无 xcodegen，新建文件要重新 generate 且冲掉手选 Team。
struct CloudBrowserView: View {
    @StateObject private var vm = CloudBrowserViewModel()
    @State private var playRequest: PlaybackRequest?

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 8)]

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                filterBar
                if vm.items.isEmpty && !vm.isLoading {
                    emptyState
                } else {
                    if vm.filter != "video" && !vm.imageItems.isEmpty {
                        PhotoGrid(
                            photos: vm.imagePhotos,
                            columns: 3,
                            fitsContent: true,
                            onSelect: { photo in
                                guard let idx = vm.imagePhotos.firstIndex(where: { $0.id == photo.id }) else { return }
                                PhotoViewerPresenter.shared.show(vm.imagePhotos, index: idx, hasMore: true) {
                                    Task {
                                        await vm.loadMore()
                                        PhotoViewerPresenter.shared.updatePhotos(vm.imagePhotos)
                                    }
                                }
                            }
                            // 🔴 不接 onReachEnd：fitsContent 模式下所有 cell 都在 bounds 内、
                            // willDisplay 会在 reload 时一次性全触发 → 连锁翻页直到拉完整个库
                            // （3.2 万张），又慢又乱。翻页只走下方「加载更多」按钮，用户可控。
                        )
                    }
                    if vm.filter != "image" && !vm.videoItems.isEmpty {
                        videoSection
                    }
                    if vm.isLoading {
                        ProgressView().padding()
                    } else if vm.hasMore {
                        Button { Task { await vm.loadMore() } } label: {
                            Text("加载更多").font(.subheadline).foregroundStyle(.secondary)
                        }
                        .padding(.bottom, 8)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
        }
        .navigationTitle("云端浏览器")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $vm.query, prompt: "搜索云端文件名")
        .onChange(of: vm.query) { _ in Task { await vm.reload() } }
        .bottomBarClearance()
        .appBackground()
        .fullScreenCover(item: $playRequest) { request in
            PlayerHostView(request: request)
        }
        .task { await vm.loadInitial() }
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            ForEach([("all", "全部"), ("image", "图片"), ("video", "视频")], id: \.0) { key, label in
                Button { vm.setFilter(key) } label: {
                    Text(label)
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(Capsule().fill(vm.filter == key ? Color.white.opacity(0.22) : Color.white.opacity(0.08)))
                        .foregroundStyle(vm.filter == key ? .primary : .secondary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    private var videoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("视频 · \(vm.videoItems.count)").font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(vm.videoItems) { item in
                    Button { startPlay(item) } label: {
                        VStack(spacing: 0) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.08))
                                    .aspectRatio(16 / 9, contentMode: .fit)
                                Image(systemName: "play.circle.fill")
                                    .font(.system(size: 30))
                                    .foregroundStyle(.white.opacity(0.7))
                            }
                            Text(item.displayName)
                                .font(.caption2).lineLimit(2).multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .foregroundStyle(.primary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "cloud").font(.system(size: 44)).foregroundStyle(.secondary)
            Text(vm.error.isEmpty ? "云端库为空或尚未同步" : vm.error)
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if vm.error.isEmpty {
                Text("在网页端点「同步目录树」后即可在此浏览")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.top, 80)
    }

    private func startPlay(_ item: CloudItem) {
        playRequest = PlaybackRequest(path: item.localPath,
                                      title: item.displayName,
                                      assetType: nil, assetID: nil,
                                      startAt: nil, knownDuration: nil)
    }
}

@MainActor
final class CloudBrowserViewModel: ObservableObject {
    @Published var items: [CloudItem] = []
    @Published var isLoading = false
    @Published var hasMore = true
    @Published var filter: String = "all"
    @Published var query: String = ""
    @Published var error: String = ""

    private let client: APIClient?
    private let pageSize = 100
    private var total = 0
    /// 🔴 请求代次：切 tab/搜索/下拉刷新都会 reset 并 +1。旧请求返回时若代次已变，
    /// 结果直接丢弃——否则「先切图片再切回全部」会把上一次的残页 append 进新列表，
    /// 表现为排序错乱 + 内容混杂（实测必现）。
    private var epoch = 0

    init(client: APIClient? = nil) {
        self.client = client ?? AppSession.shared.client
    }

    var imageItems: [CloudItem] { items.filter { $0.isImage } }
    var videoItems: [CloudItem] { items.filter { $0.isVideo } }

    /// 图片转瀑布流 Photo：thumb/full URL 由 APIClient 拼（带 token 兼容收紧认证）
    var imagePhotos: [Photo] {
        imageItems.map { item in
            item.asPhoto(thumb: client?.cloudThumbURL(path: item.localPath),
                         full: client?.cloudRawURL(path: item.localPath))
        }
    }

    func loadInitial() async {
        guard items.isEmpty, error.isEmpty else { return }
        await load(reset: true)
    }

    func reload() async { await load(reset: true) }

    func setFilter(_ key: String) {
        guard key != filter else { return }
        filter = key
        Task { await load(reset: true) }
    }

    func loadMore() async {
        guard hasMore, !isLoading else { return }
        await load(reset: false)
    }

    private func load(reset: Bool) async {
        if reset {
            epoch += 1
            items = []; total = 0; hasMore = true; error = ""
            isLoading = false   // 强制放开：切 tab 时旧请求还在飞，不能让它挡住新一轮
        }
        let myEpoch = epoch
        guard hasMore else { return }
        // 翻页（非 reset）才需要 isLoading 去重；reset 已经靠 epoch 作废了旧请求
        if !reset && isLoading { return }
        guard let client else { error = "未连接服务器"; hasMore = false; return }
        isLoading = true
        defer { if myEpoch == epoch { isLoading = false } }
        do {
            let resp = try await client.fetchCloudItems(
                type: filter, q: query.isEmpty ? nil : query,
                limit: pageSize, offset: items.count)
            guard myEpoch == epoch else { return }   // 代次已变：丢弃旧 tab 的残页
            if resp.ok || !resp.items.isEmpty {
                total = resp.total
                items.append(contentsOf: resp.items)
                hasMore = items.count < total
            } else {
                error = resp.error ?? "查询失败"
                hasMore = false
            }
        } catch {
            guard myEpoch == epoch else { return }
            self.error = error.localizedDescription
            hasMore = false
        }
    }
}
