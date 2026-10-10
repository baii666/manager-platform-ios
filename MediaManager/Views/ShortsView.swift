import SwiftUI

// MARK: - 短视频页
// 对齐网页端 ShortsPage（消费侧）：池筛选 + 搜索 + 封面墙 + 点开播放
struct ShortsView: View {
    @StateObject private var viewModel = ShortsViewModel()
    /// 播放目标。地址直接挂在 item 上，避免 isPresented + 分离 URL 状态不同步
    @State private var playTarget: PlayerTarget?
    /// 播放地址构造失败时给出明确原因，而不是静默什么都不发生
    @State private var playError: String?

    private let gridSpacing: CGFloat = 12
    private let edgePadding: CGFloat = 16
    /// 封面高度写死成常量，不跟列宽挂钩。
    ///
    /// 短视频封面是 FFmpeg 抽帧，横屏 1920×1080 / 竖屏 1080×1920 / 4K 混在一起，
    /// 尺寸完全没有统一标准。只要行高还会随内容变（列宽测量、图片加载完成），
    /// LazyVGrid 就不会重算已布局的行 —— 表现就是卡片互相压住。
    /// 所以这里连列宽都不自己量，改用 adaptive 交给系统，高度保持常量。
    private let coverHeight: CGFloat = 240
    /// 标题区高度也写死，让整卡高度成为常量
    private let titleHeight: CGFloat = 28

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 160, maximum: 220), spacing: gridSpacing)]
    }

    var body: some View {
        ScrollView {
            if viewModel.items.isEmpty && !viewModel.isLoading {
                ContentUnavailableView(viewModel.errorMessage ?? "暂无短视频",
                                       systemImage: viewModel.errorMessage == nil ? "play.rectangle.fill" : "exclamationmark.triangle")
                    .frame(maxWidth: .infinity, minHeight: 400)
            } else {
                LazyVGrid(columns: columns, spacing: gridSpacing) {
                    ForEach(viewModel.items) { v in
                        ShortCard(video: v, client: viewModel.client,
                                  coverHeight: coverHeight,
                                  titleHeight: titleHeight,
                                  cardHeight: coverHeight + titleHeight) {
                            guard let path = v.filePath, !path.isEmpty else {
                                playError = "这条记录没有文件路径"
                                return
                            }
                            // streamURL 会按容器分流：mp4/mov 直连，avi/mkv 等走 remux
                            guard let url = viewModel.client?.streamURL(path: path) else {
                                playError = "播放地址构造失败\n\(path)"
                                return
                            }
                            playTarget = PlayerTarget(url: url)
                        }
                        .task {
                            if v.id == viewModel.items.last?.id { await viewModel.loadMore() }
                        }
                    }
                }
                .padding(edgePadding)
                if viewModel.isLoading {
                    ProgressView().frame(maxWidth: .infinity).padding()
                }
            }
        }
        .navigationTitle("短视频")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $viewModel.searchText, prompt: "搜索文件名…")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { Task { await viewModel.selectPool(nil) } } label: {
                        if viewModel.selectedPoolID == nil { Label("全部池", systemImage: "checkmark") }
                        else { Text("全部池") }
                    }
                    ForEach(viewModel.pools) { pool in
                        Button { Task { await viewModel.selectPool(pool.id) } } label: {
                            if pool.id == viewModel.selectedPoolID { Label(pool.name, systemImage: "checkmark") }
                            else { Text(pool.name) }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(viewModel.selectedPoolName)
                            .font(.subheadline.weight(.medium))
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(Theme.brand)
                }
            }
        }
        // ⚠️ iOS 17 起 `onChange(of:) { newValue in }`（单参数）已废弃，用零参数闭包
        .onChange(of: viewModel.searchText) {
            Task {
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled else { return }
                await viewModel.reload()
            }
        }
        .task { await viewModel.loadInitial() }
        .fullScreenCover(item: $playTarget) { target in
            NavigationStack {
                VideoPlayerView(url: target.url, title: "短视频")
                    .toolbar { ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") { playTarget = nil }
                    } }
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
    }
}

// MARK: - 短视频 VM
final class ShortsViewModel: ObservableObject {
    @Published var items: [ShortVideo] = []
    @Published var pools: [ShortPool] = []
    @Published var selectedPoolID: Int?
    @Published var searchText = ""
    @Published var totalCount = 0
    @Published var isLoading = false
    @Published var errorMessage: String?

    var client: APIClient? { AppSession.shared.client }
    var selectedPoolName: String {
        if let id = selectedPoolID, let p = pools.first(where: { $0.id == id }) { return p.name }
        return "全部池"
    }

    private var page = 1
    private let pageSize = 60
    private var hasMore = true

    @MainActor
    func loadInitial() async {
        guard let client else { errorMessage = "未连接服务器"; return }
        do { pools = try await client.fetchShortPools() } catch { pools = [] }
        // 同 AlbumListView：从详情返回本页时 .task 可能重跑，此时 reload 会清空 items
        // 让 ScrollView 弹回顶部。已有数据就跳过，保住滚动位置。
        // 搜索 / 切换合集仍各自直接调 reload()，不受影响。
        guard items.isEmpty else { return }
        await reload()
    }

    @MainActor
    func selectPool(_ id: Int?) async {
        selectedPoolID = id
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
            let (batch, total) = try await client.fetchShortVideos(
                poolId: selectedPoolID, page: page, size: pageSize,
                q: searchText.isEmpty ? nil : searchText)
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

// MARK: - 短视频封面卡（高度全常量：封面 coverHeight + 标题 titleHeight）
private struct ShortCard: View {
    let video: ShortVideo
    let client: APIClient?
    let coverHeight: CGFloat
    let titleHeight: CGFloat
    let cardHeight: CGFloat
    var onTap: () -> Void

    private var poster: URL? {
        guard let raw = video.posterUrl, let u = URL(string: raw) else { return nil }
        return client?.resolve(u) ?? u
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .bottomLeading) {
                    RemoteImage(url: poster, fallbackIcon: "play.rectangle.fill",
                                fallbackColors: Theme.placeholderGradient(for: .short))
                        // imageFilled 把图片钉死在容器尺寸里，杜绝按原图像素渲染
                        .imageFilled()
                        .frame(height: coverHeight)
                        .frame(maxWidth: .infinity)
                        .clipped()
                    LinearGradient(colors: [.clear, .black.opacity(0.75)],
                                  startPoint: .top, endPoint: .bottom)
                        .frame(height: 70)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .clipped()
                    VStack(alignment: .leading, spacing: 2) {
                        if let dur = video.durationText {
                            HStack(spacing: 4) {
                                Image(systemName: "play.fill").font(.system(size: 9))
                                Text(dur).font(.caption2).monospacedDigit()
                            }
                            .foregroundStyle(.white)
                        }
                        if let dim = video.dimensionText {
                            Text(dim).font(.caption2).foregroundStyle(.white.opacity(0.7))
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)

                    // 封面状态徽章
                    HStack(spacing: 4) {
                        if video.hasPreview {
                            Text("动态").font(.system(size: 9)).fontWeight(.medium)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(.blue.opacity(0.85), in: Capsule())
                        } else if video.hasPoster {
                            Text("静态").font(.system(size: 9))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(.black.opacity(0.6), in: Capsule())
                        } else {
                            Text("无封面").font(.system(size: 9))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(.red.opacity(0.8), in: Capsule())
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                Text(video.titleText)
                    .font(.caption)
                    .lineLimit(1).truncationMode(.tail)
                    .padding(.horizontal, 8)
                    .frame(height: titleHeight, alignment: .leading)
            }
            // 整卡高度也钉死：LazyVGrid 行高是「首帧测出来就固定」的，
            // 只要高度有任何变化（图片加载完成、列宽重算）都不会重排 → 卡片压在一起
            .frame(height: cardHeight, alignment: .top)
            .clipped()
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.separator))
        }
        .buttonStyle(.plain)
    }
}
