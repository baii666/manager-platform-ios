import SwiftUI
import UIKit

// MARK: - 相册列表状态
final class AlbumListViewModel: ObservableObject {
    /// 排序方式（对齐网页版 AlbumListPage 的排序下拉 + 后端 /api/photos sortMap）
    enum Sort: String, CaseIterable, Sendable {
        case updatedDesc = "updated_desc"
        case updatedAsc = "updated_asc"
        case releaseDesc = "release_desc"
        case releaseAsc = "release_asc"
        case nameAsc = "name_asc"
        case nameDesc = "name_desc"
        case random = "random"
        var label: String {
            switch self {
            case .updatedDesc: return "最新更新"
            case .updatedAsc: return "最早更新"
            case .releaseDesc: return "最新发表"
            case .releaseAsc: return "最早发表"
            case .nameAsc: return "名称 A→Z"
            case .nameDesc: return "名称 Z→A"
            case .random: return "随机"
            }
        }
    }

    /// 固定库模式：从「媒体库卡片墙」点进来时传入，直接看该库相册
    let fixedLibrary: Library?

    @Published var albums: [Album] = []
    @Published var libraries: [Library] = []
    @Published var selectedLibID: Int?
    @Published var sort: Sort = .updatedDesc
    @Published var searchText = ""
    /// 封面方向：false = 竖版，true = 横版
    @Published var landscape = false
    @Published var totalCount = 0
    @Published var isLoading = false
    @Published var errorMessage: String?

    private var page = 1
    private let pageSize = 60
    private var hasMore = true

    private var client: APIClient? { AppSession.shared.client }

    var selectedLibrary: Library? { libraries.first { $0.id == selectedLibID } }

    init(library: Library? = nil) {
        self.fixedLibrary = library
        self.selectedLibID = library?.id
    }

    @MainActor
    func loadLibraries() async {
        guard let client else {
            errorMessage = "未连接服务器"
            return
        }
        // 固定库模式：库已指定，直接加载
        if let lib = fixedLibrary {
            libraries = [lib]
            selectedLibID = lib.id
            guard albums.isEmpty else { return }
            await reload()
            return
        }
        do {
            let libs = try await client.photoLibraries()
            libraries = libs
            if selectedLibID == nil { selectedLibID = libs.first?.id }

            // ⚠️ 从相册详情返回本页时，SwiftUI 可能再次触发本页的 .task。
            // 若此时走 reload()，会先把 albums 清空 —— ScrollView 内容变空后弹回顶部，
            // 等新数据回来滚动位置已经丢了，表现就是「返回闪一下、跳回列表顶部」。
            // 所以已有数据时直接跳过，保留列表内容与滚动位置，做到「从哪进的返回还在哪」。
            // 真正需要重置列表的场景（切换媒体库）仍由 selectLibrary 显式调 reload。
            guard albums.isEmpty else { return }

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
    func setSort(_ s: Sort) async {
        guard sort != s else { return }
        sort = s
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
            let (items, total) = try await client.fetchAlbums(libID: libID, page: page, size: pageSize, sort: sort.rawValue, q: searchText.isEmpty ? nil : searchText)
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
    let library: Library?

    @StateObject private var viewModel: AlbumListViewModel
    /// 卡片最小宽度（尺寸档位：小 130 / 中 170 / 大 210）
    @State private var cardWidth: CGFloat = 170

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: cardWidth), spacing: 18)]
    }

    init(library: Library? = nil) {
        self.library = library
        _viewModel = StateObject(wrappedValue: AlbumListViewModel(library: library))
    }

    var body: some View {
        VStack(spacing: 0) {
            // 顶部状态栏（独立、美观）
            VStack(spacing: 10) {
                ListSearchBar(text: $viewModel.searchText, placeholder: "搜索相册名…")
                HStack(spacing: 8) {
                    sortMenu
                    ToolChip(label: viewModel.landscape ? "横版" : "竖版",
                             icon: viewModel.landscape ? "rectangle" : "rectangle.portrait",
                             highlighted: viewModel.landscape) {
                        viewModel.landscape.toggle()
                    }
                    sizeMenu
                    Spacer()
                    Text("\(viewModel.albums.count) / \(viewModel.totalCount)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 4)

            ScrollView {
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(viewModel.albums) { album in
                        NavigationLink(value: album) {
                            AlbumCard(album: album, coverURL: coverURL(for: album), landscape: viewModel.landscape)
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
                .padding(16)
                if viewModel.isLoading {
                    ProgressView().frame(maxWidth: .infinity).padding()
                }
            }
        }
        .navigationTitle(library?.name ?? "相册")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // 固定库模式不显示库筛选
                if library == nil && viewModel.libraries.count > 1 { libraryMenu }
            }
        }
        // ⚠️ iOS 17 起 onChange(of:) 零参闭包
        .onChange(of: viewModel.searchText) {
            Task {
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled else { return }
                await viewModel.reload()
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

    /// 排序选择（对齐网页版列表页顶部状态栏）
    private var sortMenu: some View {
        ToolMenuChip(label: viewModel.sort.label, icon: "arrow.up.arrow.down") {
            ForEach(AlbumListViewModel.Sort.allCases, id: \.self) { s in
                Button {
                    Task { await viewModel.setSort(s) }
                } label: {
                    if viewModel.sort == s { Label(s.label, systemImage: "checkmark") }
                    else { Text(s.label) }
                }
            }
        }
    }

    /// 尺寸档位
    private var sizeMenu: some View {
        ToolMenuChip(label: sizeLabel, icon: "arrow.up.left.and.arrow.down.right") {
            Button { cardWidth = 130 } label: { Label("小", systemImage: cardWidth == 130 ? "checkmark" : "square") }
            Button { cardWidth = 170 } label: { Label("中", systemImage: cardWidth == 170 ? "checkmark" : "square") }
            Button { cardWidth = 210 } label: { Label("大", systemImage: cardWidth == 210 ? "checkmark" : "square") }
        }
    }

    private var sizeLabel: String {
        switch cardWidth {
        case 130: return "小"
        case 210: return "大"
        default: return "中"
        }
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

    private func coverURL(for album: Album, landscape: Bool = false) -> URL? {
        // 横版用横封面，竖版用竖封面（缺哪个就退回另一个）
        let id = landscape ? (album.coverPhotoId ?? album.coverPhotoIdPortrait) : album.preferredCoverId
        guard let id else { return nil }
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
    /// 横版封面（16:9）还是竖版（2:3）
    var landscape: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomTrailing) {
                RemoteImage(url: coverURL, fallbackIcon: "photo.on.rectangle")
                    .imageFilled()
                    .frame(width: width, height: width * (landscape ? 9.0 / 16.0 : 3.0 / 2.0))
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
