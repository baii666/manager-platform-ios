import SwiftUI

// MARK: - 拍摄集详情页
// 对齐网页端 ShootDetailPage：Hero 封面头 + Tab(全部/视频/照片) + 视频列表(播放)
// + 照片瀑布流(看图器) + 无限滚动。
struct ShootDetailView: View {
    let shoot: Shoot

    @StateObject private var viewModel: ShootDetailViewModel
    /// 同 ShortsView：地址挂 item 上，不用 isPresented + 分离 URL 状态
    @State private var playTarget: PlayerTarget?
    /// 照片瀑布流列数：双指捏合缩放，按「拍摄集照片」记忆
    @State private var photoColumns = PhotoGridPrefs.load("shootPhotos", fallback: 3)

    private var client: APIClient? { AppSession.shared.client }

    init(shoot: Shoot) {
        self.shoot = shoot
        _viewModel = StateObject(wrappedValue: ShootDetailViewModel(shoot: shoot))
    }

    var body: some View {
        VStack(spacing: 0) {
            heroHeader

            Picker("内容", selection: $viewModel.activeTab) {
                Text("全部 (\(viewModel.totalCount))").tag(ShootDetailViewModel.Tab.all)
                Text("视频 (\(viewModel.videos.count))").tag(ShootDetailViewModel.Tab.videos)
                Text("照片 (\(viewModel.photoTotal))").tag(ShootDetailViewModel.Tab.photos)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)

            ScrollView {
                if viewModel.activeTab == .videos || viewModel.activeTab == .all {
                    if !viewModel.videos.isEmpty {
                        LazyVStack(spacing: 8) {
                            ForEach(viewModel.videos) { file in
                                ShootVideoRow(file: file) {
                                    if let url = client?.shootFileURL(file.id) {
                                        playTarget = PlayerTarget(url: url)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }

                if viewModel.activeTab == .photos || viewModel.activeTab == .all {
                    if !viewModel.photos.isEmpty {
                        // ⚠️ fitsContent 必须按 PhotoGrid 的声明顺序传（onColumnsChange
                        // 等闭包参数之前）—— Swift 不允许实参乱序
                        PhotoGrid(photos: viewModel.viewerPhotos, columns: photoColumns,
                                  fitsContent: true,
                                  onColumnsChange: { photoColumns = $0; PhotoGridPrefs.save("shootPhotos", $0) },
                                  onSelect: { photo in
                            guard let idx = viewModel.viewerPhotos.firstIndex(where: { $0.id == photo.id }) else { return }
                            PhotoViewerPresenter.shared.show(
                                viewModel.viewerPhotos, index: idx,
                                hasMore: viewModel.photoHasMore, onLoadMore: {
                                    Task {
                                        await viewModel.loadMorePhotos()
                                        PhotoViewerPresenter.shared.updatePhotos(viewModel.viewerPhotos)
                                    }
                                })
                        }, onReachEnd: {
                            Task { await viewModel.loadMorePhotos() }
                        })
                            // 🔧 fitsContent：UICollectionView 没有 intrinsicContentSize，
                            // 直接塞 ScrollView 高度会塌成 0 —— 照片整块不显示的根因。
                            // 开启后网格不自己滚，高度=内容总高，由外层 ScrollView 统管。
                            .padding(.horizontal, 16)
                    }
                }

                if viewModel.isLoading {
                    ProgressView().frame(maxWidth: .infinity).padding()
                }
                if viewModel.photos.isEmpty && viewModel.videos.isEmpty && !viewModel.isLoading {
                    ContentUnavailableView("暂无内容", systemImage: "photo.on.rectangle.angled")
                        .padding(.top, 60)
                }

                // 底部净空：滑到底时最后的内容不被底栏盖住
                Spacer().frame(height: BottomTabBar.height)
            }
            .refreshable { await viewModel.refresh() }
        }
        .navigationTitle(shoot.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        // ⚠️ 每个 tab / 每个 push 进来的页面都要自己垫一层背景：
        // NavigationStack 只渲染栈顶那一层，App 根的背景透不进来
        .appBackground()
        .task { await viewModel.loadInitial() }
        .fullScreenCover(item: $playTarget) { target in
            NavigationStack {
                VideoPlayerView(url: target.url, title: shoot.displayTitle)
                    .toolbar { ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") { playTarget = nil }
                    } }
            }
        }
        // 看图器走全局 overlay（PhotoViewerPresenter），不再用 fullScreenCover
    }

    // MARK: Hero 封面头

    /// 封面大图 + 底部渐变 + 标题 + 统计胶囊。没有封面时 RemoteImage 自己出
    /// 渐变占位，布局不变。
    private var heroHeader: some View {
        ZStack(alignment: .bottomLeading) {
            RemoteImage(url: client?.shootCoverURL(shoot.id, size: 900),
                        fallbackIcon: "photo.on.rectangle.angled",
                        fallbackColors: Theme.placeholderGradient(for: .shoot))
                .imageFilled()
                .frame(height: 172)
                .clipped()
            // 底部压暗，保证白字在亮封面上也可读
            LinearGradient(colors: [.clear, .black.opacity(0.72)],
                           startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 6) {
                Text(shoot.displayTitle)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .shadow(color: .black.opacity(0.5), radius: 4, y: 1)
                HStack(spacing: 8) {
                    statChip("film", "\(shoot.videoCount)")
                    statChip("photo", "\(shoot.photoCount)")
                    if let size = formatSize(shoot.totalSize) { statChip("internaldrive", size) }
                    if shoot.totalDuration > 0 {
                        statChip("clock", formatDuration(Int(shoot.totalDuration)))
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .frame(height: 172)
        .clipped()
    }

    private func statChip(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10))
            Text(text).font(.caption2.weight(.medium)).monospacedDigit()
        }
        .foregroundStyle(.white.opacity(0.92))
        .padding(.horizontal, 7).padding(.vertical, 4)
        .background(.black.opacity(0.35), in: Capsule())
    }
}

// MARK: - 拍摄集详情 VM
final class ShootDetailViewModel: ObservableObject {
    enum Tab: Hashable { case all, videos, photos }

    let shoot: Shoot
    @Published var activeTab: Tab = .all
    @Published var videos: [ShootFile] = []
    @Published var photos: [ShootFile] = []
    @Published var photoTotal = 0
    @Published var photoHasMore = false
    @Published var isLoading = false

    private var photoPage = 1
    private let photoSize = 50

    init(shoot: Shoot) { self.shoot = shoot }

    var totalCount: Int { videos.count + photoTotal }

    /// 把照片 ShootFile 适配成 Photo 供看图器使用
    var viewerPhotos: [Photo] {
        photos.map { f in
            var p = Photo(id: f.id)
            p.thumbURL = AppSession.shared.client?.shootPhotoURL(f.id, size: 600)
            p.fullURL = AppSession.shared.client?.shootPhotoURL(f.id)
            p.width = f.width
            p.height = f.height
            p.fileSize = f.fileSize
            p.fileName = f.filename
            return p
        }
    }

    @MainActor
    func loadInitial() async {
        guard let client = AppSession.shared.client else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let detail = try await client.fetchShootDetail(id: shoot.id)
            videos = detail.videos
        } catch {}
        await loadMorePhotos()
    }

    /// 下拉刷新：重置照片分页重新拉（视频列表一起更新）
    @MainActor
    func refresh() async {
        photoPage = 1
        photos = []
        photoHasMore = false
        do {
            if let client = AppSession.shared.client {
                let detail = try await client.fetchShootDetail(id: shoot.id)
                videos = detail.videos
            }
        } catch {}
        await loadMorePhotos()
    }

    @MainActor
    func loadMorePhotos() async {
        guard let client = AppSession.shared.client, !isLoading, photoHasMore || photoPage == 1 else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let batch = try await client.fetchShootPhotos(id: shoot.id, page: photoPage, size: photoSize)
            let existing = Set(photos.map { $0.id })
            photos.append(contentsOf: batch.filter { !existing.contains($0.id) })
            photoTotal = photos.count // 后端未返回总页，用已加载数 + hasMore 近似
            photoPage += 1
            photoHasMore = !batch.isEmpty
        } catch {}
    }
}

// MARK: - 视频行
private struct ShootVideoRow: View {
    let file: ShootFile
    var onPlay: () -> Void

    var body: some View {
        Button(action: onPlay) {
            HStack(spacing: 12) {
                // 16:9 缩略位。后端没有视频抽帧端点（shoot_files.has_thumb 也未生成），
                // 用品牌渐变 + 播放键占位，比例先摆正
                ZStack {
                    LinearGradient(colors: Theme.placeholderGradient(for: .shoot),
                                   startPoint: .top, endPoint: .bottom)
                    Image(systemName: "play.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 96, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    // 文件名同样剥掉站点前缀、去掉扩展名，短一半才好读
                    Text(file.filename.strippingSitePrefix.deletingPathExtension)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1).truncationMode(.tail)
                    HStack(spacing: 8) {
                        if let d = file.durationText {
                            Label(d, systemImage: "clock").font(.caption2)
                        }
                        if let dim = file.dimensionText {
                            Text(dim).font(.caption2)
                        }
                        Text(file.sizeText).font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .appSurface(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.separator))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 字符串清理
extension String {
    /// 剥掉站点目录名前缀："www.98T.la@蜃楼-02E4K MP4.mp4" → "蜃楼-02E4K MP4.mp4"。
    /// 规则保守：第一个 @ 左边「含点且不含空格」才剥，正常文案原样返回。
    var strippingSitePrefix: String {
        guard let at = firstIndex(of: "@"), at > startIndex else { return self }
        let prefix = self[startIndex..<at]
        guard prefix.contains(".") && !prefix.contains(" ") else { return self }
        return String(self[index(after: at)...])
    }

    /// 去扩展名（"a.mp4" → "a"）。Foundation 的 deletingPathExtension 在纯 Swift
    /// 环境可用（NSString 桥接），这里包一层只为调用点读起来顺口
    var deletingPathExtension: String {
        (self as NSString).deletingPathExtension
    }
}
