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

// MARK: - 云端浏览器首页（配置目录列表）
/// 进入云 tab 第一屏：列出 /api/cloudlib/status 的配置入库目录 + 每目录条目数。
/// 点某个目录 push CloudBrowserView(root:) 按 root 筛选；「全部目录」root=nil。
/// 🔴 放在本文件（不新建 .swift）：Windows 无 xcodegen，新建文件要重新 generate 且冲掉手选 Team。
struct CloudRootListView: View {
    /// 是否处于云 tab。RootView 的 ZStack 一次性创建全部 tab，
    /// 本页的 .task 必须等真正切到云 tab 才加载，别在 App 启动瞬间发请求。
    var active: Bool = true
    @StateObject private var vm = CloudRootListViewModel()

    var body: some View {
        Group {
            if vm.isLoading && vm.roots.isEmpty {
                ProgressView("加载目录…")
            } else if !vm.error.isEmpty, vm.roots.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle").font(.title2).foregroundStyle(.orange)
                    Text(vm.error).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("重试") { Task { await vm.load() } }
                }
            } else {
                List {
                    // 全部目录：root=nil，走原来的全库瀑布流
                    NavigationLink {
                        CloudBrowserView(root: nil)
                    } label: {
                        rootRow(icon: "square.stack.3d.up.fill",
                                title: "全部目录",
                                detail: "\(vm.totalItems) 项 · 所有配置目录",
                                color: .accentColor)
                    }
                    ForEach(vm.roots) { r in
                        NavigationLink {
                            CloudBrowserView(root: r)
                        } label: {
                            rootRow(icon: "folder.fill",
                                    title: r.netPath.isEmpty ? "（未命名目录）" : r.netPath,
                                    detail: "\(r.activeItems) 项 · \(r.mount)",
                                    color: .orange)
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("云端浏览器")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await vm.load() }
        // 🔴 只在云 tab 激活时首次加载；切到别的 tab 不发请求。
        .task(id: active) {
            if active { await vm.load() }
        }
        .bottomBarClearance()
        .appBackground()
    }

    private func rootRow(icon: String, title: String, detail: String, color: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.title3).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium)).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }
}

final class CloudRootListViewModel: ObservableObject {
    @Published var roots: [CloudRoot] = []
    @Published var totalItems: Int = 0
    @Published var isLoading = false
    @Published var error: String = ""

    @MainActor
    func load() async {
        isLoading = true
        error = ""
        defer { isLoading = false }
        guard let client = AppSession.shared.client else {
            error = "未连接服务器"
            return
        }
        do {
            let resp = try await client.fetchCloudStatus()
            roots = resp.roots
            totalItems = resp.activeItems
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - 云端浏览器（cloudlib 本地入库轻表：图片瀑布流 + 视频卡片）
// 数据源 = GET /api/cloudlib/items（读本地 cloud_items，零 115、零 X 盘 stat）。
// 图片缩略图走 /thumb、原图走 /raw（都免认证）；视频点开复用 PlayerHostView 全套播放链路。
// 🔴 放在本文件（不新建 .swift）：Windows 无 xcodegen，新建文件要重新 generate 且冲掉手选 Team。
struct CloudBrowserView: View {
    /// 选中的配置目录；nil = 全部。目录列表页点进来时传入。
    var root: CloudRoot? = nil
    @StateObject private var vm: CloudBrowserViewModel
    @State private var playRequest: PlaybackRequest?
    /// 瀑布流列数：捏合缩放 + 各页记忆（与相册/搜索/人物页同一套 PhotoGrid）。
    @State private var columns = PhotoGridPrefs.load("cloudBrowser", fallback: 3)
    /// 视频卡片用固定网格（条数少，不需要捏合缩放）
    private let videoColumns = [GridItem(.adaptive(minimum: 110), spacing: 8)]

    init(root: CloudRoot? = nil) {
        self.root = root
        _vm = StateObject(wrappedValue: CloudBrowserViewModel(root: root))
    }

    /// 顶栏标题：全部=「全部目录」，单目录取路径最后一段（完整路径太长放不下）。
    private var navTitle: String {
        guard let r = root else { return "全部目录" }
        let parts = r.netPath.split(separator: "/").map(String.init)
        return parts.last ?? r.netPath
    }

    var body: some View {
        Group {
            if vm.filter == "image" {
                cloudImageGrid
            } else {
                cloudVideoGrid
            }
        }
        .navigationTitle(navTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // 🔴 与相册详情页一致：图片/视频 tab 放系统顶栏正中（principal），
            // 不是下拉框，也不占内容区一条高度。切换仍是纯本地过滤、零请求。
            ToolbarItem(placement: .principal) {
                cloudTabBar
            }
            .withoutGlass()
        }
        .searchable(text: $vm.query, prompt: "搜索云端文件名")
        .onChange(of: vm.query) { _ in Task { await vm.reload() } }
        .bottomBarClearance()
        .appBackground()
        .fullScreenCover(item: $playRequest) { request in
            PlayerHostView(request: request)
        }
        .task { await vm.loadInitial() }
    }

    /// 🔴 图片走项目现成的瀑布流组件 PhotoGrid（MasonryLayout 按图片真实宽高比排版），
    /// fitsContent=false 让它自己滚 —— willDisplay 只在 cell 进入可视区时触发，
    /// 底部 onReachEnd 自动翻页是全 App（相册/搜索/人物页）验证过的标准路径，不会连锁。
    /// 下拉刷新用 PhotoGrid 原生 UIRefreshControl（onRefresh），不再靠 SwiftUI .refreshable
    /// （后者必须套外层 ScrollView，正是 fitsContent=true 连锁翻页的根源）。
    private var cloudImageGrid: some View {
        PhotoGrid(
            photos: vm.imagePhotos,
            columns: columns,
            onColumnsChange: { columns = $0; PhotoGridPrefs.save("cloudBrowser", $0) },
            onSelect: openImage,
            onReachEnd: { Task { await vm.loadMore() } },
            onRefresh: { await vm.reload() }
        )
        .overlay {
            if vm.items.isEmpty && vm.isLoading {
                ProgressView("加载中…")
            } else if vm.items.isEmpty {
                emptyState
            } else if !vm.error.isEmpty && !vm.isLoading {
                VStack { errorBanner; Spacer() }
            }
        }
        // 翻页加载提示：悬浮在底部，不进 VStack、不占布局高度 ——
        // PhotoGrid 自己滚，不能再塞 footer 进内容（那会走回 fitsContent 连锁老路）。
        .overlay(alignment: .bottom) {
            if vm.isLoading && !vm.items.isEmpty { loadingMoreIndicator }
        }
    }

    /// 自动翻页时的转圈提示，悬浮胶囊，只在真正加载中显示。
    private var loadingMoreIndicator: some View {
        HStack(spacing: 8) {
            ProgressView()
            Text("加载更多…")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .padding(.bottom, 16)
    }

    /// 视频条数少，用普通 ScrollView + LazyVGrid（保留 SwiftUI 原生下拉刷新）。
    private var cloudVideoGrid: some View {
        ScrollView {
            videoSection
                .padding(.horizontal, 10)
                .padding(.top, 8)
        }
        .refreshable { await vm.reload() }
        .overlay {
            if vm.videoItems.isEmpty && vm.isLoading {
                ProgressView("加载中…")
            } else if vm.videoItems.isEmpty {
                emptyState
            }
        }
    }

    // 🔴 下面这些视图/闭包单独拆出来：body 里内联太多复杂表达式会让 Swift 类型检查器
    // 直接超时（"unable to type-check this expression"，报在 ViewBuilder 的某个 if 行上）。
    // 拆成具名计算属性后编译器分块检查，body 就轻了。

    private func openImage(_ photo: Photo) {
        guard let idx = vm.imagePhotos.firstIndex(where: { $0.id == photo.id }) else { return }
        PhotoViewerPresenter.shared.show(vm.imagePhotos, index: idx, hasMore: true) {
            Task {
                await vm.loadMore()
                PhotoViewerPresenter.shared.updatePhotos(vm.imagePhotos)
            }
        }
    }

    @ViewBuilder
    private var errorBanner: some View {
        if !vm.error.isEmpty && !vm.isLoading {
            Button {
                Task { await vm.retry() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                    Text("\(vm.error) · 点击重试")
                }
                .font(.caption)
                .foregroundStyle(.orange)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 8)
        }
    }

    /// 顶栏正中的分段胶囊，样式对齐相册详情页（品牌色淡底 + 图标 + 数量）。
    /// 🔴 字重恒定，避免切换时中文字重变化让胶囊宽度跳动。
    private var cloudTabBar: some View {
        HStack(spacing: 8) {
            ForEach([
                ("image", "图片", "photo", vm.imageItems.count),
                ("video", "视频", "film", vm.videoItems.count),
            ], id: \.0) { key, label, icon, count in
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { vm.setFilter(key) }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: icon)
                            .font(.system(size: 12, weight: .semibold))
                        Text(label)
                        Text("\(count)")
                            .font(.caption2).monospacedDigit()
                            .foregroundStyle(vm.filter == key ? Theme.brand : Color.secondary)
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(vm.filter == key ? Theme.brand : Color.secondary)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(vm.filter == key ? Theme.brand.opacity(0.15) : Color.clear,
                                in: Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var videoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("视频 · \(vm.videoItems.count)").font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: videoColumns, spacing: 8) {
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
            } else {
                Button {
                    Task { await vm.retry() }
                } label: {
                    Label("重试", systemImage: "arrow.clockwise")
                        .font(.subheadline).foregroundStyle(Theme.brand)
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 320)
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
    /// 只有图片/视频两个 tab（无「全部」）：🔴 纯本地过滤，切换不发任何请求
    @Published var filter: String = "image"
    @Published var query: String = ""
    @Published var error: String = ""

    private let client: APIClient?
    /// 当前选中的配置目录（nil = 全部目录）。作为 root_key 筛选传给 items 接口。
    let root: CloudRoot?
    /// 一次拉混合数据本地分组：视频占比小，页大一点减少「加载更多」点击
    private let pageSize = 200
    private var total = 0
    /// 🔴 请求代次：下拉刷新/搜索都 +1。旧请求返回时若代次已变直接丢弃，
    /// 避免残页 append 进新列表造成排序错乱。
    private var epoch = 0

    init(root: CloudRoot? = nil, client: APIClient? = nil) {
        self.root = root
        self.client = client ?? AppSession.shared.client
    }

    var imageItems: [CloudItem] { items.filter { $0.isImage } }
    var videoItems: [CloudItem] { items.filter { $0.isVideo } }
    var visibleItems: [CloudItem] { filter == "video" ? videoItems : imageItems }

    /// 图片转瀑布流 Photo：thumb/full URL 由 APIClient 拼（带 token 兼容收紧认证）
    var imagePhotos: [Photo] {
        imageItems.map { item in
            // 🔴 云端一律用 /raw 原图，不用 /thumb 缩略图：
            // 1) 云端是本地入库快照，原图就是压缩档（jpg ~97KB / png ~457KB，实测），
            //    并非几千万像素的大原片，瀑布流直出原图不会撑爆内存；
            // 2) /thumb?fast=1 缓存缺失时直吐 gif 原图（2~3MB），走 X: 挂载盘下载慢 → 灰块；
            // 3) gif/heic 经 /thumb 转出的 webp 在 ImageCache.forceDecoded 下会丢动画。
            // 统一 /raw 后：gif 原样保动画、heic 由系统原生解码、看图器 thumb==full 秒开。
            let u = client?.cloudRawURL(path: item.localPath)
            return item.asPhoto(thumb: u, full: u)
        }
    }

    func loadInitial() async {
        // 🔴 不再被 error 挡住：超时后 error 非空，切 tab 回来必须能自动重试首屏
        guard items.isEmpty, !isLoading else { return }
        await load(offset: 0, replace: true)
    }

    /// 下拉刷新 / 搜索：重新从 0 拉。🔴 不清空 items、成功后整体替换，
    /// 这样刷新/搜索期间旧列表还在，不会白屏闪烁（refreshable 红线）。
    func reload() async {
        await load(offset: 0, replace: true)
    }

    /// 🔴 切 tab 纯本地过滤：不发任何请求，不动 items/epoch。
    func setFilter(_ key: String) {
        guard key != filter else { return }
        filter = key
    }

    func loadMore() async {
        guard hasMore, !isLoading else { return }
        await load(offset: items.count, replace: false)
    }

    /// 错误后的显式重试：清掉 error 再从 0 拉一次。
    /// 🔴 不清空 items（保留旧列表不白屏），靠 replace 整体替换；
    /// error 一清，底部哨兵重新出现，又能继续自动翻页。
    func retry() async {
        error = ""
        await load(offset: 0, replace: true)
    }

    /// offset=0+replace=true → 刷新（保留旧数据直到新数据到）；否则翻页 append。
    /// type 恒为 nil：一次拉混合数据，图片/视频本地分组，切 tab 才零请求。
    private func load(offset: Int, replace: Bool) async {
        if replace {
            epoch += 1
            isLoading = false   // 放开：上一轮请求还在飞也不挡新一轮
        }
        let myEpoch = epoch
        if !replace && isLoading { return }
        guard let client else { error = "未连接服务器"; return }
        isLoading = true
        defer { if myEpoch == epoch { isLoading = false } }
        do {
            let resp = try await client.fetchCloudItems(
                type: nil, root: root?.key, q: query.isEmpty ? nil : query,
                limit: pageSize, offset: offset)
            guard myEpoch == epoch else { return }   // 代次已变：丢弃过期结果
            if resp.ok || !resp.items.isEmpty {
                total = resp.total
                if replace {
                    items = resp.items               // 整体替换，不清空
                } else {
                    items.append(contentsOf: resp.items)
                }
                hasMore = (replace ? resp.items.count : items.count) < total
                error = ""
            } else {
                // 真的查完了才知道到底有没有下一页；这里仍有数据，保持 hasMore 不动
                error = resp.error ?? "查询失败"
            }
        } catch {
            guard myEpoch == epoch else { return }
            // 🔴 超时/网络失败 ≠ 数据加载完：绝不能动 hasMore，否则底部哨兵消失，
            // 之后下拉刷新就算成功也只有一页、再也没法自动翻页。只记错误，留重试入口。
            self.error = error.localizedDescription
        }
    }
}
