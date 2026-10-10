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

    /// 带 query items 的请求（自动正确编码）
    private func request<T: Decodable>(_ path: String, queryItems: [URLQueryItem]) async throws -> T {
        var comp = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        comp?.path = path
        comp?.queryItems = queryItems
        guard let finalURL = comp?.url else { throw DataError.server("URL 构造失败") }
        var req = URLRequest(url: finalURL)
        req.httpMethod = "GET"
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

    // MARK: - 媒体详情

    func fetchMediaDetail(id: Int) async throws -> MediaDetail {
        var detail: MediaDetail = try await request("/api/media/\(id)")
        detail.posterURL = detail.posterImageId.map { makeURL("/media-image", queryItems: [
            URLQueryItem(name: "id", value: "\($0)"),
            URLQueryItem(name: "size", value: "600"),
        ]) } ?? nil
        detail.backdropURL = detail.fanartImageId.map { makeURL("/media-image", queryItems: [
            URLQueryItem(name: "id", value: "\($0)"),
        ]) } ?? nil
        // 剧照 relative → absolute
        if !detail.stills.isEmpty {
            detail.stills = detail.stills.compactMap { resolve($0) }
        }
        return detail
    }

    // MARK: - 拍摄集

    func fetchShoots(libraryId: Int? = nil, page: Int = 1, size: Int = 30,
                     sort: String = "mtime", search: String? = nil) async throws -> ([Shoot], Int) {
        var qi: [URLQueryItem] = [
            URLQueryItem(name: "page", value: "\(page)"),
            URLQueryItem(name: "limit", value: "\(size)"),
            URLQueryItem(name: "sort", value: sort),
        ]
        if let libraryId, libraryId > 0 { qi.append(URLQueryItem(name: "libraryId", value: "\(libraryId)")) }
        if let search, !search.isEmpty { qi.append(URLQueryItem(name: "search", value: search)) }
        let resp: ShootsPageResponse = try await request("/api/shoots", queryItems: qi)
        return (resp.shoots, resp.total)
    }

    func fetchShootDetail(id: Int) async throws -> ShootDetail {
        try await request("/api/shoots/\(id)")
    }

    func fetchShootPhotos(id: Int, page: Int = 1, size: Int = 50) async throws -> [ShootFile] {
        let resp: ShootPhotosResponse = try await request(
            "/api/shoots/\(id)/photos", queryItems: [
                URLQueryItem(name: "page", value: "\(page)"),
                URLQueryItem(name: "limit", value: "\(size)"),
            ]
        )
        return resp.photos
    }

    func shootCoverURL(_ id: Int, size: Int = 600) -> URL? {
        makeURL("/api/shoots/\(id)/cover", queryItems: [URLQueryItem(name: "size", value: "\(size)")])
    }
    func shootFileURL(_ fileId: Int) -> URL? {
        makeURL("/api/shoot-file/\(fileId)")
    }
    /// 拍摄集内照片走统一的 /photo?id= 接口（与网页端一致）
    func shootPhotoURL(_ id: Int, size: Int? = nil) -> URL? {
        var qi: [URLQueryItem] = [URLQueryItem(name: "id", value: "\(id)")]
        if let size { qi.append(URLQueryItem(name: "size", value: "\(size)")) }
        else { qi.append(URLQueryItem(name: "size", value: "original")) }
        return makeURL("/photo", queryItems: qi)
    }

    // MARK: - 短视频

    func fetchShortVideos(poolId: Int? = nil, page: Int = 1, size: Int = 60,
                          q: String? = nil, cover: String = "all") async throws -> ([ShortVideo], Int) {
        var qi: [URLQueryItem] = [
            URLQueryItem(name: "page", value: "\(page)"),
            URLQueryItem(name: "size", value: "\(size)"),
        ]
        if let poolId, poolId > 0 { qi.append(URLQueryItem(name: "pool", value: "\(poolId)")) }
        if let q, !q.isEmpty { qi.append(URLQueryItem(name: "q", value: q)) }
        if cover != "all" { qi.append(URLQueryItem(name: "cover", value: cover)) }
        let resp: ShortVideosResponse = try await request("/api/shorts/videos", queryItems: qi)
        return (resp.items, resp.total)
    }

    func fetchShortPools() async throws -> [ShortPool] {
        let resp: PoolsResponse = try await request("/api/shorts/pools")
        return resp.pools
    }

    // MARK: - 搜索（分类）

    /// 按类型分页搜索。type: all/movie/series/album/photo/shoot/short
    func searchItems(query: String, type: String, page: Int = 1, size: Int = 60) async throws -> ([SearchItem], Int) {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let resp: SearchResponse = try await request(
            "/api/search", queryItems: [
                URLQueryItem(name: "q", value: encoded),
                URLQueryItem(name: "type", value: type),
                URLQueryItem(name: "page", value: "\(page)"),
                URLQueryItem(name: "size", value: "\(size)"),
            ]
        )
        return (resp.items, resp.total)
    }

    /// 分类计数（用于搜索页 Tab 角标），走独立 /totals 端点
    func searchTotals(query: String) async throws -> [String: Int] {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let resp: [String: Int] = try await request("/api/search/totals", queryItems: [
            URLQueryItem(name: "q", value: encoded)
        ])
        return resp
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
            // ⚠️ 必须显式要原图：不传 size 时后端默认给 400 缩略图，看图器会糊
            URLQueryItem(name: "size", value: "original"),
        ])
        return photo
    }

    private func resolveSearchItem(_ item: SearchItem) -> UnifiedAsset? {
        let isPhoto = item.hasThumb != nil || item.albumId != nil || item.folderName != nil
        let type: AssetType = isPhoto ? .photo : .media
        let title = item.title ?? item.folderName ?? item.displayName ?? ""
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

    // MARK: - 相册 / 影视列表

    /// 相册列表。GET /api/photos?lib=x&page=1&size=60（返回 folders 数组）
    func fetchAlbums(libID: Int, page: Int = 1, size: Int = 60) async throws -> (items: [Album], total: Int) {
        let resp: AlbumListResponse = try await request(
            "/api/photos?lib=\(libID)&page=\(page)&size=\(size)&sort=updated_desc"
        )
        return (resp.folders, resp.total)
    }

    /// 相册内照片。GET /api/photos?lib=x&albumId=y
    /// ⚠️ lib 是必填（缺失直接 400）；用 albumId 比 folder 精确——
    /// 后端只按 folder_path 匹配，同目录可能被多个库共用
    func fetchAlbumPhotos(albumID: Int, libID: Int, page: Int = 1, size: Int = 120) async throws -> [Photo] {
        let resp: ItemsResponse<Photo> = try await request(
            "/api/photos?lib=\(libID)&albumId=\(albumID)&page=\(page)&size=\(size)"
        )
        return resp.items.map { resolvePhoto($0) }
    }

    /// 影视列表。type: movie / tv；libID 为 nil 时后端返回用户可见媒体库的全集
    func fetchMedia(type: String, libID: Int? = nil, page: Int = 1, size: Int = 60) async throws -> (items: [MediaItem], total: Int) {
        var path = "/api/media?type=\(type)&page=\(page)&size=\(size)&sort=updated_desc"
        if let libID { path += "&lib=\(libID)" }
        let resp: MediaListResponse = try await request(path)
        return (resp.items, resp.total)
    }

    /// 指定类型的媒体库（movie / tv / photo / shoot），用于列表页的库筛选
    func libraries(ofType type: String) async throws -> [Library] {
        let libs: [Library] = try await request("/api/libraries")
        return libs.filter { $0.type == type }
    }

    func photoLibraries() async throws -> [Library] {
        try await libraries(ofType: "photo")
    }

    /// 影视库筛选。⚠️ 库表的 type 是 movie/series/mixed，而 /api/media 用 movie/tv，
    /// 直接拿 "tv" 去过滤会得到一个空列表，这里做一次映射
    func mediaLibraries(ofMediaType type: String) async throws -> [Library] {
        let wanted: Set<String> = type == "tv" ? ["series", "tv", "mixed"] : ["movie", "mixed"]
        let libs: [Library] = try await request("/api/libraries")
        return libs.filter { wanted.contains($0.type) }
    }

    /// 影视条目的封面 / 播放地址
    func resolveMedia(_ m: MediaItem) -> (cover: URL?, playback: URL?) {
        var cover: URL?
        if let posterId = m.posterImageId {
            cover = makeURL("/media-image", queryItems: [
                URLQueryItem(name: "id", value: "\(posterId)"),
                URLQueryItem(name: "size", value: "600"),
            ])
        }
        var playback: URL?
        if let path = m.filePath, !path.isEmpty {
            playback = makeURL("/stream", queryItems: [URLQueryItem(name: "path", value: path)])
        }
        return (cover, playback)
    }

    // MARK: - 行为层（收藏）

    /// 查询单个资产的收藏状态。GET /api/actions/status?type=photo&ids=1 → {states:[{id,favorite}]}
    func fetchFavorite(type: String, id: Int) async throws -> Bool {
        let resp: ActionStatusResponse = try await request("/api/actions/status?type=\(type)&ids=\(id)")
        return resp.states.first(where: { $0.id == id })?.favorite ?? false
    }

    /// 设置 / 取消收藏。POST /api/actions/favorite {type,id,on} → {favorite}
    func setFavorite(type: String, id: Int, on: Bool) async throws -> Bool {
        let resp: FavoriteResponse = try await request(
            "/api/actions/favorite", method: "POST",
            json: ["type": type, "id": id, "on": on]
        )
        return resp.favorite
    }

    // MARK: - 行为层（播放进度）

    /// 上报播放位置。POST /api/actions/progress {type,id,position,duration}
    /// position <= 0 时后端会清除该资产的进度记录（看完/从头开始）。
    /// 播放器每 15 秒调一次，关闭时再补一次，失败静默忽略。
    func reportProgress(type: String, id: Int, position: Double, duration: Double) async throws {
        let _: ActionAck = try await request(
            "/api/actions/progress", method: "POST",
            json: ["type": type, "id": id, "position": position, "duration": duration]
        )
    }
}

// MARK: - 响应 DTO

private struct LoginResponse: Decodable {
    let user: User
}

private struct ErrorResponse: Decodable {
    let error: String
}

/// 行为层写接口的统一回包：{ok:true}
private struct ActionAck: Decodable {
    let ok: Bool?
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

private struct MediaListResponse: Decodable {
    let items: [MediaItem]
    let total: Int
}

/// /api/photos 的相册列表响应（数组挂在 folders 键下）
private struct AlbumListResponse: Decodable {
    let folders: [Album]
    let total: Int
}

private struct SearchResponse: Decodable {
    let items: [SearchItem]
    let total: Int
}

/// /api/actions/status 的响应：states 里每项含 id / favorite / rating / position
private struct ActionStatusResponse: Decodable {
    struct State: Decodable {
        let id: Int
        let favorite: Bool?
    }
    let states: [State]
}

private struct FavoriteResponse: Decodable {
    let favorite: Bool
}

private struct ShootsPageResponse: Decodable {
    let shoots: [Shoot]
    let total: Int
}

private struct ShootPhotosResponse: Decodable {
    let photos: [ShootFile]
    let total: Int
}

private struct ShortVideosResponse: Decodable {
    let items: [ShortVideo]
    let total: Int
}

private struct PoolsResponse: Decodable {
    let pools: [ShortPool]
}
