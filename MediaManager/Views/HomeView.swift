import SwiftUI
import UIKit

// MARK: - 首页
// 信息架构对齐现有 Web 端 HomePageV3 的消费视角：
// 搜索 + 统计 → 继续观看 → 我的收藏 → 最近入库 → 发现
struct HomeView: View {
    @ObservedObject var viewModel: HomeViewModel

    /// 点开之后交给 PlayerHostView 去拿地址：它自己会立刻全屏并把等待过程摊开给人看
    @State private var pending: PlaybackRequest?
    /// 点开却拿不到播放地址时给出明确原因，而不是「点了没反应」
    @State private var playError: String?
    @State private var showingPhotos = false
    @State private var showingAlbums = false
    @State private var showingTasks = false
    @State private var showingSearch = false
    @StateObject private var taskViewModel = TaskProgressViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                hero
                if !viewModel.failures.isEmpty { errorBanner }
                if !viewModel.resume.isEmpty { resumeSection }
                if !viewModel.favorites.isEmpty { favoritesSection }
                if !viewModel.recent.isEmpty { recentSection }
                discoverSection
            }
            .padding(.vertical, 24)
            .padding(.horizontal, 24)
        }
        .background(Color(uiColor: .systemBackground))
        .navigationTitle("首页")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if viewModel.stats.libraryCount == 0 {
                await viewModel.load()
            }
        }
        .overlay {
            if viewModel.isLoading {
                ProgressView("加载中…")
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingTasks = true
                } label: {
                    Label("任务", systemImage: "gearshape.2")
                }
            }
        }
        .sheet(isPresented: $showingTasks) {
            NavigationStack {
                TaskProgressView(viewModel: taskViewModel)
                    .navigationTitle("任务进度")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { showingTasks = false }
                        }
                    }
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showingPhotos) {
            NavigationStack {
                PhotoBrowserView()
            }
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
        .sheet(isPresented: $showingSearch) {
            NavigationStack {
                SearchView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { showingSearch = false }
                        }
                    }
            }
        }
        .alert("无法播放", isPresented: Binding(
            get: { playError != nil },
            set: { if !$0 { playError = nil } }
        )) {
            Button("好", role: .cancel) { playError = nil }
        } message: {
            Text(playError ?? "")
        }
        .fullScreenCover(item: $pending) { request in
            PlayerHostView(request: request)
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
                semantic: $viewModel.semanticSearch,
                onSubmit: {
                    Task {
                        await viewModel.performSearch()
                        showingSearch = true
                    }
                }
            )
            .frame(maxWidth: 640)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                ForEach(statEntries) { entry in
                    StatCard(icon: entry.icon, label: entry.label, value: entry.value, tint: entry.tint, action: entry.action)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    // MARK: 继续观看

    private var resumeSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(icon: "clock.fill", title: "继续观看")
            horizontalRow {
                ForEach(viewModel.resume) { asset in
                    ResumeCard(asset: asset) {
                        handleAssetTap(asset)
                    }
                }
            }
        }
    }

    // MARK: 我的收藏

    private var favoritesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(icon: "heart.fill", title: "我的收藏")
            horizontalRow {
                ForEach(viewModel.favorites) { asset in
                    AssetPosterCard(asset: asset) {
                        handleAssetTap(asset)
                    }
                }
            }
        }
    }

    // MARK: 最近入库

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(icon: "bolt.fill", title: "最近入库")
            horizontalRow {
                ForEach(viewModel.recent) { item in
                    RecentPosterCard(item: item)
                }
            }
        }
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

    private func handleAssetTap(_ asset: UnifiedAsset) {
        guard let path = asset.playablePath else {
            if asset.type == .photo {
                showingPhotos = true
            } else {
                playError = "《\(asset.title)》没有可播放的文件路径"
            }
            return
        }
        // 只负责把「要播什么」交出去，不做任何网络请求。
        // 拿地址的等待由 PlayerHostView 接手，它一弹出就有片名和进度反馈。
        pending = PlaybackRequest(path: path,
                                  title: asset.title,
                                  assetType: asset.type.rawValue,
                                  assetID: asset.id,
                                  startAt: asset.position,
                                  knownDuration: asset.duration)
    }

    /// 统一的行容器：继续观看 / 收藏 / 最近入库都用它，卡片各自固定尺寸，不再铺满多行
    @ViewBuilder
    private func horizontalRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 16, content: content)
                .padding(.horizontal, 2)
                .padding(.vertical, 2)
        }
    }

    // MARK: 统计配置

    private var statEntries: [StatEntry] {
        [
            StatEntry(id: "lib", icon: "folder.fill", label: "媒体库", value: viewModel.stats.libraryCount, tint: Theme.brand),
            StatEntry(id: "movie", icon: "film", label: "电影", value: viewModel.stats.movieCount, tint: .blue),
            StatEntry(id: "series", icon: "tv", label: "剧集", value: viewModel.stats.seriesCount, tint: .purple),
            StatEntry(id: "photo", icon: "camera", label: "图片", value: viewModel.stats.photoCount, tint: .green) {
                showingAlbums = true
            },
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
