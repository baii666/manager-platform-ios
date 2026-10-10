import SwiftUI

// MARK: - 搜索页
// 对齐网页端搜索：分类 Tab（全部/影视/相册/照片/拍摄集）+ 每类无限滚动 + 结果直达详情
struct SearchView: View {
    @State private var query = ""
    @State private var debounced = ""
    @State private var selectedTab: Tab = .all
    @State private var results: [SearchItem] = []
    @State private var totals: [String: Int] = [:]
    @State private var isLoading = false
    @State private var errorMessage: String?

    // 导航目标
    @State private var movieTarget: MediaItem?
    @State private var albumTarget: Album?
    @State private var albumLibID: Int = 0
    @State private var shootTarget: Shoot?
    @State private var photoTarget: Photo?

    private var client: APIClient? { AppSession.shared.client }

    enum Tab: String, CaseIterable {
        case all, movie, album, photo, shoot
        var label: String {
            switch self {
            case .all: return "全部"; case .movie: return "影视"
            case .album: return "相册"; case .photo: return "照片"; case .shoot: return "拍摄集"
            }
        }
        /// 该 Tab 实际请求的搜索 type（影视合并 movie+series，用 all 再过滤）
        var requestType: String { self == .movie ? "all" : rawValue }
    }

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 16)]

    var body: some View {
        VStack(spacing: 0) {
            // 搜索框
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索影视 / 相册 / 照片 / 拍摄集", text: $query)
                    .textFieldStyle(.plain)
                    .submitLabel(.search)
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
            .padding(.horizontal, 16).padding(.vertical, 10)

            // 分类 Tab + 计数
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Tab.allCases, id: \.self) { tab in
                        let count = tab == .all
                            ? (totals.values.reduce(0, +))
                            : totals[tab.rawValue].map { $0 } ?? 0
                        Button {
                            selectedTab = tab
                            Task { await reload() }
                        } label: {
                            HStack(spacing: 5) {
                                Text(tab.label)
                                if count > 0 {
                                    Text("\(count)").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            .font(.subheadline.weight(selectedTab == tab ? .semibold : .regular))
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(selectedTab == tab ? Theme.brand.opacity(0.15) : .clear,
                                        in: Capsule())
                            .foregroundStyle(selectedTab == tab ? Theme.brand : .primary)
                        }
                    }
                }
                .padding(.horizontal, 16)
            }

            Divider()

            // 结果
            ScrollView {
                if let errorMessage {
                    ContentUnavailableView(errorMessage, systemImage: "exclamationmark.triangle")
                        .frame(maxWidth: .infinity, minHeight: 300)
                } else if query.isEmpty {
                    ContentUnavailableView("输入关键词开始搜索", systemImage: "magnifyingglass")
                        .frame(maxWidth: .infinity, minHeight: 300)
                } else if results.isEmpty && !isLoading {
                    ContentUnavailableView("没有匹配结果", systemImage: "tray")
                        .frame(maxWidth: .infinity, minHeight: 300)
                } else {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(results) { item in
                            SearchCard(item: item, client: client) {
                                route(item)
                            }
                            .task {
                                if item.id == results.last?.id { await loadMore() }
                            }
                        }
                    }
                    .padding(16)
                    if isLoading {
                        ProgressView().frame(maxWidth: .infinity).padding()
                    }
                }
            }
        }
        .navigationTitle("搜索")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: query) { _ in
            Task {
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled else { return }
                debounced = query
                selectedTab = .all
                await reload()
            }
        }
        .task { }
        .navigationDestination(item: $movieTarget) { MediaDetailView(media: $0) }
        .navigationDestination(item: $albumTarget) { AlbumPhotosView(album: $0, libID: albumLibID) }
        .navigationDestination(item: $shootTarget) { ShootDetailView(shoot: $0) }
        .fullScreenCover(item: $photoTarget) { photo in
            PhotoViewerView(photos: [photo], index: 0, onClose: { photoTarget = nil })
        }
    }

    // MARK: 数据
    private func currentResultsType() -> String {
        // 影视 Tab 用 all 拉取后过滤；其余用各自 type
        selectedTab == .movie ? "all" : selectedTab.rawValue
    }

    @MainActor
    private func reload() async {
        guard let client, !debounced.isEmpty else {
            results = []; totals = [:]; return
        }
        // 计数
        do { totals = try await client.searchTotals(query: debounced) } catch { totals = [:] }
        page = 1; hasMore = true
        await loadMore()
    }

    @State private var page = 1
    private let pageSize = 60
    @State private var hasMore = true

    @MainActor
    private func loadMore() async {
        guard let client, !isLoading, hasMore else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let (batch, total) = try await client.searchItems(
                query: debounced, type: currentResultsType(), page: page, size: pageSize)
            let filtered = selectedTab == .movie
                ? batch.filter { $0.type == "movie" || $0.type == "series" || $0.type == "tv" }
                : batch
            if page == 1 { results = filtered } else { results.append(contentsOf: filtered) }
            page += 1
            hasMore = results.count < total
        } catch {
            errorMessage = "搜索失败 · \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
        }
    }

    // MARK: 路由
    private func route(_ item: SearchItem) {
        switch item.type {
        case "movie", "series", "tv":
            var m = MediaItem(id: item.id)
            m.title = item.titleText
            m.year = item.year
            m.type = item.type == "tv" ? "tv" : "movie"
            m.posterImageId = item.posterImageId
            m.libraryId = item.libraryId
            movieTarget = m
        case "album":
            var a = Album(id: item.id)
            a.folderName = item.folderName ?? item.titleText
            a.displayName = item.displayName
            a.count = item.photoCount ?? 0
            a.coverPhotoId = item.coverPhotoId
            a.coverPhotoIdPortrait = item.coverPhotoId
            albumLibID = item.libraryId ?? 0
            albumTarget = a
        case "photo":
            var p = Photo(id: item.id)
            p.albumId = item.albumId
            p.libraryId = item.libraryId
            p.fileName = item.titleText
            p.thumbURL = client?.makeURL("/photo", queryItems: [
                URLQueryItem(name: "id", value: "\(item.id)"),
                URLQueryItem(name: "size", value: "600"),
            ])
            p.fullURL = client?.makeURL("/photo", queryItems: [
                URLQueryItem(name: "id", value: "\(item.id)"),
                URLQueryItem(name: "size", value: "original"),
            ])
            photoTarget = p
        case "shoot":
            var s = Shoot(id: item.id)
            s.displayName = item.titleText
            s.folderName = item.folderName ?? item.titleText
            s.libraryId = item.libraryId ?? 0
            shootTarget = s
        default:
            break
        }
    }
}

// MARK: - 搜索结果卡
private struct SearchCard: View {
    let item: SearchItem
    let client: APIClient?
    var onTap: () -> Void

    private var cover: URL? {
        switch item.type {
        case "movie", "series", "tv":
            // .map 已返回可选，别再 ?? nil（no-op，会招警告）
            return item.posterImageId.flatMap {
                client?.makeURL("/media-image", queryItems: [
                    URLQueryItem(name: "id", value: "\($0)"),
                    URLQueryItem(name: "size", value: "600"),
                ])
            }
        case "album", "photo":
            let aid = item.coverPhotoId ?? item.id
            return client?.makeURL("/photo", queryItems: [
                URLQueryItem(name: "id", value: "\(aid)"),
                URLQueryItem(name: "size", value: "600"),
            ])
        default:
            return nil
        }
    }

    private var subtitle: String {
        switch item.type {
        case "movie", "series", "tv":
            return item.year.map { "\($0)" } ?? (item.libraryName ?? "")
        case "album":
            return item.photoCount.map { "\($0) 张" } ?? (item.libraryName ?? "")
        case "photo":
            return item.albumId != nil ? "照片" : (item.libraryName ?? "照片")
        case "shoot":
            return item.libraryName ?? "拍摄集"
        default:
            return item.libraryName ?? ""
        }
    }

    private var fallbackColors: [Color] {
        switch item.type {
        case "photo": return Theme.placeholderGradient(for: .photo)
        case "shoot": return Theme.placeholderGradient(for: .shoot)
        case "short": return Theme.placeholderGradient(for: .short)
        default: return Theme.placeholderGradient(for: .media)
        }
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 0) {
                let isPortrait = item.type == "album" || item.type == "movie" || item.type == "series" || item.type == "tv"
                RemoteImage(url: cover, fallbackIcon: fallbackIcon, fallbackColors: fallbackColors)
                    // 搜索结果混合了海报/抽帧封面/照片缩略图，尺寸各不相同，
                    // 必须按容器尺寸渲染，否则会按原图像素撑开、压住相邻卡片
                    .imageFilled()
                    .frame(height: isPortrait ? 200 : 150)
                    .frame(maxWidth: .infinity)
                    .clipped()
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.titleText)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1).truncationMode(.tail)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                }
                .padding(10)
            }
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.separator))
        }
        .buttonStyle(.plain)
    }

    private var fallbackIcon: String {
        switch item.type {
        case "photo": return "photo"
        case "shoot": return "photo.on.rectangle.angled"
        case "short": return "play.rectangle.fill"
        default: return "film"
        }
    }
}
