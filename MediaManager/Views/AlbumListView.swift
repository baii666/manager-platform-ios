import SwiftUI

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
                if viewModel.libraries.count > 1 {
                    libraryPicker
                }
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

    private var libraryPicker: some View {
        Picker("媒体库", selection: Binding(
            get: { viewModel.selectedLibID ?? 0 },
            set: { newValue in Task { await viewModel.selectLibrary(newValue) } }
        )) {
            ForEach(viewModel.libraries) { lib in
                Text(lib.name).tag(lib.id)
            }
        }
        .pickerStyle(.segmented)
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
        VStack(alignment: .leading, spacing: 7) {
            RemoteImage(url: coverURL, fallbackIcon: "photo.on.rectangle")
                .frame(width: width, height: width * 3.0 / 2.0)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(alignment: .bottomTrailing) {
                    Text("\(album.count)")
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.55), in: Capsule())
                        .padding(7)
                }
            Text(album.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Text("\(album.count) 张")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(width: width)
    }
}

// MARK: - 相册内照片
struct AlbumPhotosView: View {
    let album: Album
    /// 后端 /api/photos 强制要求 lib，缺失会 400
    let libID: Int

    @State private var photos: [Photo] = []
    @State private var isLoading = false
    @State private var selected: Photo?
    @State private var page = 1
    @State private var hasMore = true
    @State private var errorMessage: String?

    var body: some View {
        PhotoGrid(
            photos: photos,
            columns: 4,
            onSelect: { selected = $0 },
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
        .fullScreenCover(item: $selected) { photo in
            PhotoDetailView(photo: photo)
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
