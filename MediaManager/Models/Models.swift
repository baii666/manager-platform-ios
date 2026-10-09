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
struct RecentItem: Identifiable, Codable, Sendable {
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
struct Library: Identifiable, Codable, Sendable {
    let id: Int
    let name: String
    let type: String // movie / series / photo / shoot / mixed
    var itemCount: Int = 0
    var albumCount: Int? = nil
    var thumbURL: URL? = nil

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
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        type = (try? c.decode(String.self, forKey: .type)) ?? ""
        itemCount = optInt(c, .itemCount) ?? 0
        albumCount = optInt(c, .albumCount)
        thumbURL = flexURL(c, .thumbURL)
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
}

// MARK: - 影视条目
// 对应 /api/media?type=movie|tv 返回的 items 项
struct MediaItem: Identifiable, Codable, Sendable {
    let id: Int
    var title: String = ""
    var year: Int? = nil
    var type: String = ""
    var filePath: String? = nil
    var posterImageId: Int? = nil
    var fanartImageId: Int? = nil
    var libraryId: Int? = nil

    var subtitle: String {
        if let year, year > 0 { return String(year) }
        return ""
    }

    enum CodingKeys: String, CodingKey {
        case id, title, year, type
        case filePath = "file_path"
        case posterImageId = "poster_image_id"
        case fanartImageId = "fanart_image_id"
        case libraryId = "library_id"
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
