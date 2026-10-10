import SwiftUI
import UIKit

// MARK: - 影视列表状态
// 对齐网页端 MediaListPage：selectedLibID 为 nil 时不传 lib，后端返回用户可见媒体库的全集
final class MediaListViewModel: ObservableObject {
    let type: String

    @Published var items: [MediaItem] = []
    @Published var libraries: [Library] = []
    @Published var selectedLibID: Int?
    @Published var totalCount = 0
    @Published var isLoading = false
    @Published var errorMessage: String?

    private var page = 1
    private let pageSize = 60
    private var hasMore = true

    private var client: APIClient? { AppSession.shared.client }

    var selectedLibrary: Library? { libraries.first { $0.id == selectedLibID } }

    init(type: String) {
        self.type = type
    }

    @MainActor
    func loadLibraries() async {
        guard let client else {
            errorMessage = "未连接服务器"
            return
        }
        do {
            libraries = try await client.mediaLibraries(ofMediaType: type)
        } catch {
            // 库列表拉不到不阻塞内容加载，退化成「全部」
            libraries = []
        }
        // 同 AlbumListView：从详情返回本页时 .task 可能重跑，此时 reload 会清空 items
        // 让 ScrollView 弹回顶部。已有数据就跳过，保住滚动位置。
        // 切换媒体库仍由 selectLibrary 直接调 reload()，不受影响。
        guard items.isEmpty else { return }
        await reload()
    }

    @MainActor
    func selectLibrary(_ id: Int?) async {
        selectedLibID = id
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
            let (batch, total) = try await client.fetchMedia(type: type, libID: selectedLibID, page: page, size: pageSize)
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
    @State private var selected: MediaItem?

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
                    // resolved?.cover 是 URL??（cover 本身就是可选），flatMap 压平
                    let cover: URL? = resolved.flatMap { $0.cover }
                    MediaCard(item: item, coverURL: cover) {
                        selected = item
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
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if !viewModel.libraries.isEmpty { libraryMenu }
            }
        }
        .overlay {
            if viewModel.items.isEmpty && !viewModel.isLoading {
                ContentUnavailableView(
                    viewModel.errorMessage ?? "暂无内容",
                    systemImage: viewModel.errorMessage == nil ? "film" : "exclamationmark.triangle"
                )
            }
        }
        .task { await viewModel.loadLibraries() }
        .navigationDestination(item: $selected) { item in
            MediaDetailView(media: item)
        }
    }

    /// 库选择放导航栏下拉菜单（iOS 常见样式），不再挤在顶部占一整行
    private var libraryMenu: some View {
        Menu {
            Button {
                Task { await viewModel.selectLibrary(nil) }
            } label: {
                if viewModel.selectedLibID == nil {
                    Label("全部", systemImage: "checkmark")
                } else {
                    Text("全部")
                }
            }
            ForEach(viewModel.libraries) { lib in
                Button {
                    Task { await viewModel.selectLibrary(lib.id) }
                } label: {
                    if lib.id == viewModel.selectedLibID {
                        Label(lib.name, systemImage: "checkmark")
                    } else {
                        Text(lib.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(viewModel.selectedLibrary?.name ?? "全部")
                    .font(.subheadline.weight(.medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(Theme.brand)
        }
    }
}

// MARK: - 影视卡
struct MediaCard: View {
    let item: MediaItem
    var coverURL: URL?
    var width: CGFloat = 150
    var onTap: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RemoteImage(
                url: coverURL,
                fallbackIcon: item.type == "tv" ? "tv" : "film",
                fallbackColors: Theme.placeholderGradient(for: .media)
            )
            .frame(width: width, height: width * 3.0 / 2.0)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(width: width, alignment: .leading)
        }
        .frame(width: width)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color(uiColor: .separator).opacity(0.6), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.10), radius: 8, x: 0, y: 3)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}
