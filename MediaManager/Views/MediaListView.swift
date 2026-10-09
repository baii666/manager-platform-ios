import SwiftUI

// MARK: - 影视列表状态
// 对齐网页端 MediaListPage：不传 lib，后端返回用户可见媒体库的全集
final class MediaListViewModel: ObservableObject {
    let type: String

    @Published var items: [MediaItem] = []
    @Published var totalCount = 0
    @Published var isLoading = false
    @Published var errorMessage: String?

    private var page = 1
    private let pageSize = 60
    private var hasMore = true

    private var client: APIClient? { AppSession.shared.client }

    init(type: String) {
        self.type = type
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
            let (batch, total) = try await client.fetchMedia(type: type, page: page, size: pageSize)
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

// MARK: - 影视列表页（电影 / 剧集通用）
struct MediaListView: View {
    let type: String

    @StateObject private var viewModel: MediaListViewModel
    @State private var playing: (url: URL, title: String)?

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 18)]

    init(type: String) {
        self.type = type
        _viewModel = StateObject(wrappedValue: MediaListViewModel(type: type))
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 18) {
                ForEach(viewModel.items) { item in
                    let resolved = AppSession.shared.client?.resolveMedia(item)
                    let cover: URL? = resolved?.cover ?? nil
                    let playback: URL? = resolved?.playback ?? nil
                    MediaCard(item: item, coverURL: cover) {
                        if let url = playback {
                            playing = (url, item.title)
                        }
                    }
                    .task {
                        if item.id == viewModel.items.last?.id {
                            await viewModel.loadMore()
                        }
                    }
                }
            }
            .padding(24)
            if viewModel.isLoading {
                ProgressView().frame(maxWidth: .infinity).padding()
            }
        }
        .navigationTitle(type == "tv" ? "剧集" : "电影")
        .overlay {
            if viewModel.items.isEmpty && !viewModel.isLoading {
                ContentUnavailableView(
                    viewModel.errorMessage ?? "暂无内容",
                    systemImage: viewModel.errorMessage == nil ? "film" : "exclamationmark.triangle"
                )
            }
        }
        .task { await viewModel.reload() }
        .fullScreenCover(item: Binding(
            get: { playing.map { PlaybackItem(url: $0.url, title: $0.title) } },
            set: { newValue in
                if newValue == nil { playing = nil }
            }
        )) { item in
            NavigationStack {
                VideoPlayerView(url: item.url, title: item.title)
            }
        }
    }
}

/// fullScreenCover 需要 Identifiable，这里把播放目标包一层
private struct PlaybackItem: Identifiable, Hashable {
    let url: URL
    let title: String
    var id: String { url.absoluteString }
}

// MARK: - 影视卡
struct MediaCard: View {
    let item: MediaItem
    var coverURL: URL?
    var width: CGFloat = 150
    var onTap: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            RemoteImage(
                url: coverURL,
                fallbackIcon: item.type == "tv" ? "tv" : "film",
                fallbackColors: Theme.placeholderGradient(for: .media)
            )
            .frame(width: width, height: width * 3.0 / 2.0)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)

            Text(item.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            if !item.subtitle.isEmpty {
                Text(item.subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: width)
    }
}
