import SwiftUI
import UIKit

// MARK: - 相册列表状态
final class AlbumListViewModel: ObservableObject {
    @Published var albums: [Album] = []
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

    @MainActor
    func loadLibraries() async {
        guard let client else {
            errorMessage = "未连接服务器"
            return
        }
        do {
            let libs = try await client.photoLibraries()
            libraries = libs
            if selectedLibID == nil { selectedLibID = libs.first?.id }
            await reload()
        } catch {
            errorMessage = "加载媒体库失败 · \(describe(error))"
        }
    }

    @MainActor
    func selectLibrary(_ id: Int) async {
        selectedLibID = id
        await reload()
    }

    @MainActor
    func reload() async {
        albums = []
        page = 1
        hasMore = true
        await loadMore()
    }

    @MainActor
    func loadMore() async {
        guard let client, let libID = selectedLibID, !isLoading, hasMore else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let (items, total) = try await client.fetchAlbums(libID: libID, page: page, size: pageSize)
            totalCount = total
            albums.append(contentsOf: items)
            page += 1
            hasMore = !items.isEmpty && albums.count < total
        } catch {
            errorMessage = "加载相册失败 · \(describe(error))"
        }
    }

    private func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

// MARK: - 相册列表页
// 对齐网页端 AlbumListPage：相册网格（封面 + 标题 + 张数），点进相册看照片
struct AlbumListView: View {
    @StateObject private var viewModel = AlbumListViewModel()

    private let columns = [GridItem(.adaptive(minimum: 170), spacing: 18)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(viewModel.albums) { album in
                        NavigationLink(value: album) {
                            AlbumCard(album: album, coverURL: coverURL(for: album))
                        }
                        .buttonStyle(.plain)
                        .task {
                            // 滚到末尾前预取
                            if album.id == viewModel.albums.last?.id {
                                await viewModel.loadMore()
                            }
                        }
                    }
                }
                if viewModel.isLoading {
                    ProgressView().frame(maxWidth: .infinity).padding()
                }
            }
            .padding(24)
        }
        .navigationTitle("相册")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if viewModel.libraries.count > 1 { libraryMenu }
            }
        }
        .navigationDestination(for: Album.self) { album in
            AlbumPhotosView(album: album, libID: viewModel.selectedLibID ?? 0)
        }
        .overlay {
            if viewModel.albums.isEmpty && !viewModel.isLoading {
                ContentUnavailableView(
                    viewModel.errorMessage ?? "暂无相册",
                    systemImage: viewModel.errorMessage == nil ? "photo.on.rectangle" : "exclamationmark.triangle"
                )
            }
        }
        .task { await viewModel.loadLibraries() }
    }

    /// 库选择放导航栏下拉菜单（iOS 常见样式），不再挤在顶部占一整行
    private var libraryMenu: some View {
        Menu {
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
                Text(viewModel.selectedLibrary?.name ?? "选择相册库")
                    .font(.subheadline.weight(.medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(Theme.brand)
        }
    }

    private func coverURL(for album: Album) -> URL? {
        guard let id = album.preferredCoverId else { return nil }
        return AppSession.shared.client?.makeURL("/photo", queryItems: [
            URLQueryItem(name: "id", value: "\(id)"),
            URLQueryItem(name: "size", value: "600"),
        ])
    }
}

// MARK: - 相册卡
struct AlbumCard: View {
    let album: Album
    var coverURL: URL?
    var width: CGFloat = 170

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomTrailing) {
                RemoteImage(url: coverURL, fallbackIcon: "photo.on.rectangle")
                    .frame(width: width, height: width * 3.0 / 2.0)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                Text("\(album.count)")
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(7)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(album.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("\(album.count) 张")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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
    }
}

// MARK: - 相册内照片
struct AlbumPhotosView: View {
    let album: Album
    /// 后端 /api/photos 强制要求 lib，缺失会 400
    let libID: Int

    @State private var photos: [Photo] = []
    @State private var isLoading = false
    /// 存下标而不是 Photo：看图器要按当前下标左右翻页
    @State private var selectedIndex: Int?
    @State private var page = 1
    @State private var hasMore = true
    @State private var errorMessage: String?

    var body: some View {
        PhotoGrid(
            photos: photos,
            columns: 4,
            onSelect: { photo in
                selectedIndex = photos.firstIndex(where: { $0.id == photo.id })
            },
            onReachEnd: { Task { await loadMore() } }
        )
        .ignoresSafeArea(edges: .bottom)
        .navigationTitle(album.title)
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if photos.isEmpty {
                if let errorMessage {
                    ContentUnavailableView(errorMessage, systemImage: "exclamationmark.triangle")
                } else {
                    ProgressView("加载照片…")
                }
            }
        }
        .task { await loadMore() }
        .fullScreenCover(isPresented: Binding(
            get: { selectedIndex != nil },
            set: { if !$0 { selectedIndex = nil } }
        )) {
            if let index = selectedIndex {
                PhotoViewerView(
                    photos: photos,
                    index: index,
                    hasMore: hasMore,
                    onLoadMore: { Task { await loadMore() } },
                    onClose: { selectedIndex = nil }
                )
            }
        }
    }

    @MainActor
    private func loadMore() async {
        guard let client = AppSession.shared.client, !isLoading, hasMore else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let batch = try await client.fetchAlbumPhotos(albumID: album.id, libID: libID, page: page)
            photos.append(contentsOf: batch)
            page += 1
            hasMore = !batch.isEmpty
        } catch {
            errorMessage = "加载照片失败 · \(((error as? LocalizedError)?.errorDescription) ?? error.localizedDescription)"
        }
    }
}
