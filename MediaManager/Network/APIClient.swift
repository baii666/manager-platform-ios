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

    // MARK: - 播放地址
    //
    // 三档，按「AVPlayer 到底认什么」来分：
    //   1. MP4/M4V/MOV → 直连 /stream。服务端支持 Range（206），随便拖。
    //   2. 其余容器（MKV / AVI / WMV…）→ HLS。
    //      ⚠️ 之前这里走 /stream/remux（chunked fMP4），实测 iPad 上播不了：
    //      它用 -movflags empty_moov 边转边吐，响应是 chunked、没有 Content-Length
    //      也没有 Accept-Ranges，AVPlayer 拿不到时长也 seek 不了，直接
    //      “The operation could not be completed”。HLS 才是 AVPlayer 的原生格式：
    //      每个分片都是独立请求、有确定长度，可 seek。
    //   3. 编码是 iPad 硬解吃不下的时候（VC-1 / MPEG-2 的老 WMV、AVI）→ HLS 重编码。
    //      这一档白烧 CPU，但库里 200 多个 WMV 只有这条路能出画面。

    /// AVPlayer 能直接吃的容器
    private static let directPlayExts: Set<String> = ["mp4", "m4v", "mov"]

    /// iPad 硬解吃得下的视频编码。命中就走 HLS 的 -c:v copy（只换封装，画质无损、CPU 几乎不动）
    private static let nativeVideoCodecs: Set<String> = [
        "h264", "avc1", "avc3", "hevc", "hvc1", "hev1", "av01", "av1c"
    ]

    /// GET /api/playback/info 的返回（服务端用 FFmpeg 探出容器与编码）
    struct PlaybackInfo: Decodable {
        let container: String?
        let videoCodec: String?
        /// 视频轨的 sample entry tag（hvc1 / hev1 / avc1 …）。服务端没升级时这个字段不存在
        let videoTag: String?
        let audioCodec: String?
    }

    func fetchPlaybackInfo(path: String) async throws -> PlaybackInfo {
        guard let u = makeURL("/api/playback/info", queryItems: [
            URLQueryItem(name: "path", value: path)
        ]) else { throw DataError.server("播放地址拼接失败") }
        let (data, resp) = try await session.data(for: URLRequest(url: u))
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw DataError.http(http.statusCode)
        }
        return try decoder.decode(PlaybackInfo.self, from: data)
    }

    /// 带缓存的探测。
    /// 服务端每次都要跑一遍 `ffmpeg -i` 才能知道编码，在 X: 挂载盘上要 1~3 秒。
    /// 同一部片第二次点进去不该再等一次 —— 缓存 5 分钟，返回播放 / 重进直接秒开。
    /// （文件被替换的极端情况最多错 5 分钟，代价可接受。）
    func playbackInfo(path: String) async throws -> PlaybackInfo {
        if let hit = PlaybackInfoStore.shared.get(path) { return hit }
        let info = try await fetchPlaybackInfo(path: path)
        PlaybackInfoStore.shared.set(path, info)
        return info
    }

    /// 直连地址。⚠️ 只对 MP4/M4V/MOV 有意义 —— 别的容器 AVPlayer 不认，
    /// 这里直接返回 nil，免得谁拿它去播 MKV 又得到一个「能拼出来但播不了」的地址。
    /// 非直连容器一律走 `resolvePlayback(path:startAt:...)`。
    func streamURL(path: String) -> URL? {
        guard !path.isEmpty else { return nil }
        let ext = (path as NSString).pathExtension.lowercased()
        guard Self.directPlayExts.contains(ext) else { return nil }
        return makeURL("/stream", queryItems: [URLQueryItem(name: "path", value: path)])
    }

    /// 开一个 HLS 会话拿 m3u8 地址。
    /// 两步：GET /hls 返回 {"sessionId","m3u8Url":"/hls/<id>/index.m3u8"}，
    /// m3u8Url 是**相对路径**，必须拼到 baseURL 上再交给 AVPlayer。
    private func hlsURL(path: String, startAt: Double?, copyVideo: Bool) async throws -> URL {
        var items = [URLQueryItem(name: "path", value: path)]
        if copyVideo { items.append(URLQueryItem(name: "copyVideo", value: "1")) }
        if let s = startAt, s.isFinite, s > 1 {
            items.append(URLQueryItem(name: "startTime", value: String(format: "%.3f", s)))
        }
        guard let u = makeURL("/hls", queryItems: items) else {
            throw DataError.server("HLS 地址拼接失败")
        }
        let (data, resp) = try await session.data(for: URLRequest(url: u))
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw DataError.http(http.statusCode)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rel = obj["m3u8Url"] as? String, !rel.isEmpty,
              let url = URL(string: rel, relativeTo: baseURL) else {
            throw DataError.server("服务端没有返回 HLS 播放列表")
        }
        return url
    }

    /// 兜底播放：绕开直接播放，让服务端重新封一遍。
    ///
    /// - `copyVideo = true`：只换封装（`-c:v copy`），CPU 几乎不动。
    ///   修的是**容器层面**的问题 —— 最典型的是 MP4 里的 HEVC 用了 `hev1` 这个
    ///   sample entry tag：AVFoundation 只认 `hvc1`，碰到 `hev1` 会把视频轨禁用，
    ///   表现就是「只有声音没有画面」。转成 HLS 分片后 tag 问题自然消失。
    /// - `copyVideo = false`：转 H.264。修的是**编码本身**解不出（VC-1、MPEG-2，
    ///   或设备不支持的 HEVC 规格）。代价是烧 CPU。
    ///
    /// ⚠️ 所以降级要分两级：先试便宜的换封装，还不行再重编码。
    ///   直接上重编码的话，4K 片源丢给 libx264 会卡成幻灯片。
    func fallbackPlayback(path: String,
                          startAt: Double?,
                          copyVideo: Bool,
                          title: String,
                          assetType: String?,
                          assetID: Int?,
                          knownDuration: Double? = nil) async throws -> PlaybackTarget {
        let url = try await hlsURL(path: path, startAt: startAt, copyVideo: copyVideo)
        let offset = (startAt ?? 0) > 1 ? (startAt ?? 0) : 0
        return PlaybackTarget(url: url, title: title, assetType: assetType, assetID: assetID,
                              startAt: 0, timeOffset: offset,
                              knownDuration: knownDuration, sourcePath: path)
    }

    /// 决定播放方式并给出最终地址。非直连容器要发两次请求（探测 + 开会话），所以是 async。
    func resolvePlayback(path: String,
                         startAt: Double?,
                         title: String,
                         assetType: String?,
                         assetID: Int?,
                         knownDuration: Double? = nil) async throws -> PlaybackTarget {
        let ext = (path as NSString).pathExtension.lowercased()

        let info = try? await playbackInfo(path: path)
        let codec = info?.videoCodec?.lowercased() ?? ""
        let tag = info?.videoTag?.lowercased() ?? ""

        // MP4 里装 HEVC 有两种 sample entry：`hvc1` 才是 Apple 要的那种。
        // ffmpeg / 部分封装工具写出来的是 `hev1`，AVFoundation 碰上会**直接禁用视频轨** ——
        // 不报错、status 照样 readyToPlay，表现就是「只有声音没有画面」。
        // 所以 tag 是 hev1 时不能直连，得先让服务端重新封装一遍。
        // （库里 x265 的 MP4 基本全是 hev1，抽 120 部无一例外。）
        if Self.directPlayExts.contains(ext), tag != "hev1" {
            guard let url = streamURL(path: path) else {
                throw DataError.server("播放地址拼接失败")
            }
            return PlaybackTarget(url: url, title: title, assetType: assetType, assetID: assetID,
                                  startAt: startAt ?? 0, timeOffset: 0,
                                  knownDuration: knownDuration, sourcePath: path)
        }

        // 探不到编码时按「能 copy」乐观处理。反过来的兜底是灾难性的：
        // 猜成「要重编码」会把 4K 片源丢给 libx264，几帧一秒，那才真的播不动。
        let copyVideo = codec.isEmpty || Self.nativeVideoCodecs.contains(codec)
        let url = try await hlsURL(path: path, startAt: startAt, copyVideo: copyVideo)

        // HLS 的时间轴是从 -ss 那个点重新开始的，上报进度要加回基准
        let offset = (startAt ?? 0) > 1 ? (startAt ?? 0) : 0
        return PlaybackTarget(url: url, title: title, assetType: assetType, assetID: assetID,
                              startAt: 0, timeOffset: offset,
                              knownDuration: knownDuration, sourcePath: path)
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

    /// remember=true → 后端 session cookie 给 30 天（否则 24h）
    func login(username: String, password: String, remember: Bool = true) async throws -> User {
        let resp: LoginResponse = try await request(
            "/api/auth/login", method: "POST",
            json: ["username": username, "password": password, "remember": remember]
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
        // ⚠️ makeURL 返回 URL?，用 flatMap 而不是 `.map { } ?? nil`
        // （map 会得到 URL??，那种靠 ?? nil 压平的写法会招编译器警告）
        detail.posterURL = detail.posterImageId.flatMap { makeURL("/media-image", queryItems: [
            URLQueryItem(name: "id", value: "\($0)"),
            URLQueryItem(name: "size", value: "600"),
        ]) }
        detail.backdropURL = detail.fanartImageId.flatMap { makeURL("/media-image", queryItems: [
            URLQueryItem(name: "id", value: "\($0)"),
        ]) }
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
        // 播放地址：只有直连容器（MP4/M4V/MOV）能同步拼出来。
        // MKV / AVI / WMV 要先找服务端开 HLS 会话，播的时候再走 resolvePlayback 异步拿。
        // ⚠️ 条件必须写成 (a.type == .media || a.type == .short) 加括号：
        // && 优先级高于 ||，不加括号会被解析成 "(path 非空 && media) || short"，
        // 于是短视频即使 path 为空也会拼出一个 path= 的空地址
        if let path = a.playablePath {
            asset.playbackURL = streamURL(path: path)
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
        // ⚠️ title 是非可选 String（默认 ""），写 `item.title ?? ...` 会被警告
        // "left side of nil coalescing operator has non-optional type"。
        // 直接用模型自带的 titleText：title → displayName → folderName → ""
        let title = item.titleText
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
            playback = streamURL(path: path)
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

// MARK: - 播放探测缓存
// `GET /api/playback/info` 每次都要让服务端跑一遍 ffprobe 才拿得到编码 / 容器 / tag。
// 同一部片连点两次不该重复付这个代价（尤其是挂载盘上的大文件）。
private final class PlaybackInfoStore: @unchecked Sendable {
    static let shared = PlaybackInfoStore()

    private let lock = NSLock()
    private var items: [String: (date: Date, info: APIClient.PlaybackInfo)] = [:]
    private let ttl: TimeInterval = 300

    func get(_ path: String) -> APIClient.PlaybackInfo? {
        lock.lock(); defer { lock.unlock() }
        guard let hit = items[path], Date().timeIntervalSince(hit.date) < ttl else { return nil }
        return hit.info
    }

    func set(_ path: String, _ info: APIClient.PlaybackInfo) {
        lock.lock(); defer { lock.unlock() }
        items[path] = (Date(), info)
    }
}
