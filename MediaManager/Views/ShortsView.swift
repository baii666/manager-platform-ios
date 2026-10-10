import SwiftUI

// MARK: - 短视频页
// 对齐网页端 ShortsPage（消费侧）：池筛选 + 搜索 + 封面墙 + 点开播放
struct ShortsView: View {
    @StateObject private var viewModel = ShortsViewModel()
    @State private var playing = false
    @State private var playingURL: URL?

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    var body: some View {
        ScrollView {
            if viewModel.items.isEmpty && !viewModel.isLoading {
                ContentUnavailableView(viewModel.errorMessage ?? "暂无短视频",
                                       systemImage: viewModel.errorMessage == nil ? "play.rectangle.fill" : "exclamationmark.triangle")
                    .frame(maxWidth: .infinity, minHeight: 400)
            } else {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(viewModel.items) { v in
                        ShortCard(video: v, client: viewModel.client) {
                            if let path = v.filePath,
                               let url = viewModel.client?.makeURL("/stream", queryItems: [URLQueryItem(name: "path", value: path)]) {
                                playingURL = url; playing = true
                            }
                        }
                        .task {
                            if v.id == viewModel.items.last?.id { await viewModel.loadMore() }
                        }
                    }
                }
                .padding(16)
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
        .onChange(of: viewModel.searchText) { _ in
            Task {
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled else { return }
                await viewModel.reload()
            }
        }
        .task { await viewModel.loadInitial() }
        .fullScreenCover(isPresented: $playing) {
            if let playingURL {
                NavigationStack {
                    VideoPlayerView(url: playingURL, title: "短视频")
                        .toolbar { ToolbarItem(placement: .cancellationAction) {
                            Button("关闭") { playing = false }
                        } }
                }
            }
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

// MARK: - 短视频封面卡（3:4）
private struct ShortCard: View {
    let video: ShortVideo
    let client: APIClient?
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
                        .aspectRatio(3.0 / 4.0, contentMode: .fill)
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
                    .padding(.horizontal, 8).padding(.vertical, 6)
            }
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.separator))
        }
        .buttonStyle(.plain)
    }
}
