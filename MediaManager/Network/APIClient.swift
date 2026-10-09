import Foundation

// MARK: - 真实后端客户端
// 对接 D:/manager-platform 的 Go 网关（默认 http://<host>:19876）。
// 认证走 session cookie（URLSession.shared 自动管理），
// 图片 / 播放地址都是相对路径，这里统一拼成完整 URL。
final class APIClient: DataProviding, @unchecked Sendable {
    let baseURL: URL
    private let session: URLSession
    private let decoder: JSONDecoder

    /// 照片随机浏览用的 photo 库 id（惰性缓存，fetchPhotos 串行调用）
    private var cachedPhotoLibID: Int?

    init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
        self.decoder = JSONDecoder()
    }

    // MARK: - URL 辅助

    /// 拼请求 URL（path 以 / 开头，root-relative）
    func url(_ path: String) -> URL {
        URL(string: path, relativeTo: baseURL) ?? baseURL
    }

    /// 用 URLComponents 构建带 query 的完整 URL（自动正确编码）
    func makeURL(_ path: String, queryItems: [URLQueryItem] = []) -> URL? {
        var comp = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        comp?.path = path
        if !queryItems.isEmpty { comp?.queryItems = queryItems }
        return comp?.url
    }

    /// 把后端返回的相对 URL（如 /media-image?id=1）解析成完整 URL
    func resolve(_ url: URL?) -> URL? {
        guard let url, !url.absoluteString.isEmpty else { return nil }
        if url.scheme != nil { return url }
        return URL(string: url.absoluteString, relativeTo: baseURL)
    }

    // MARK: - 请求辅助

    private func request<T: Decodable>(_ path: String, method: String = "GET", json: [String: Any]? = nil) async throws -> T {
        var req = URLRequest(url: url(path))
        req.httpMethod = method
        if let json {
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            if let err = try? decoder.decode(ErrorResponse.self, from: data), !err.error.isEmpty {
                throw DataError.server(err.error)
            }
            throw DataError.http(http.statusCode)
        }
        return try decoder.decode(T.self, from: data)
    }

    // MARK: - 认证

    func login(username: String, password: String) async throws -> User {
        let resp: LoginResponse = try await request(
            "/api/auth/login", method: "POST",
            json: ["username": username, "password": password]
        )
        return resp.user
    }

    func fetchCurrentUser() async throws -> User {
        let resp: LoginResponse = try await request("/api/auth/me")
        return resp.user
    }

    // MARK: - DataProviding

    func fetchStats() async throws -> HomeStats {
        async let libsReq: [Library] = request("/api/libraries")
        async let shootsReq: ShootListResponse = request("/api/shoots?page=1&limit=1")
        async let shortsReq: ShortsCountResponse = request("/api/shorts/count")

        let (libs, shoots, shorts) = try await (libsReq, shootsReq, shortsReq)

        var stats = HomeStats()
        stats.libraryCount = libs.count
        for lib in libs {
            // ⚠️ 后端 media.type 是 "tv" 不是 "series"（只有搜索接口兼容 "series" 别名）
            switch lib.type {
            case "movie": stats.movieCount += lib.itemCount
            case "tv", "series": stats.seriesCount += lib.itemCount
            case "photo": stats.photoCount += lib.itemCount
            case "shoot": stats.shootCount += lib.itemCount
            default: break
            }
        }
        stats.shootCount = shoots.total
        stats.shortCount = shorts.total
        return stats
    }

    func fetchResume(limit: Int) async throws -> [UnifiedAsset] {
        let resp: ItemsResponse<UnifiedAsset> = try await request("/api/actions/resume?limit=\(limit)")
        return resp.items.map { resolveAsset($0) }
    }

    func fetchFavorites(limit: Int) async throws -> [UnifiedAsset] {
        let resp: ItemsResponse<UnifiedAsset> = try await request(
            "/api/actions/list?action=favorite&type=all&page=1&size=\(limit)"
        )
        return resp.items.map { resolveAsset($0) }
    }

    func fetchRecent(limit: Int) async throws -> [RecentItem] {
        let resp: ItemsResponse<RecentItem> = try await request("/api/recent?limit=\(limit)")
        return resp.items.map { resolveRecent($0) }
    }

    func fetchPhotos(limit: Int, offset: Int) async throws -> [Photo] {
        let libID = try await photoLibraryID()
        let resp: ItemsResponse<Photo> = try await request("/api/photos/random?lib=\(libID)&size=\(limit)")
        return resp.items.map { resolvePhoto($0) }
    }

    func search(query: String) async throws -> [UnifiedAsset] {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let resp: SearchResponse = try await request("/api/search?q=\(encoded)&type=all&page=1&size=60")
        return resp.items.compactMap { resolveSearchItem($0) }
    }

    // MARK: - 结果解析（拼完整 URL）

    private func resolveAsset(_ a: UnifiedAsset) -> UnifiedAsset {
        var asset = a
        asset.coverURL = resolve(a.coverURL)
        asset.backdropURL = resolve(a.backdropURL)
        // 播放地址：影视/短视频有文件路径，直接用 /stream 直连（AVPlayer 支持 Range + H264/HEVC）
        if let path = a.path, !path.isEmpty, a.type == .media || a.type == .short {
            asset.playbackURL = makeURL("/stream", queryItems: [URLQueryItem(name: "path", value: path)])
        }
        return asset
    }

    private func resolveRecent(_ item: RecentItem) -> RecentItem {
        var r = item
        if let coverPhotoId = r.coverPhotoId {
            r.coverURL = makeURL("/photo", queryItems: [
                URLQueryItem(name: "id", value: "\(coverPhotoId)"),
                URLQueryItem(name: "size", value: "600"),
            ])
        } else if let posterId = r.posterImageId {
            r.coverURL = makeURL("/media-image", queryItems: [
                URLQueryItem(name: "id", value: "\(posterId)"),
                URLQueryItem(name: "size", value: "600"),
            ])
        }
        return r
    }

    private func resolvePhoto(_ p: Photo) -> Photo {
        var photo = p
        photo.thumbURL = makeURL("/photo", queryItems: [
            URLQueryItem(name: "id", value: "\(p.id)"),
            URLQueryItem(name: "size", value: "600"),
        ])
        photo.fullURL = makeURL("/photo", queryItems: [
            URLQueryItem(name: "id", value: "\(p.id)"),
        ])
        return photo
    }

    private func resolveSearchItem(_ item: SearchItem) -> UnifiedAsset? {
        let isPhoto = item.fileName != nil || item.hasThumb != nil || item.folderName != nil
        let type: AssetType = isPhoto ? .photo : .media
        let title = item.title ?? item.fileName ?? item.folderName ?? ""
        guard !title.isEmpty else { return nil }

        var cover: URL?
        if let posterId = item.posterImageId {
            cover = makeURL("/media-image", queryItems: [
                URLQueryItem(name: "id", value: "\(posterId)"),
                URLQueryItem(name: "size", value: "600"),
            ])
        } else if isPhoto {
            cover = makeURL("/photo", queryItems: [
                URLQueryItem(name: "id", value: "\(item.id)"),
                URLQueryItem(name: "size", value: "600"),
            ])
        }
        return UnifiedAsset(id: item.id, type: type, title: title, coverURL: cover)
    }

    private func photoLibraryID() async throws -> Int {
        if let id = cachedPhotoLibID { return id }
        let libs: [Library] = try await request("/api/libraries")
        guard let photoLib = libs.first(where: { $0.type == "photo" }) else {
            throw DataError.server("未找到照片媒体库")
        }
        cachedPhotoLibID = photoLib.id
        return photoLib.id
    }
}

// MARK: - 响应 DTO

private struct LoginResponse: Decodable {
    let user: User
}

private struct ErrorResponse: Decodable {
    let error: String
}

private struct ItemsResponse<T: Decodable>: Decodable {
    let items: [T]
}

private struct ShootListResponse: Decodable {
    let total: Int
}

private struct ShortsCountResponse: Decodable {
    let total: Int
}

private struct SearchResponse: Decodable {
    let items: [SearchItem]
}

/// 搜索结果异构字段：不同类型（影视/照片/相册）返回不同列，这里只取需要的
private struct SearchItem: Decodable {
    let id: Int
    let title: String?
    let fileName: String?
    let folderName: String?
    let posterImageId: Int?
    let hasThumb: Int?

    enum CodingKeys: String, CodingKey {
        case id, title
        case fileName = "file_name"
        case folderName = "folder_name"
        case posterImageId = "poster_image_id"
        case hasThumb = "has_thumb"
    }
}
