import Foundation
import CoreGraphics

// MARK: - 资产类型
// 与后端 asset_type 对齐：四类内容共用一套资产模型
// media=影视 / photo=写真 / short=短视频 / shoot=拍摄集
enum AssetType: String, Codable, CaseIterable, Identifiable, Sendable {
    case media
    case photo
    case short
    case shoot

    var id: String { rawValue }

    /// 容错解码：后端若出现未知类型，不至于让整条列表解码失败
    init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? "media"
        self = AssetType(rawValue: raw) ?? .media
    }

    var label: String {
        switch self {
        case .media: return "影视"
        case .photo: return "写真"
        case .short: return "短视频"
        case .shoot: return "拍摄集"
        }
    }

    var systemImage: String {
        switch self {
        case .media: return "film"
        case .photo: return "camera"
        case .short: return "play.rectangle.fill"
        case .shoot: return "photo.on.rectangle.angled"
        }
    }
}

// MARK: - 统一资产
// 对应后端统一行为层 asset_actions 返回的 AssetRef：
// 「继续观看」「我的收藏」都返回这种结构，天然覆盖四类内容。
// cover_url / backdrop_url 是相对路径，由 APIClient 拼成完整 URL。
struct UnifiedAsset: Identifiable, Codable, Sendable {
    let id: Int
    let type: AssetType
    let title: String
    var subtitle: String? = nil
    /// 文件路径（media=video_file、short=file_path、photo=file_path、shoot=folder_path）
    var path: String? = nil
    var coverURL: URL? = nil
    var backdropURL: URL? = nil
    var position: Double? = nil
    var duration: Double? = nil
    /// 客户端拼好的播放地址（/stream?path=），不来自后端
    var playbackURL: URL? = nil

    /// 播放进度 0...1（继续观看卡片的进度条）
    var progress: Double {
        guard let position, let duration, duration > 0 else { return 0 }
        return min(1, max(0, position / duration))
    }

    enum CodingKeys: String, CodingKey {
        case id, type, title, subtitle, path, position, duration
        case coverURL = "cover_url"
        case backdropURL = "backdrop_url"
    }

    init(id: Int, type: AssetType, title: String,
         subtitle: String? = nil, path: String? = nil,
         coverURL: URL? = nil, backdropURL: URL? = nil,
         position: Double? = nil, duration: Double? = nil,
         playbackURL: URL? = nil) {
        self.id = id
        self.type = type
        self.title = title
        self.subtitle = subtitle
        self.path = path
        self.coverURL = coverURL
        self.backdropURL = backdropURL
        self.position = position
        self.duration = duration
        self.playbackURL = playbackURL
    }

    // 后端 gin.H 手动拼字段，cover_url 为空串也会输出；
    // Swift 的 URL? 解码空串 / 非法串会抛错 → 一条坏记录拖垮整块列表。
    // 这里自定义解码：URL 解析失败只丢这张封面。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        type = (try? c.decode(AssetType.self, forKey: .type)) ?? .media
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        subtitle = optString(c, .subtitle)
        path = optString(c, .path)
        coverURL = flexURL(c, .coverURL)
        backdropURL = flexURL(c, .backdropURL)
        position = optDouble(c, .position)
        duration = optDouble(c, .duration)
    }

    /// 可播放的文件路径。只有影视 / 短视频是「一个文件」，写真 / 拍摄集是目录。
    /// ⚠️ 别再用 playbackURL 是否为空来判断能不能播 —— 非直连容器（MKV/AVI/WMV）
    /// 的播放地址要问服务端要，拿不到同步地址 ≠ 不能播。
    var playablePath: String? {
        guard type == .media || type == .short else { return nil }
        guard let p = path, !p.isEmpty else { return nil }
        return p
    }
}

// MARK: - 播放目标
// 播放地址不再是一行代码能拼出来的：非 MP4 容器要先找服务端开一个 HLS 会话，
// 所以「地址 + 起始位置 + 时间轴偏移」打包成一个值，配合 .fullScreenCover(item:) 使用。
// ⚠️ 必须用 item: 把数据传进内容闭包。写成 isPresented + 另一个 @State，
// 闭包可能读到更新前的值（URL 还是 nil）→ 弹层出来了但没画面，且无从判断。
struct PlaybackTarget: Identifiable, Sendable {
    let id = UUID()
    let url: URL
    let title: String
    /// 传了才会上报播放进度（对接统一行为层 POST /api/actions/progress）
    let assetType: String?
    let assetID: Int?
    /// 交给 AVPlayer 的起始秒
    let startAt: Double
    /// 上报进度要叠加的时间轴基准。
    /// HLS 走服务端 `-ss` 从断点切片时，播放器自己的时间轴是从 0 开始的，
    /// 直接上报会把 2 小时的电影记成 30 分钟。
    let timeOffset: Double
    /// 服务端已知的总时长。HLS 会话没跑完时 AVPlayer 拿不到 duration，用它兜底
    let knownDuration: Double?
    /// 源文件路径。画面解不出来时要拿它去服务端开重编码会话
    let sourcePath: String?
}

// decodeIfPresent 再包 try? 会产生 String?? / Double??（双层可选），
// 直接当 String? 用会编译不过，这里统一压平成单层。
fileprivate func optString<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> String? {
    if let v = try? c.decodeIfPresent(String.self, forKey: key) { return v }
    return nil
}

fileprivate func optDouble<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> Double? {
    if let v = try? c.decodeIfPresent(Double.self, forKey: key) { return v }
    return nil
}

fileprivate func optInt<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> Int? {
    if let v = try? c.decodeIfPresent(Int.self, forKey: key) { return v }
    return nil
}

/// URL 字段的容错解码：空串 / 非法串返回 nil，不让整块数据解码失败
fileprivate func flexURL<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> URL? {
    guard let s = optString(c, key), !s.isEmpty else { return nil }
    return URL(string: s)
}

// MARK: - 最近入库
// 对应 /api/recent 返回的条目：电影 / 剧集 / 相册
struct RecentItem: Identifiable, Codable, Sendable, Hashable {
    enum Kind: String, Codable, Sendable {
        case movie
        case series
        case album

        /// 容错解码：media.type 出现库类型（如 mixed）时兜底，避免整块「最近入库」解码失败
        init(from decoder: Decoder) throws {
            let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? "movie"
            self = Kind(rawValue: raw) ?? .movie
        }

        var label: String {
            switch self {
            case .movie: return "电影"
            case .series: return "剧集"
            case .album: return "相册"
            }
        }

        var systemImage: String {
            switch self {
            case .movie: return "film"
            case .series: return "tv"
            case .album: return "camera"
            }
        }
    }

    let id: Int
    let kind: Kind
    let title: String
    var year: Int? = nil
    var posterImageId: Int? = nil
    var fanartImageId: Int? = nil
    var coverPhotoId: Int? = nil
    var photoCount: Int? = nil
    var libraryId: Int = 0
    var libraryName: String? = nil
    /// 客户端拼好的封面 URL（不来自后端）
    var coverURL: URL? = nil

    // ⚠️ 后端 /api/recent 用的是 camelCase（posterImageId / coverPhotoId / libName），
    // 写错不会报错，只会静默全为 nil —— 表现为条目有标题但没封面
    enum CodingKeys: String, CodingKey {
        case id, kind, title, year
        case posterImageId = "posterImageId"
        case fanartImageId = "fanartImageId"
        case coverPhotoId = "coverPhotoId"
        case photoCount = "photoCount"
        case libraryId = "libraryId"
        case libraryName = "libName"
    }
}

// MARK: - 媒体库
struct Library: Identifiable, Codable, Sendable, Hashable {
    let id: Int
    let name: String
    let type: String // movie / series / photo / shoot / mixed
    var itemCount: Int = 0
    var albumCount: Int? = nil
    var thumbURL: URL? = nil
    /// 库设置里的**横版**卡片宽高比（网页端库设置「横版封面」），如 3/2 → 1.5；nil = 没设，用默认 16:9
    var cardAspectLandscape: CGFloat? = nil
    /// 库设置里的**竖版**卡片宽高比；nil = 没设，用默认 2:3
    var cardAspectPortrait: CGFloat? = nil

    var displayType: String {
        switch type {
        case "movie": return "电影"
        case "tv", "series": return "剧集"
        case "photo": return "相册"
        case "shoot": return "拍摄集"
        default: return type
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, name, type
        case itemCount = "item_count"
        case albumCount = "album_count"
        case thumbURL = "thumb_url"
        case settings
    }

    /// settings 里只关心这两个键（其它的网页端才用）
    private enum SettingsKeys: String, CodingKey {
        case cardAspectRatioLandscape, cardAspectRatioPortrait
    }

    /// "3/2" → 1.5。网页端只提供 n/h 形式的选项（1/1、5/4、4/3、3/2、16:9…），
    /// 解析失败 / 为空一律返回 nil（= 用客户端默认比例）
    private static func aspectRatio(_ raw: String?) -> CGFloat? {
        guard let raw, !raw.isEmpty else { return nil }
        let parts = raw.split(separator: "/")
        guard parts.count == 2,
              let w = Double(parts[0]), w > 0,
              let h = Double(parts[1]), h > 0 else { return nil }
        return CGFloat(w / h)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        type = (try? c.decode(String.self, forKey: .type)) ?? ""
        itemCount = optInt(c, .itemCount) ?? 0
        albumCount = optInt(c, .albumCount)
        thumbURL = flexURL(c, .thumbURL)
        // settings 是个 JSON 对象（后端已 JSON.parse 过）；个别老接口可能给字符串，失败就当没设
        if let s = try? c.nestedContainer(keyedBy: SettingsKeys.self, forKey: .settings) {
            cardAspectLandscape = Library.aspectRatio(try? s.decode(String.self, forKey: .cardAspectRatioLandscape))
            cardAspectPortrait = Library.aspectRatio(try? s.decode(String.self, forKey: .cardAspectRatioPortrait))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(type, forKey: .type)
        try c.encode(itemCount, forKey: .itemCount)
        try c.encodeIfPresent(albumCount, forKey: .albumCount)
        try c.encodeIfPresent(thumbURL, forKey: .thumbURL)
        // settings 与两个比例字段都是「读进来」用的，编码时跳过
    }
}

// MARK: - 首页统计
// 对应首页 Hero 区的六张统计卡
struct HomeStats: Sendable {
    var libraryCount: Int = 0
    var movieCount: Int = 0
    var seriesCount: Int = 0
    var photoCount: Int = 0
    var shootCount: Int = 0
    var shortCount: Int = 0

    var totalContent: Int { movieCount + seriesCount + photoCount + shootCount }
}

// MARK: - 照片
// 对应后端 /api/photos 返回的单张照片；width/height 用于瀑布流计算展示高度
struct Photo: Identifiable, Codable, Sendable {
    let id: Int
    var albumId: Int? = nil
    var fileName: String? = nil
    /// 后端在 EXIF 缺失时会返回 null，必须可选，否则整页照片解码失败
    var width: Int? = nil
    var height: Int? = nil
    var hasThumb: Int? = nil
    var libraryId: Int? = nil
    var fileSize: Int64? = nil
    /// 客户端拼好的缩略图 / 原图 URL（不来自后端）
    var thumbURL: URL? = nil
    var fullURL: URL? = nil
    /// 左下角胶囊角标文案。目前只有语义搜索用它标相似度（"87%"）；
    /// 默认 nil → 瀑布流 cell 不画角标。⚠️ 纯客户端字段，不在 CodingKeys 里
    var badge: String? = nil

    /// 人类可读的文件大小，信息面板用
    var sizeText: String? {
        guard let fileSize, fileSize > 0 else { return nil }
        if fileSize < 1024 { return "\(fileSize) B" }
        if fileSize < 1024 * 1024 { return String(format: "%.1f KB", Double(fileSize) / 1024) }
        return String(format: "%.1f MB", Double(fileSize) / (1024 * 1024))
    }

    /// “1920 × 1080”，没有 EXIF 时返回 nil
    var dimensionText: String? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        return "\(width) × \(height)"
    }

    /// 展示宽高比（宽/高），瀑布流据此算 cell 高度；默认 2:3
    var aspectRatio: CGFloat {
        guard let width, let height, width > 0, height > 0 else { return 2.0 / 3.0 }
        return CGFloat(width) / CGFloat(height)
    }

    enum CodingKeys: String, CodingKey {
        case id, width, height
        case albumId = "album_id"
        case fileName = "file_name"
        case hasThumb = "has_thumb"
        case libraryId = "library_id"
        case fileSize = "file_size"
    }
}

// MARK: - 图片详情（看图器信息卡片）
// 对应 GET /api/photo/:id 返回的 photo 对象。字段全可选：后端只在 EXIF/AI 标注存在时才返回对应键。
struct PhotoDetail: Identifiable, Decodable, Sendable {
    let id: Int
    var fileName: String = ""
    var filePath: String = ""
    var hasThumb: Bool = false
    var folderName: String? = nil
    var fileSize: Int64? = nil
    var width: Int? = nil
    var height: Int? = nil
    var library: LibraryRef? = nil
    var album: AlbumRef? = nil
    var takenAt: String? = nil
    var cameraMake: String? = nil
    var cameraModel: String? = nil
    var focalLength: Double? = nil
    var aperture: Double? = nil
    var iso: Int? = nil
    var gpsLat: Double? = nil
    var gpsLng: Double? = nil
    var aestheticScore: Double? = nil
    var aiCaption: String? = nil
    var captionAt: String? = nil

    enum CodingKeys: String, CodingKey {
        case id, width, height, iso, library, album
        case fileName = "file_name"
        case filePath = "file_path"
        case hasThumb = "has_thumb"
        case folderName = "folder_name"
        case fileSize = "file_size"
        case takenAt = "taken_at"
        case cameraMake = "camera_make"
        case cameraModel = "camera_model"
        case focalLength = "focal_length"
        case aperture
        case gpsLat = "gps_lat"
        case gpsLng = "gps_lng"
        case aestheticScore = "aesthetic_score"
        case aiCaption = "ai_caption"
        case captionAt = "caption_at"
    }

    /// 所属媒体库（后端返回 {id, name, type}）
    struct LibraryRef: Decodable, Sendable {
        let id: Int
        let name: String
        let type: String
    }

    /// 所属相册（后端返回 {id, photo_count, folder_name}）
    struct AlbumRef: Decodable, Sendable {
        let id: Int
        let photoCount: Int?
        let folderName: String?

        enum CodingKeys: String, CodingKey {
            case id
            case photoCount = "photo_count"
            case folderName = "folder_name"
        }
    }
}

// MARK: - 人脸检测结果
// 对应 GET /api/photos/:id/faces 返回的 faces 项（后端只返回 bbox + 置信度，不含人物名）
struct PhotoFace: Identifiable, Decodable, Sendable {
    let id: Int
    var bboxX1: Double = 0
    var bboxY1: Double = 0
    var bboxX2: Double = 0
    var bboxY2: Double = 0
    var detScore: Double = 0

    /// 检测置信度百分比文案（如 "87%"）
    var scoreText: String { String(format: "%.0f%%", detScore * 100) }

    enum CodingKeys: String, CodingKey {
        case id
        case bboxX1 = "bbox_x1"
        case bboxY1 = "bbox_y1"
        case bboxX2 = "bbox_x2"
        case bboxY2 = "bbox_y2"
        case detScore = "det_score"
    }
}

// MARK: - 相似图片
// 对应 GET /api/photos/:id/similar 返回的 similar 项。
// phash 结果带 distance（汉明距离，越小越像）；clip 结果带 similarity（余弦相似度 0~1，越大越像）。
struct SimilarPhoto: Identifiable, Decodable, Sendable {
    let id: Int
    var fileName: String = ""
    var distance: Int? = nil
    var similarity: Double? = nil
    var width: Int? = nil
    var height: Int? = nil
    var aestheticScore: Double? = nil

    /// 展示用相似度文案：phash 显示距离，clip 显示百分比
    var scoreText: String? {
        if let distance {
            return "距离 \(distance)"
        }
        if let similarity {
            return String(format: "%.0f%%", similarity * 100)
        }
        return nil
    }

    enum CodingKeys: String, CodingKey {
        case id, width, height
        case fileName = "file_name"
        case distance
        case similarity
        case aestheticScore = "aesthetic_score"
    }
}

// MARK: - 任务进度（SSE 推送）
// 后端扫描/转码等后台任务通过 text/event-stream 推送进度
struct TaskProgress: Identifiable, Sendable {
    let id: String
    var taskType: String = ""
    var message: String = ""
    var done: Int = 0
    var total: Int = 0
    var isFinished: Bool = false

    var percent: Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(done) / Double(total)))
    }
}

// MARK: - 相册
// 对应 /api/photos?lib=x 返回的 folders 项（后端字段：count / display_name / cover_photo_id）
struct Album: Identifiable, Codable, Sendable, Hashable {
    let id: Int
    var folderPath: String = ""
    var folderName: String = ""
    var displayName: String? = nil
    var count: Int = 0
    var coverPhotoId: Int? = nil
    var coverPhotoIdPortrait: Int? = nil
    var coverOrient: String? = nil
    var releaseDate: String? = nil

    /// display_name 为空时回退 folder_name（与网页端一致）
    var title: String {
        if let displayName, !displayName.isEmpty { return displayName }
        return folderName
    }

    /// 竖版封面优先，相册卡是 2:3 竖版
    var preferredCoverId: Int? { coverPhotoIdPortrait ?? coverPhotoId }

    enum CodingKeys: String, CodingKey {
        case id
        case folderPath = "folder_path"
        case folderName = "folder_name"
        case displayName = "display_name"
        case count
        case coverPhotoId = "cover_photo_id"
        case coverPhotoIdPortrait = "cover_photo_id_portrait"
        case coverOrient = "cover_orient"
        case releaseDate = "release_date"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        folderPath = (try? c.decode(String.self, forKey: .folderPath)) ?? ""
        folderName = (try? c.decode(String.self, forKey: .folderName)) ?? ""
        displayName = optString(c, .displayName)
        count = optInt(c, .count) ?? 0
        coverPhotoId = optInt(c, .coverPhotoId)
        coverPhotoIdPortrait = optInt(c, .coverPhotoIdPortrait)
        coverOrient = optString(c, .coverOrient)
        releaseDate = optString(c, .releaseDate)
    }

    /// 由搜索结果构造（struct 已有自定义 init(from:)，抑制了成员构造器）
    init(id: Int) {
        self.id = id
    }
}

// MARK: - 影视条目
// 对应 /api/media?type=movie|tv 返回的 items 项
struct MediaItem: Identifiable, Codable, Sendable, Hashable {
    let id: Int
    var title: String = ""
    var year: Int? = nil
    var type: String = ""
    var filePath: String? = nil
    var posterImageId: Int? = nil
    var fanartImageId: Int? = nil
    var libraryId: Int? = nil
    /// 评分（后端 /api/media 返回，横版卡片右上角徽章用）
    var rating: Double? = nil
    /// 目录名：番号库的番号藏在这里（中文优先后的标题常不带番号）
    var folderName: String? = nil

    var subtitle: String {
        if let year, year > 0 { return String(year) }
        return ""
    }

    /// 番号（如 ABF-391）。从目录名里正则抠 —— 中文优先后的标题常常没有；
    /// 标题已含该番号时不重复显示（旧日文标题自带前缀）。
    /// 与网页端 MediaCard 同一套正则，两边观感对齐。
    var code: String? {
        guard let f = folderName, !f.isEmpty else { return nil }
        guard let r = f.range(of: "[A-Z]{2,6}-[0-9]{2,5}",
                              options: [.regularExpression, .caseInsensitive]) else { return nil }
        let code = String(f[r])
        if title.uppercased().contains(code.uppercased()) { return nil }
        return code
    }

    enum CodingKeys: String, CodingKey {
        case id, title, year, type, rating
        case filePath = "file_path"
        case posterImageId = "poster_image_id"
        case fanartImageId = "fanart_image_id"
        case libraryId = "library_id"
        case folderName = "folder_name"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        year = optInt(c, .year)
        type = (try? c.decode(String.self, forKey: .type)) ?? ""
        filePath = optString(c, .filePath)
        posterImageId = optInt(c, .posterImageId)
        fanartImageId = optInt(c, .fanartImageId)
        libraryId = optInt(c, .libraryId)
        rating = optDouble(c, .rating)
        folderName = optString(c, .folderName)
    }

    /// 由搜索结果构造（不依赖成员构造器，struct 已有自定义 init(from:)）
    init(id: Int, title: String = "", year: Int? = nil, type: String = "",
         filePath: String? = nil, posterImageId: Int? = nil, fanartImageId: Int? = nil, libraryId: Int? = nil,
         rating: Double? = nil, folderName: String? = nil) {
        self.id = id
        self.title = title
        self.year = year
        self.type = type
        self.filePath = filePath
        self.posterImageId = posterImageId
        self.fanartImageId = fanartImageId
        self.libraryId = libraryId
        self.rating = rating
        self.folderName = folderName
    }
}

// MARK: - 用户
// 对应 /api/auth/me、/api/auth/login 返回的 user
struct User: Codable, Sendable {
    let id: Int
    let username: String
    var displayName: String? = nil
    var role: String = "user"
    var enabled: Int = 1

    var isAdmin: Bool { role == "admin" }

    enum CodingKeys: String, CodingKey {
        case id, username, role, enabled
        case displayName = "display_name"
    }
}

// MARK: - 演员
struct Actor: Identifiable, Codable, Sendable {
    let id: String
    let name: String
    var role: String? = nil
    var thumbURL: URL? = nil
    /// 演员库 id。⚠️ 后端 media.go 2026-10-13 起在 actors 里输出 id（列表/详情两处），
    /// 老数据 / JSON 兜底分支没有这个字段 → 可选。详情页演员头像靠它跳演员页。
    var actorId: Int? = nil

    var initial: String { String((name.first ?? "?").uppercased()) }

    // ⚠️ 不能加 case id：String 型的 id 是 Identifiable 用的（= name），
    // 而 JSON 的 "id"（演员库数字 id）归 actorId —— raw value 必须唯一
    enum CodingKeys: String, CodingKey {
        case name, role
        case thumbURL = "thumb"
        case actorId = "id"
    }

    init(name: String, role: String? = nil, thumbURL: URL? = nil) {
        self.id = name
        self.name = name
        self.role = role
        self.thumbURL = thumbURL
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        id = name
        role = optString(c, .role)
        thumbURL = flexURL(c, .thumbURL)
        actorId = optInt(c, .actorId)
    }
}

// MARK: - 人物（人脸聚类）
// 对应 GET /api/persons 列表项（face_cluster_persons_* 分表，跨媒体库全局聚合）
struct Person: Identifiable, Codable, Sendable, Hashable {
    let id: Int
    var name: String = ""
    var faceCount: Int = 0
    var representativeFaceId: Int?
    var representativePhotoId: Int?

    /// 未命名的人物（聚类产物默认名为空）显示「未命名」
    var displayName: String { name.isEmpty ? "未命名" : name }

    enum CodingKeys: String, CodingKey {
        case id, name
        case faceCount = "face_count"
        case representativeFaceId = "representative_face_id"
        case representativePhotoId = "representative_photo_id"
    }
}

// MARK: - 演员库条目
// 对应 GET /api/actors 列表项。⚠️ 与上面内嵌的 Actor 区分：那个是影片详情里的
// {name, role, thumb}（ historically 没有 id），这个是演员库条目，必有 id。
struct ActorItem: Identifiable, Codable, Sendable, Hashable {
    let id: Int
    var name: String = ""
    var displayName: String?
    /// /raw?path= 相对地址，APIClient 取出时会 resolve 成完整 URL
    var thumbURL: URL? = nil
    var movieCount: Int = 0
    var seriesCount: Int = 0

    /// 展示名优先 display_name（后台人工改过的名），回退 name
    var title: String {
        if let d = displayName, !d.isEmpty { return d }
        return name
    }

    enum CodingKeys: String, CodingKey {
        case id, name
        case displayName = "display_name"
        case thumbURL = "thumb"
        case movieCount = "movie_count"
        case seriesCount = "series_count"
    }
}

// MARK: - 演员详情
// 对应 GET /api/actors/:id 的 actor 对象
struct ActorProfile: Identifiable, Decodable, Sendable {
    let id: Int
    var name: String = ""
    var displayName: String?
    var thumbURL: URL? = nil
    var biography: String?
    var birthday: String?
    var aliases: [String] = []
    var linkedActors: [ActorItem] = []

    var title: String {
        if let d = displayName, !d.isEmpty { return d }
        return name
    }

    enum CodingKeys: String, CodingKey {
        case id, name, biography, birthday, aliases
        case displayName = "display_name"
        case thumbURL = "thumb"
        case linkedActors = "linked_actors"
    }
}

// MARK: - 演员作品
// 对应 GET /api/actors/:id 的 movies[] / series[] 项。
// ⚠️ rating 后端是 *string（"8.5"），按 Double 解会 typeMismatch 整页挂掉
struct ActorWork: Identifiable, Decodable, Sendable {
    let id: Int
    var title: String = ""
    var year: Int?
    var rating: Double?
    var role: String?
    var libraryId: Int = 0
    var libraryName: String = ""
    /// 海报地址（后端已拼成 /raw?path= 相对地址，APIClient resolve）
    var posterURL: URL? = nil

    enum CodingKeys: String, CodingKey {
        case id, title, year, rating, role
        case libraryId = "library_id"
        case libraryName = "library_name"
        case posterURL = "poster_path"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        year = optInt(c, .year)
        role = optString(c, .role)
        libraryId = optInt(c, .libraryId) ?? 0
        libraryName = (try? c.decode(String.self, forKey: .libraryName)) ?? ""
        posterURL = flexURL(c, .posterURL)
        // rating：兼容 "8.5" / 8.5 / null
        if let d = try? c.decode(Double.self, forKey: .rating) {
            rating = d
        } else if let s = try? c.decode(String.self, forKey: .rating) {
            rating = Double(s)
        }
    }
}

// MARK: - 影视详情
// 对应 GET /api/media/:id 返回的 gin.H map
struct MediaDetail: Identifiable, Decodable, Sendable {
    let id: Int
    let type: String           // movie / tv
    let title: String
    var originalTitle: String? = nil
    var year: Int? = nil
    var plot: String? = nil
    var runtime: Int? = nil    // 分钟
    var rating: Double? = nil
    var genres: [String] = []
    var releaseDate: String? = nil
    var director: String? = nil
    var studio: String? = nil
    var country: String? = nil
    var certification: String? = nil
    var actors: [Actor] = []
    var posterImageId: Int? = nil
    var fanartImageId: Int? = nil
    var filePath: String? = nil
    var videoFiles: [String] = []
    var stills: [URL] = []       // 剧照（relative /raw?path=）
    var folderPath: String? = nil
    var issues: [String] = []

    var posterURL: URL? = nil     // 客户端拼好
    var backdropURL: URL? = nil   // 客户端拼好

    var playable: Bool { !(videoFiles.isEmpty) }

    var runtimeText: String? {
        guard let runtime, runtime > 0 else { return nil }
        let h = runtime / 60, m = runtime % 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    /// 单条解码：actors 后端可能是 [{name,role,...}] 或 ["name"]，兼容两种
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        type = (try? c.decode(String.self, forKey: .type)) ?? "movie"
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        originalTitle = optString(c, .originalTitle)
        year = optInt(c, .year)
        plot = optString(c, .plot)
        runtime = optInt(c, .runtime)
        rating = optDouble(c, .rating)
        releaseDate = optString(c, .releaseDate)
        director = optString(c, .director)
        studio = optString(c, .studio)
        country = optString(c, .country)
        certification = optString(c, .certification)
        folderPath = optString(c, .folderPath)
        genres = (try? c.decode([String].self, forKey: .genres)) ?? []

        // actors：优先对象数组，退化纯字符串数组
        if let arr = try? c.decode([Actor].self, forKey: .actors) {
            actors = arr
        } else if let names = try? c.decode([String].self, forKey: .actors) {
            actors = names.map { Actor(name: $0) }
        }

        posterImageId = optInt(c, .posterImageId)
        fanartImageId = optInt(c, .fanartImageId)
        filePath = optString(c, .filePath)
        videoFiles = (try? c.decode([String].self, forKey: .videoFiles)) ?? []
        if let s = try? c.decode([String].self, forKey: .stills) {
            stills = s.compactMap { URL(string: $0) }
        }
        if let iss = try? c.decode([String].self, forKey: .issues) {
            issues = iss
        } else if let issStr = optString(c, .issues) {
            if let data = issStr.data(using: .utf8),
               let arr = try? JSONDecoder().decode([String].self, from: data) {
                issues = arr
            }
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, type, title
        case originalTitle = "original_title"
        case year, plot, runtime, rating, genres
        case releaseDate = "release_date"
        case director, studio, country, certification
        case actors
        case posterImageId = "poster_image_id"
        case fanartImageId = "fanart_image_id"
        case filePath = "file_path"
        case videoFiles = "video_files"
        case stills, folderPath = "folder_path"
        case issues
    }
}

// MARK: - 拍摄集
struct Shoot: Identifiable, Codable, Sendable, Hashable {
    let id: Int
    var libraryId: Int = 0
    var folderName: String = ""
    var displayName: String? = nil
    var hasCover: Bool = false
    var videoCount: Int = 0
    var photoCount: Int = 0
    var totalSize: Int64 = 0
    /// ⚠️ SQLite 里 total_duration 是 REAL（ffprobe 给的是浮点秒），
    /// 必须按 Double 解码 —— 声明成 Int 会因为 893.74 这种值直接 typeMismatch 整页挂掉
    var totalDuration: Double = 0
    var folderMtime: Int64 = 0

    var title: String { displayName?.isEmpty == false ? displayName! : folderName }

    /// 尾部统计标记，如 "[104P1V-5.11G]" / "[104P+1V／7.44GB]"（原样含方括号）。
    /// 站点目录名把张数/视频数/体积塞在末尾，摘出来当徽标比混在标题里好读。
    /// 没有（或不是以 [ 开头的尾部标记）返回 nil。
    var specTag: String? {
        let t = title
        // 尾部标记：以 ] 结尾，且最后一个 [ 在它前面
        guard t.hasSuffix("]"),
              let close = t.lastIndex(of: "]"),
              let open = t.lastIndex(of: "["),
              open < close else { return nil }
        return String(t[open...close])
    }

    /// 展示用标题：站点目录名直接上屏很难读
    ///（"www.98T.la@森萝财团 写真 内部 蜃楼-02E4K [104P1V-5.11G]"）。
    /// 剥掉「站点@」前缀 + 尾部统计标记，剩下的才是内容名。
    /// 用户手动改过名（display_name）的不受影响：规则很保守，不带 @ / 不带
    /// 尾部方括号的名字原样返回。
    var displayTitle: String {
        var name = title.strippingSitePrefix
        if let tag = specTag {
            name = name.replacingOccurrences(of: tag, with: "")
        }
        return name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case libraryId = "library_id"
        case folderName = "folder_name"
        case displayName = "display_name"
        case hasCover = "has_cover"
        case videoCount = "video_count"
        case photoCount = "photo_count"
        case totalSize = "total_size"
        case totalDuration = "total_duration"
        case folderMtime = "folder_mtime"
    }
}

struct ShootFile: Identifiable, Codable, Sendable, Hashable {
    let id: Int
    var shootId: Int = 0
    var libraryId: Int = 0
    var filename: String = ""
    var fileSize: Int64 = 0
    var mediaType: String = "video"  // video / image
    var width: Int? = nil
    var height: Int? = nil
    /// ⚠️ 同 Shoot.totalDuration：shoot_files.duration 在库里 100% 是 REAL，按 Double 解
    var duration: Double? = nil
    var hasThumb: Int = 0

    var isVideo: Bool { mediaType == "video" }
    var sizeText: String {
        if fileSize < 1024 { return "\(fileSize) B" }
        if fileSize < 1024*1024 { return String(format: "%.1f KB", Double(fileSize)/1024) }
        if fileSize < 1024*1024*1024 { return String(format: "%.1f MB", Double(fileSize)/(1024*1024)) }
        return String(format: "%.2f GB", Double(fileSize)/(1024*1024*1024))
    }
    var durationText: String? {
        guard let d = duration, d > 0 else { return nil }
        let t = Int(d)
        let h = t/3600, m = (t%3600)/60, s = t%60
        return h > 0 ? "\(h):\(String(format: "%02d:%02d", m, s))" : "\(m):\(String(format: "%02d", s))"
    }
    var dimensionText: String? {
        guard let w = width, let h = height, w > 0, h > 0 else { return nil }
        return "\(w)×\(h)"
    }
    /// 卡片标题 / 播放器标题：剥掉站点目录名前缀、去掉扩展名。
    /// 原来这串逻辑内联在 ShootDetailView 里；加了 VidHub 外播后有两处要用
    /// （内置播放 + 外播的 filename），提到模型上免得两处走偏。
    var displayName: String {
        filename.strippingSitePrefix.deletingPathExtension
    }

    enum CodingKeys: String, CodingKey {
        case id
        case shootId = "shoot_id"
        case libraryId = "library_id"
        case filename
        case fileSize = "file_size"
        case mediaType = "media_type"
        case width, height, duration
        case hasThumb = "has_thumb"
    }
}

struct ShootDetail: Decodable, Sendable {
    let shoot: Shoot
    let videos: [ShootFile]
}

// MARK: - 短视频
struct ShortVideo: Identifiable, Codable, Sendable, Hashable {
    let id: Int
    var poolId: Int = 0
    var fileName: String = ""
    var title: String? = nil
    var year: Int? = nil
    /// ⚠️ 同 Shoot.totalDuration：short_videos.duration 在库里 100% 是 REAL，按 Double 解
    var duration: Double? = nil
    var fileSize: Int64 = 0
    var width: Int? = nil
    var height: Int? = nil
    var filePath: String? = nil
    var posterUrl: String? = nil
    var gifUrl: String? = nil
    var previewUrl: String? = nil
    var hasPoster: Bool = false
    var hasPreview: Bool = false

    var titleText: String { title?.isEmpty == false ? title! : fileName }

    var durationText: String? {
        guard let d = duration, d > 0 else { return nil }
        let t = Int(d)
        let h = t/3600, m = (t%3600)/60, s = t%60
        return h > 0 ? "\(h):\(String(format: "%02d:%02d", m, s))" : "\(m):\(String(format: "%02d", s))"
    }
    var dimensionText: String? {
        guard let w = width, let h = height, w > 0, h > 0 else { return nil }
        return "\(w)×\(h)"
    }

    enum CodingKeys: String, CodingKey {
        case id
        case poolId = "pool_id"
        case fileName = "file_name"
        case title, year, duration, fileSize = "file_size"
        case filePath = "file_path"
        case width, height
        case posterUrl = "posterUrl"
        case gifUrl = "gifUrl"
        case previewUrl = "previewUrl"
        case hasPoster = "hasPoster"
        case hasPreview = "hasPreview"
    }
}

struct ShortPool: Identifiable, Codable, Sendable, Hashable {
    let id: Int
    var name: String = ""
    var itemCount: Int = 0
    var enabled: Int = 1
    /// 池封面（后端 = 该池最新一支视频的静态海报 URL，相对路径 /raw?path=…）。
    /// nil = 空池或没抽帧，前端走渐变占位
    var coverUrl: String? = nil

    enum CodingKeys: String, CodingKey {
        case id, name
        case itemCount = "item_count"
        case enabled
        case coverUrl = "cover_url"
    }
}

// MARK: - 搜索结果项
// 对应 /api/search 返回的单条；type 区分 movie/tv/album/photo/shoot
//
// ⚠️⚠️ 后端各类型返回的字段差别极大，解码必须全部容错：
//   · media（movie/tv）→ 有 title / type / year / rating / poster_image_id
//   · 相册 photo_albums   → 只有 folder_name / display_name / cover_photo_id / photo_count，**没有 title、type**
//   · 拍摄集 shoots       → 同上，也没有 title、type
//   · 照片（Meili / LIKE）→ 只有 file_name / folder_path / has_thumb / album_id，**没有 title、type**
// 用自动合成的 init(from:) 时，任何一个缺失的非 Optional 字段都会让整批结果解码失败
//（表现为「搜索失败」或结果恒空），所以这里手写 decodeIfPresent 兜底。
struct SearchItem: Identifiable, Codable, Sendable {
    let id: Int
    var type: String = ""
    var title: String = ""
    var year: Int? = nil
    var rating: Double? = nil
    var libraryId: Int? = nil
    var libraryName: String? = nil
    var posterImageId: Int? = nil
    var coverPhotoId: Int? = nil
    var coverPhotoIdPortrait: Int? = nil
    var hasThumb: Int? = nil
    var photoCount: Int? = nil
    var albumId: Int? = nil
    var folderName: String? = nil
    var displayName: String? = nil
    var fileName: String? = nil

    /// 纯客户端标记：这条是**语义匹配**（CLIP 以文搜图）命中的，不是关键词命中的。
    /// ⚠️ 后端不返回这个字段，只有搜索页自己会写。
    /// 当前语义结果单独存在 SearchView.semanticItems 里（异步追加、单独成组），
    /// 这个标记留着做来源识别：哪天把它们并回 results，分组还得靠它区分。
    var semanticHit: Bool = false

    var titleText: String {
        if !title.isEmpty { return title }
        if let d = displayName, !d.isEmpty { return d }
        if let f = folderName, !f.isEmpty { return f }
        return fileName ?? ""
    }

    enum CodingKeys: String, CodingKey {
        case id, type, title, year, rating
        case libraryId = "library_id"
        case libraryName = "library_name"
        case posterImageId = "poster_image_id"
        case coverPhotoId = "cover_photo_id"
        case coverPhotoIdPortrait = "cover_photo_id_portrait"
        case hasThumb = "has_thumb"
        case photoCount = "photo_count"
        case albumId = "album_id"
        case folderName = "folder_name"
        case displayName = "display_name"
        case fileName = "file_name"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // id 可能是 123 也可能是 123.0（Meili 文档里的数值），两种都接
        if let v = try? c.decode(Int.self, forKey: .id) {
            id = v
        } else if let d = try? c.decode(Double.self, forKey: .id) {
            id = Int(d)
        } else if let s = try? c.decode(String.self, forKey: .id) {
            id = Int(s) ?? 0
        } else {
            id = 0
        }
        type = (try? c.decodeIfPresent(String.self, forKey: .type)) ?? ""
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
        year = SearchItem.decodeInt(c, .year)
        rating = SearchItem.decodeDouble(c, .rating)
        libraryId = SearchItem.decodeInt(c, .libraryId)
        libraryName = try? c.decodeIfPresent(String.self, forKey: .libraryName)
        posterImageId = SearchItem.decodeInt(c, .posterImageId)
        coverPhotoId = SearchItem.decodeInt(c, .coverPhotoId)
        coverPhotoIdPortrait = SearchItem.decodeInt(c, .coverPhotoIdPortrait)
        hasThumb = SearchItem.decodeInt(c, .hasThumb)
        photoCount = SearchItem.decodeInt(c, .photoCount)
        albumId = SearchItem.decodeInt(c, .albumId)
        folderName = try? c.decodeIfPresent(String.self, forKey: .folderName)
        displayName = try? c.decodeIfPresent(String.self, forKey: .displayName)
        fileName = try? c.decodeIfPresent(String.self, forKey: .fileName)
    }

    /// 数值字段在不同分支里可能是 Int / Double / String（"12"），统一兜一遍
    private static func decodeInt(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Int? {
        if let v = try? c.decode(Int.self, forKey: key) { return v }
        if let d = try? c.decode(Double.self, forKey: key) { return Int(d) }
        if let s = try? c.decode(String.self, forKey: key) { return Int(s) }
        return nil
    }

    private static func decodeDouble(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Double? {
        if let v = try? c.decode(Double.self, forKey: key) { return v }
        if let s = try? c.decode(String.self, forKey: key) { return Double(s) }
        return nil
    }

    /// 由调用方回填类型：相册/拍摄集/照片的返回里根本没有 type 字段
    mutating func fillType(_ fallback: String) {
        if type.isEmpty { type = fallback }
    }

    /// 手工构造（语义搜索结果 → SearchItem）。
    /// ⚠️ 本 struct 自带 init(from:)，Swift **不再合成** memberwise init，
    /// 所以要显式提供一个；其余字段用声明时的默认值。
    init(id: Int) {
        self.id = id
    }
}

// MARK: - 搜索结果 → 浏览页模型
// 搜索接口只返回一套扁平字段，而四类内容的展示卡（MediaCard / AlbumCard /
// ShootCard / 照片瀑布流）分别吃 MediaItem / Album / Shoot / Photo。
// 转换集中放在这里，搜索页就能**直接复用浏览页的卡片组件**，
// 不用再维护一版「搜索专用卡」—— 那正是两边观感分叉的根源。
extension SearchItem {
    func asMediaItem() -> MediaItem {
        var m = MediaItem(id: id)
        m.title = titleText
        m.year = year
        m.type = (type == "tv" || type == "series") ? "tv" : "movie"
        m.posterImageId = posterImageId
        m.libraryId = libraryId
        m.rating = rating
        m.folderName = folderName
        return m
    }

    func asAlbum() -> Album {
        var a = Album(id: id)
        a.folderName = folderName ?? titleText
        a.displayName = displayName
        a.count = photoCount ?? 0
        a.coverPhotoId = coverPhotoId
        a.coverPhotoIdPortrait = coverPhotoIdPortrait
        return a
    }

    func asShoot() -> Shoot {
        var s = Shoot(id: id)
        s.folderName = folderName ?? titleText
        s.displayName = titleText
        s.libraryId = libraryId ?? 0
        return s
    }
}

// MARK: - CLIP 语义搜索结果（以文搜图）
// 对应 GET /api/photos/semantic-search 的 results[]。
// ⚠️ 只在**照片**上工作：语义向量来自 CLIP，影视/相册/拍摄集没有。
struct SemanticPhotoResult: Identifiable, Decodable, Sendable {
    let id: Int
    var fileName: String?
    var folderPath: String?
    var libraryId: Int?
    var albumId: Int?
    /// 余弦相似度 [0,1]，后端已按它降序排好
    var similarity: Double?
    var aestheticScore: Double?

    enum CodingKeys: String, CodingKey {
        case id
        case fileName = "file_name"
        case folderPath = "folder_path"
        case libraryId = "library_id"
        case albumId = "album_id"
        case similarity
        case aestheticScore = "aesthetic_score"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // 同 SearchItem：id 可能是 123 / 123.0 / "123"
        if let v = try? c.decode(Int.self, forKey: .id) {
            id = v
        } else if let d = try? c.decode(Double.self, forKey: .id) {
            id = Int(d)
        } else if let s = try? c.decode(String.self, forKey: .id) {
            id = Int(s) ?? 0
        } else {
            id = 0
        }
        fileName = try? c.decodeIfPresent(String.self, forKey: .fileName)
        folderPath = try? c.decodeIfPresent(String.self, forKey: .folderPath)
        libraryId = try? c.decodeIfPresent(Int.self, forKey: .libraryId)
        albumId = try? c.decodeIfPresent(Int.self, forKey: .albumId)
        similarity = try? c.decodeIfPresent(Double.self, forKey: .similarity)
        aestheticScore = try? c.decodeIfPresent(Double.self, forKey: .aestheticScore)
    }
}
