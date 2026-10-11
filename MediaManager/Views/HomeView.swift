import SwiftUI
import UIKit

// MARK: - 首页
// 信息架构对齐现有 Web 端 HomePageV3 的消费视角：搜索 + 统计 → 最近入库 → 发现。
// ⚠️「继续观看 / 我的收藏 / 观看记录」已挪到「我的」tab（MineView），首页只管找内容。
struct HomeView: View {
    @ObservedObject var viewModel: HomeViewModel
    @Environment(\.horizontalSizeClass) private var hSizeClass

    @State private var showingPhotos = false
    @State private var showingAlbums = false
    @State private var showingSearch = false
    @State private var selectedRecent: RecentItem?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                hero
                if !viewModel.failures.isEmpty { errorBanner }
                if !viewModel.recent.isEmpty { recentSection }
                discoverSection
            }
            .padding(.vertical, 24)
            .padding(.horizontal, 24)
            // 底部留出底栏高度，滑到底不被底栏盖住
            .bottomBarClearance()
        }
        // ⚠️ 关掉内容触摸延迟：ScrollView 为了区分「点 TextField」和「开始滚动」，
        // 默认会 `delaysContentTouches`（等手势判定完才把触摸交给子控件），
        // 这就是「点搜索框要等 1s 键盘才弹」的根因 —— 在 iPad 上尤其明显。
        .fixDelaysContentTouches()
        .appBackground()
        .navigationTitle("首页")
        .navigationBarTitleDisplayMode(.inline)
        // 下拉刷新（不显示 loading 遮罩，避免触发 refreshable 取消）
        .refreshable { await viewModel.load(showSpinner: false) }
        .task {
            // 与「我的」tab 共用同一份 viewModel，闸在 HomeViewModel 里，不会重复拉
            await viewModel.loadIfNeeded()
        }
        .overlay {
            if viewModel.isLoading {
                ProgressView("加载中…")
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        // 随机照片：push 进全屏页面，不再用 sheet。
        // 与搜索同理 —— push 后底层首页始终在层级里渲染，全局看图器 overlay 可见，
        // 点开大图退出时露出的是照片页本身，不会像 sheet 那样盖住全局 overlay。
        .navigationDestination(isPresented: $showingPhotos) {
            PhotoBrowserView()
        }
        .sheet(isPresented: $showingAlbums) {
            NavigationStack {
                AlbumListView()
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { showingAlbums = false }
                        }
                    }
            }
        }
        // ⚠️ 搜索是核心功能：push 进**全屏页面**，不再用 sheet。
        // 两个原因：① sheet 是卡片式半屏，搜索结果多时空间不够；
        // ② sheet 是 present 出来的层级，会盖住 RootView 最外层的全局看图器 overlay，
        //    照片只能退回本页 fullScreenCover → 退出时底层页面被移出窗口层级，闪白屏。
        // push 之后底层的首页始终在层级里渲染，看图器退出露出的就是搜索结果页本身。
        .navigationDestination(isPresented: $showingSearch) {
            SearchView(initialQuery: viewModel.searchText, semantic: viewModel.semanticSearch)
        }
        // 最近入库卡片 → 详情页（电影/剧集 → 影视详情；相册 → 相册照片页）
        .navigationDestination(item: $selectedRecent) { item in
            switch item.kind {
            case .movie, .series:
                MediaDetailView(media: MediaItem(
                    id: item.id,
                    title: item.title,
                    year: item.year,
                    type: item.kind.rawValue,
                    posterImageId: item.posterImageId,
                    fanartImageId: item.fanartImageId,
                    libraryId: item.libraryId
                ))
            case .album:
                AlbumPhotosView(album: albumForRecent(item), libID: item.libraryId)
            }
        }
    }

    // MARK: 失败提示
    // 之前接口报错被静默吞掉，只表现为「页面全空」，无法判断是地址错、401 还是字段不匹配

    private var errorBanner: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("部分数据加载失败", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)

            ForEach(viewModel.failures, id: \.self) { item in
                Text("· \(item)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if let base = AppSession.shared.baseURL {
                Text("服务器：\(base.absoluteString)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Button("重试") { Task { await viewModel.load() } }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.orange.opacity(0.12),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }

    // MARK: Hero：搜索 + 统计

    private var hero: some View {
        VStack(spacing: 20) {
            VStack(spacing: 6) {
                Text("想看什么？")
                    .font(.largeTitle.weight(.bold))
                Text("影视、写真、短视频、拍摄集 —— 一个搜索框全部找到")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            SearchBar(
                text: $viewModel.searchText,
                onSubmit: {
                    // ⚠️ 直接跳转，**不再 await performSearch()**：
                    // 之前是「先跑完一整次搜索请求，等它回来才 push」，这就是
                    // 「首页搜完要等半天才跳到搜索页」的根因。
                    // 而且这一次请求纯属浪费 —— 首页并不展示搜索结果，
                    // SearchView 进去会用 initialQuery 自己再搜一次。
                    guard !viewModel.searchText
                        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    showingSearch = true
                }
            )
            .frame(maxWidth: 640)

            // 统计卡：横屏固定 5 列（1 行铺满）；竖屏 5 个卡片若用网格会 3+2 参差，
            // 改成横向滚动一行（每个卡固定宽度，左右滑）。
            statGrid
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .appSurface(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    // MARK: 继续观看 / 我的收藏 / 观看记录
    // ⚠️ 这三个区块已经挪到「我的」tab（MineView）—— 它们是私人数据，
    // 首页回到「找内容」的定位。viewModel 仍然一次性把它们拉好，两边共用。

    // MARK: 最近入库

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(icon: "bolt.fill", title: "最近入库")
            horizontalRow {
                ForEach(viewModel.recent) { item in
                    RecentPosterCard(item: item) {
                        selectedRecent = item
                    }
                }
            }
        }
    }

    /// 由「最近入库」的相册条目构造 Album：后端 /api/recent 不返回相册的
    /// folder_path / cover 等完整字段，但 AlbumPhotosView 只需 id（拉照片）+ title（标题），
    /// 其余用占位，标题靠 displayName 回填。
    private func albumForRecent(_ item: RecentItem) -> Album {
        var album = Album(id: item.id)
        album.displayName = item.title
        return album
    }

    // MARK: 发现

    private var discoverSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(icon: "sparkles", title: "发现")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                DiscoverCard(icon: "shuffle", title: "随机照片", subtitle: "从图库里随便逛", tint: .green) {
                    showingPhotos = true
                }
                DiscoverCard(icon: "person.2.fill", title: "人物", subtitle: "人脸聚类结果", tint: .cyan)
                DiscoverCard(icon: "photo.on.rectangle.angled", title: "拍摄集", subtitle: "按拍摄批次浏览", tint: .pink)
                DiscoverCard(icon: "play.rectangle.fill", title: "短视频连播", subtitle: "刷起来停不下", tint: .orange)
            }
        }
    }

    // MARK: 交互

    /// 统一的行容器：卡片各自固定尺寸，横向滚动
    @ViewBuilder
    private func horizontalRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 16, content: content)
                .padding(.horizontal, 2)
                .padding(.vertical, 2)
        }
    }

    // MARK: 统计配置

    /// 统计卡布局：横屏 4 列网格（1 行铺满）；竖屏 2 列网格（2×2 整齐）。
    @ViewBuilder
    private var statGrid: some View {
        LazyVGrid(columns: statColumns, spacing: 12) {
            ForEach(statEntries) { entry in
                StatCard(icon: entry.icon, label: entry.label, value: entry.value,
                         tint: entry.tint, action: entry.action)
            }
        }
    }

    /// 统计卡列数：横屏 4 列（1 行），竖屏 2 列（2×2）
    private var statColumns: [GridItem] {
        let count = hSizeClass == .compact ? 2 : 4
        return Array(repeating: GridItem(.flexible(), spacing: 12), count: count)
    }

    private var statEntries: [StatEntry] {
        [
            StatEntry(id: "movie", icon: "film", label: "电影", value: viewModel.stats.movieCount, tint: .blue),
            StatEntry(id: "photo", icon: "camera", label: "图片", value: viewModel.stats.photoCount, tint: .green),
            StatEntry(id: "shoot", icon: "photo.on.rectangle.angled", label: "拍摄集", value: viewModel.stats.shootCount, tint: .pink),
            StatEntry(id: "short", icon: "play.rectangle.fill", label: "短视频", value: viewModel.stats.shortCount, tint: .orange),
        ]
    }
}

private struct StatEntry: Identifiable {
    let id: String
    let icon: String
    let label: String
    let value: Int
    let tint: Color
    var action: (() -> Void)? = nil
}
