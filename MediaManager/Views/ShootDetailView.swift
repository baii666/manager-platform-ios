import SwiftUI

// MARK: - 拍摄集详情页
// 视频横滑轨(播放) + 照片瀑布流(看图器) + 无限滚动；信息全部收进导航栏。
// ⚠️ 2026-10-14 两次改版：
// 1. 从「全部/视频/照片 三段 tab」改成「视频横滑轨 + 照片瀑布流」—— 库里的
//    形状是每个拍摄集 1-2 个视频、100+ 张照片（全库 134 视频 vs 13900 照片），
//    视频不配占一个 tab；整页只有照片流一种滚动节奏
// 2. 去掉 172pt Hero 大图头 —— 照片是主体，进场就该直接看到网格；标题和
//    数量/体积/时长收进导航栏 principal（两行）
// 网页端 ShootDetailPage 仍是 tab + 大头图结构，待对齐。
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
            ScrollView {
                // 视频横滑轨。1-2 个视频时就是固定一行，横滑只为视频变多留余量；
                // 一个视频都没有时整节不渲染，不留空标题
                if !viewModel.videos.isEmpty {
                    videoStrip
                }

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
                        .padding(.top, viewModel.videos.isEmpty ? 12 : 18)
                } else if let e = viewModel.photoErrorMessage {
                    // 照片加载失败：明确说出来，不留一片空白让人以为是布局问题
                    VStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary)
                        Text("照片加载失败：\(e)")
                            .font(.caption).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity).padding(.top, 24)
                } else if !viewModel.videos.isEmpty {
                    // 有视频、没照片（库里有 3 个集是这样）：说清楚，别留白
                    Text("暂无照片")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(.top, 24)
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
        .navigationBarTitleDisplayMode(.inline)
        // 信息全部收进导航栏：第一行标题，第二行数量/体积/时长。
        // principal 顶掉 inline 标题，所以不再需要 navigationTitle
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 2) {
                    Text(shoot.displayTitle)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1).truncationMode(.tail)
                    infoRow
                }
            }
        }
        // ⚠️ 每个 tab / 每个 push 进来的页面都要自己垫一层背景：
        // NavigationStack 只渲染栈顶那一层，App 根的背景透不进来
        .appBackground()
        .task { await viewModel.loadInitial() }
        .fullScreenCover(item: $playTarget) { target in
            NavigationStack {
                // 标题优先用视频文件名（视频轨点进来时带上），回退拍摄集标题
                VideoPlayerView(url: target.url, title: target.title ?? shoot.displayTitle)
                    .toolbar { ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") { playTarget = nil }
                    } }
            }
        }
        // 看图器走全局 overlay（PhotoViewerPresenter），不再用 fullScreenCover
    }

    // MARK: 导航栏信息行

    /// 第二行：视频数 / 照片数 / 体积 / 时长。详情拉回来后用权威值
    /// （detail.videos.count / 后端 COUNT(*)），加载中才回退列表里带来的计数
    private var infoRow: some View {
        HStack(spacing: 8) {
            Label("\(viewModel.videos.isEmpty ? shoot.videoCount : viewModel.videos.count)",
                  systemImage: "film")
            Label("\(viewModel.photoTotal > 0 ? viewModel.photoTotal : shoot.photoCount)",
                  systemImage: "photo")
            if let size = formatSize(shoot.totalSize) {
                Label(size, systemImage: "internaldrive")
            }
            if shoot.totalDuration > 0 {
                Label(formatDuration(Int(shoot.totalDuration)), systemImage: "clock")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    // MARK: 视频横滑轨

    private var videoStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("视频").font(.headline)
                Text("\(viewModel.videos.count)")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(viewModel.videos) { file in
                        ShootVideoCard(file: file) {
                            if let url = client?.shootFileURL(file.id) {
                                playTarget = PlayerTarget(
                                    url: url,
                                    title: file.filename.strippingSitePrefix.deletingPathExtension)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.top, 14)
    }
}

// MARK: - 拍摄集详情 VM
final class ShootDetailViewModel: ObservableObject {
    let shoot: Shoot
    @Published var videos: [ShootFile] = []
    @Published var photos: [ShootFile] = []
    @Published var photoTotal = 0
    @Published var photoHasMore = false
    @Published var isLoading = false
    /// 照片加载失败原因。⚠️ 以前三处 catch 全吞掉，请求一失败就只剩一片空白，
    /// 看着和「布局塌了」一模一样，排障全靠猜 —— 现在至少把原因说出来。
    @Published var photoErrorMessage: String? = nil

    private var photoPage = 1
    private let photoSize = 50

    init(shoot: Shoot) {
        self.shoot = shoot
        // 先用列表里带来的 photo_count 顶上：第一页照片请求回来之前，
        // hero 统计胶囊里的照片数就已经是对的（后端 COUNT(*) 回来后覆盖）
        photoTotal = shoot.photoCount
    }

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
        // ⚠️ 必须先松锁再调 loadMorePhotos：它的 guard 里有 !isLoading，
        // 父任务攥着 flag 不退，子任务永远被挡在门外 —— 照片请求根本发不出去，
        // 页面安安静静一片空白（下拉刷新不走这条路径所以看着「拉一下才有」）。
        isLoading = false
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
            let page = try await client.fetchShootPhotos(id: shoot.id, page: photoPage, size: photoSize)
            let existing = Set(photos.map { $0.id })
            photos.append(contentsOf: page.photos.filter { !existing.contains($0.id) })
            // 总数用后端 COUNT(*)；后端给出 0（不该发生）才退回已加载数
            if page.total > 0 { photoTotal = page.total }
            photoPage += 1
            // 两个信号取或：总数没到底，或这一页是满的（后端 COUNT 偶尔比实际少，
            // 满页就再要一页，空页自然收尾）
            photoHasMore = photos.count < photoTotal || page.photos.count >= photoSize
            photoErrorMessage = nil
        } catch {
            photoErrorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

// MARK: - 视频横滑卡
private struct ShootVideoCard: View {
    let file: ShootFile
    /// 卡宽。约屏宽 60%：一屏露出一个半，暗示可以横滑
    var width: CGFloat = 232
    var onPlay: () -> Void

    var body: some View {
        Button(action: onPlay) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    // 后端没有视频抽帧端点（shoot_files.has_thumb 也未生成），
                    // 用品牌渐变 + 播放键占位，16:9 比例先摆正
                    LinearGradient(colors: Theme.placeholderGradient(for: .shoot),
                                   startPoint: .top, endPoint: .bottom)
                    Image(systemName: "play.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: width, height: width * 9 / 16)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(alignment: .bottomTrailing) {
                    // 时长徽标：黑底白字，亮暗封面都可读
                    if let d = file.durationText {
                        Text(d)
                            .font(.caption2.weight(.medium)).monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(.black.opacity(0.55), in: Capsule())
                            .padding(6)
                    }
                }

                Text(file.filename.strippingSitePrefix.deletingPathExtension)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(width: width, alignment: .leading)
            }
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
