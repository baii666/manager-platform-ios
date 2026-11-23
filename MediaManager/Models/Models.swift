import Foundation
import CoreGraphics

// MARK: - 资产类型
// 与后端 asset_type 对齐：四类内容共用一套资产模型
// media=影视 / photo=写真 / short=短视频
enum AssetType: String, Codable, CaseIterable, Identifiable, Sendable {
    case media
    case photo
    case short

    var id: String { rawValue }

    /// 人脸探测的 medium（后端 /api/video-face-probe 只认这三个）。
    /// photo 是静态图库、没有视频画面，返回 nil 让播放器不显示检测按钮。
    var faceProbeMedium: String? {
        switch self {
        case .media: return "media"
        case .short: return "short_video"
        case .photo: return nil
        }
    }

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
        }
    }

    var systemImage: String {
        switch self {
        case .media: return "film"
        case .photo: return "camera"
        case .short: return "play.rectangle.fill"
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
    /// 文件路径（media=video_file、short=file_path、photo=file_path）
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
    /// 是否走 KSPlayer(FFmpeg) 内核。MKV/AVI/WMV 等 AVPlayer 不认的容器、
    /// 以及 hev1/DTS/AC3 等解不了的编码走 KSPlayer 直连原始流；其余走系统硬解。
    let usesKSPlayer: Bool

    /// 显式初始化器：编译器合成的成员构造器对带默认值的 `let` 在跨文件调用不稳定，
    /// 这里明确列出全部参数，usesKSPlayer 带默认值 false，既有构造点无需改动。
    init(url: URL, title: String, assetType: String?, assetID: Int?,
         startAt: Double, timeOffset: Double, knownDuration: Double?,
         sourcePath: String?, usesKSPlayer: Bool = false) {
        self.url = url
        self.title = title
        self.assetType = assetType
        self.assetID = assetID
        self.startAt = startAt
        self.timeOffset = timeOffset
        self.knownDuration = knownDuration
        self.sourcePath = sourcePath
        self.usesKSPlayer = usesKSPlayer
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
    let type: String // movie / series / photo / mixed
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
    var shortCount: Int = 0

    var totalContent: Int { movieCount + seriesCount + photoCount }
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

    /// 🔴 云端图片所属目录（后端 cloud_items.dir_path），看图器「打开所在文件夹」用。
    /// 仅 CloudItem.asPhoto 填入；本地照片为 nil → 看图器不显示文件夹按钮。
    /// ⚠️ 纯客户端字段，不在 CodingKeys 里，不参与 Codable。
    var cloudDirPath: String? = nil

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
    /// 聚类人物 id（face_cluster_map_040）。未聚类的脸为 nil —— 别用
    /// photo_faces.person_id，那是个全 NULL 的遗留列。
    var personId: Int? = nil
    var personName: String? = nil
    var personFaceCount: Int? = nil

    /// 检测置信度百分比文案（如 "87%"）
    var scoreText: String { String(format: "%.0f%%", detScore * 100) }

    /// 直接构造人物页所需的目标；未聚类时返回 nil
    var person: Person? {
        guard let personId else { return nil }
        var p = Person(id: personId)
        p.name = personName ?? ""
        p.faceCount = personFaceCount ?? 0
        // 从看图器点头像进来时没有「代表脸」字段，就把被点的这张脸当头像兜底，
        // 人物页顶部信息区不会是空白占位。人物列表入口由后端给真正的代表脸。
        p.representativeFaceId = id
        return p
    }

    enum CodingKeys: String, CodingKey {
        case id
        case bboxX1 = "bbox_x1"
        case bboxY1 = "bbox_y1"
        case bboxX2 = "bbox_x2"
        case bboxY2 = "bbox_y2"
        case detScore = "det_score"
        case personId = "person_id"
        case personName = "person_name"
        case personFaceCount = "person_face_count"
    }
}

// MARK: - 播放中点按钮的人脸探测结果
// POST /api/video-face-probe 的 data 段。检测当前画面的人脸并写入 fr_* 统一人脸系统，
// 之后在人物页可见。written 是各表实际写入条数，entities 才是「登记了几个人脸实体」。
struct FaceProbeResult: Decodable, Sendable {
    var ok: Bool = false
    var medium: String = ""
    var mediaID: Int = 0
    var t: Double = 0
    var frames: Int = 0
    var faces: Int = 0
    var targets: Int = 0
    var planned: Int = 0
    var plan: [FaceProbePlan] = []
    var written: FaceProbeWritten? = nil

    /// 实际登记的人脸实体数（toast 用；没写库时返回 0）
    var entities: Int { written?.entities ?? 0 }
    /// 命中已有 illustrator/人物 的名字，去重保序
    var matchedNames: [String] {
        var seen = Set<String>()
        return plan.compactMap { $0.personName }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    enum CodingKeys: String, CodingKey {
        case ok, medium, t, frames, faces, targets, planned, plan, written
        case mediaID = "media_id"
    }
}

struct FaceProbePlan: Decodable, Sendable {
    /// 后端未命中已有簇时给 null / 0 —— 必须可选，否则一条 null 让整包解码失败
    var personRef: Int? = nil
    var personName: String? = nil
    var sim: Double = 0

    enum CodingKeys: String, CodingKey {
        case sim
        case personRef = "person_ref"
        case personName = "person_name"
    }
}

struct FaceProbeWritten: Decodable, Sendable {
    var hits: Int = 0
    var cands: Int = 0
    var links: Int = 0
    var entities: Int = 0
    var occ: Int = 0
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

// MARK: - 相册视频
// 对应 GET /api/album-videos/:albumId 的 items（Go album_videos 表）。
// 方案B：视频独立于 photos 存储，通过 (library_id, folder_path) 关联到相册。
// duration 后端是 sql.NullFloat64，JSON 可能是 number 也可能是 null → 必须 Double?
struct AlbumVideo: Identifiable, Codable, Sendable {
    let id: Int
    var libraryId: Int? = nil
    var folderPath: String = ""
    var folderName: String? = nil
    var filePath: String = ""
    var fileName: String = ""
    var fileSize: Int64? = nil
    var width: Int? = nil
    var height: Int? = nil
    var duration: Double? = nil
    var videoCodec: String? = nil
    var audioCodec: String? = nil
    var bitrate: Int64? = nil
    var hasThumb: Int? = nil
    /// 后端补的 /api/album-video/:id 直链（App 内播放不用它，走 resolvePlayback）
    var playUrl: String? = nil
    /// 静态封面（WebP）/ 动态封面（animated WebP），后端 /api/album-videos 已返回
    /// /raw?path=... 相对地址，由 APIClient.resolve 转绝对 URL。has_thumb 不是封面判据。
    var coverUrl: String? = nil
    var motionUrl: String? = nil
    /// 服务端随列表下发的 ffmpeg 口径探测结果（playback_info 缓存，零探测）。
    var probeCodec: String? = nil
    var probeTag: String? = nil

    /// 卡片标题：优先文件夹名（更像片名），没有才用文件名
    var title: String {
        if let folderName, !folderName.isEmpty { return folderName }
        return fileName
    }

    var durationText: String? {
        guard let duration, duration.isFinite, duration > 0 else { return nil }
        let total = Int(duration.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case libraryId = "library_id"
        case folderPath = "folder_path"
        case folderName = "folder_name"
        case filePath = "file_path"
        case fileName = "file_name"
        case fileSize = "file_size"
        case width, height, duration
        case videoCodec = "video_codec"
        case audioCodec = "audio_codec"
        case bitrate
        case hasThumb = "has_thumb"
        case playUrl = "play_url"
        case coverUrl = "cover_url"
        case motionUrl = "motion_url"
        case probeCodec = "probe_codec"
        case probeTag = "probe_tag"
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
        // /api/media/:id 的 thumb 是未编码的 Windows 路径（中文 / 空格 / 反斜杠），
        // URL(string:) 偶尔解析不了；换成正斜杠 + 百分号编码再试一次，别丢掉头像
        thumbURL = flexURL(c, .thumbURL) ?? Self.looseThumbURL(c, .thumbURL)
        actorId = optInt(c, .actorId)
    }

    private static func looseThumbURL<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> URL? {
        guard let s = optString(c, key), !s.isEmpty else { return nil }
        let cleaned = s.replacingOccurrences(of: "\\", with: "/")
        guard let encoded = cleaned.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        return URL(string: encoded)
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

// MARK: - 人物档案（thenude 匹配结果）
// 对应 GET /api/person-profiles/:id。24,471 个聚类人物里约 933 个匹配到了外部档案，
// 其余人物也返回 200，但 meta 为空对象 —— 用 hasDetails 判断有没有可展示的资料。
// meta 是后端把 meta_json 解析后的对象，字段值混合字符串与数字，见 PersonMetaValue。
struct ProfileFact: Identifiable, Hashable {
    let label: String
    let value: String
    var id: String { label }
}

struct ProfileSite: Identifiable, Hashable {
    let name: String
    let count: Int
    var id: String { name }
}

struct PersonProfile: Codable, Sendable, Hashable {
    let id: Int
    var name: String = ""
    var faceCount: Int = 0
    var representativeFaceId: Int?
    var thenudeId: Int?
    var thenudeName: String = ""
    var thenudeSim: Double = 0
    var profileURL: String = ""
    var avatarURL: String = ""
    var meta: [String: PersonMetaValue] = [:]
    var updatedAt: String = ""

    var displayName: String {
        let n = thenudeName.isEmpty ? name : thenudeName
        return n.isEmpty ? "未命名" : n
    }

    enum CodingKeys: String, CodingKey {
        case id, name, meta
        case faceCount = "face_count"
        case representativeFaceId = "representative_face_id"
        case thenudeId = "thenude_id"
        case thenudeName = "thenude_name"
        case thenudeSim = "thenude_sim"
        case profileURL = "profile_url"
        case avatarURL = "avatar_url"
        case updatedAt = "updated_at"
    }
}

/// meta_json 的值有字符串也有数字（thenude_id / face_sim），统一收成字符串，
/// 展示层只读 text，不用再判断原始类型；null / 空值统一成 ""。
struct PersonMetaValue: Codable, Sendable, Hashable {
    let text: String

    init(_ text: String) { self.text = text }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) {
            text = s
        } else if let i = try? c.decode(Int.self) {
            text = "\(i)"
        } else if let d = try? c.decode(Double.self) {
            text = String(format: "%g", d)
        } else if let b = try? c.decode(Bool.self) {
            text = b ? "true" : "false"
        } else {
            text = ""
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(text)
    }
}

extension PersonProfile {
    /// 取一段非空文本；脏串里的空字段按「没有」处理
    func metaText(_ key: String) -> String? {
        guard let raw = meta[key]?.text.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        return raw
    }

    /// thenude 抓下来的字段常写成「主值 | 备选 / 又一个」，取第一段够用且不撑爆一行
    private func firstSegment(_ key: String) -> String? {
        guard let raw = metaText(key) else { return nil }
        return raw.split(whereSeparator: { "|/".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }

    /// 别名：去掉与本人同名/重复项，最多 4 个，多了补个总数
    var aliasesText: String? {
        guard let raw = metaText("aka") else { return nil }
        let me = displayName.lowercased()
        var seen = Set<String>()
        let list = raw.split(separator: ",").compactMap { part -> String? in
            let v = String(part).trimmingCharacters(in: .whitespaces)
            guard !v.isEmpty, v.lowercased() != me,
                  seen.insert(v.lowercased()).inserted else { return nil }
            return v
        }
        guard !list.isEmpty else { return nil }
        let head = list.prefix(4).joined(separator: "、")
        return list.count > 4 ? "\(head) 等 \(list.count) 个" : head
    }

    /// "??-07-1997 | July, 1997 / Country: Ukraine" → "July, 1997"
    var bornText: String? {
        guard let raw = metaText("born") else { return nil }
        let parts = raw.split(whereSeparator: { "|/".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return parts.first { !$0.contains("?") && $0.contains(where: { $0.isNumber }) }
            ?? parts.first
    }

    var birthplaceText: String? { metaText("birthplace") ?? metaText("country") }

    /// "177 cm, 5 ft 10 in | 1.78 m" → "177 cm"
    var heightText: String? {
        guard let seg = firstSegment("height") else { return nil }
        return seg.split(separator: ",").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? seg
    }

    var weightText: String? { firstSegment("weight") }

    /// "34C-24-36 / 88-60-92 | 86-61-91" → "34C-24-36"
    var measurementsText: String? { firstSegment("measurements") }

    var appearanceText: String? {
        join([metaText("hair_colour"), metaText("eye_colour").map { "\($0) eyes" }])
    }

    var bodyTypeText: String? {
        join([metaText("body_type"), metaText("ethnicity")])
    }

    var sourceURL: URL? { profileURL.isEmpty ? nil : URL(string: profileURL) }

    // MARK: 网页版 PersonProfileInfo 同款资料（左栏字段表）
    /// 网页版 hasProfileMeta：meta 里有任意非空值就算挂了档案（徽章 / 空态判据）
    var hasProfileMeta: Bool {
        meta.values.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// 网页版 first(v)：thenude 的字段常写成「主值 | 备选 / 又一个」，只取第一段
    func firstMeta(_ key: String) -> String? {
        guard let raw = metaText(key) else { return nil }
        let v = raw.split(separator: "|").first.map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        } ?? ""
        return v.isEmpty ? nil : v
    }

    /// 网页版关键数字三格：身高 / 三围 / 族裔（缺值占位「—」）
    var topFacts: [ProfileFact] {
        [("身高", firstMeta("height")),
         ("三围", firstMeta("measurements")),
         ("族裔", firstMeta("ethnicity"))]
            .map { ProfileFact(label: $0.0, value: $0.1 ?? "—") }
    }

    /// 网页版 FIELD_LABELS 17 项字段表：只显示有值的行
    var profileFields: [ProfileFact] {
        let keys: [(String, String)] = [
            ("born", "出生"), ("birthplace", "出生地"), ("country", "国家"),
            ("nationality", "国籍"), ("ethnicity", "族裔"), ("height", "身高"),
            ("weight", "体重"), ("measurements", "三围"), ("cup", "罩杯"),
            ("breasts", "胸型"), ("eye_colour", "眼睛"), ("hair_colour", "头发"),
            ("body_type", "体型"), ("years_active", "活跃年份"), ("career", "职业"),
            ("tattoos", "纹身"), ("piercings", "穿孔"),
        ]
        return keys.compactMap { pair in
            guard let v = firstMeta(pair.0) else { return nil }
            return ProfileFact(label: pair.1, value: v)
        }
    }

    /// 站点串 "metart(6), femjoy(1)" → 按套图数倒序（网页版收录站点胶囊）
    var siteTags: [ProfileSite] {
        guard let raw = metaText("sites") else { return [] }
        let list: [ProfileSite] = raw.split(separator: ",").compactMap { part in
            let s = String(part).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty else { return nil }
            var name = s
            var count = 0
            if s.hasSuffix(")"), let open = s.lastIndex(of: "(") {
                let inside = String(s[s.index(after: open)..<s.index(before: s.endIndex)])
                if let n = Int(inside.trimmingCharacters(in: .whitespaces)) {
                    count = n
                    name = String(s[..<open]).trimmingCharacters(in: .whitespaces)
                }
            }
            name = name.replacingOccurrences(of: "%20", with: " ")
            return ProfileSite(name: name.removingPercentEncoding ?? name, count: count)
        }
        return list.sorted { $0.count > $1.count }
    }

    var descriptionText: String? { metaText("description") }

    /// 档案头像原图外链（meta.avatar_url 优先，顶层 avatar_url 兜底）
    var avatarSourceURL: URL? {
        if let s = firstMeta("avatar_url") ?? metaText("avatar_url"),
           let u = URL(string: s), u.scheme != nil { return u }
        return nil
    }

    /// 有可展示的结构化资料才给「资料」入口，避免空档案点开一片空白
    var hasDetails: Bool {
        aliasesText != nil || bornText != nil || birthplaceText != nil
            || heightText != nil || weightText != nil || measurementsText != nil
            || appearanceText != nil || bodyTypeText != nil
    }

    private func join(_ parts: [String?]) -> String? {
        let vals = parts.compactMap { $0 }
        return vals.isEmpty ? nil : vals.joined(separator: " · ")
    }
}

// MARK: - 人物相册（网页版人物资料页「相册」tab）
/// GET /api/persons/:id/albums 返回项：某人脸簇的照片分布在哪些相册里（只读聚合）
struct PersonAlbum: Identifiable, Codable, Sendable, Hashable {
    let id: Int
    var name: String = ""
    var folderName: String = ""
    var folderPath: String = ""
    var libraryId: Int = 0
    /// 相册本身的照片总数
    var photoCount: Int = 0
    /// 该人物在这个相册里命中的照片数
    var matched: Int = 0
    /// 相册官方横版封面（与相册列表页同一口径，不是人物命中的照片）
    var coverPhotoId: Int = 0
    /// 相册官方竖版封面；部分相册只有横版或只有竖版，取用时双向兜底
    var coverPhotoIdPortrait: Int = 0
    /// 相册默认展示方向：landscape / portrait
    var coverOrient: String = ""

    var title: String { name.isEmpty ? folderName : name }

    enum CodingKeys: String, CodingKey {
        case id, name
        case folderName = "folder_name"
        case folderPath = "folder_path"
        case libraryId = "library_id"
        case photoCount = "photo_count"
        case matched
        case coverPhotoId = "cover_photo_id"
        case coverPhotoIdPortrait = "cover_photo_id_portrait"
        case coverOrient = "cover_orient"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        folderName = (try? c.decode(String.self, forKey: .folderName)) ?? ""
        folderPath = (try? c.decode(String.self, forKey: .folderPath)) ?? ""
        libraryId = (try? c.decode(Int.self, forKey: .libraryId)) ?? 0
        photoCount = (try? c.decode(Int.self, forKey: .photoCount)) ?? 0
        matched = (try? c.decode(Int.self, forKey: .matched)) ?? 0
        coverPhotoId = (try? c.decode(Int.self, forKey: .coverPhotoId)) ?? 0
        coverPhotoIdPortrait = (try? c.decode(Int.self, forKey: .coverPhotoIdPortrait)) ?? 0
        coverOrient = (try? c.decode(String.self, forKey: .coverOrient)) ?? ""
    }
}

// MARK: - 人物视频关联
// 对应 GET /api/person-media-hub/videos 的 items 项。
// 🔴 只含人工复核 verdict='confirmed' 的正式关联；候选不在这个接口里。
// cover_url / backdrop_url 后端给的是相对路径（/media-cover?path=...），
// APIClient 取出时 resolve 成完整 URL（与 ActorItem.thumbURL 同一口径）。
/// 人物照片按媒体库的分布（GET /api/persons/:id/library-breakdown）
struct PersonLibraryStat: Identifiable, Codable, Sendable, Hashable {
    let libraryId: Int
    var name: String = ""
    var type: String = ""
    var count: Int = 0

    var id: Int { libraryId }

    enum CodingKeys: String, CodingKey {
        case libraryId = "library_id"
        case name, type, count
    }
}

/// 人物三个 tab 各自的按库分布。libraries=图片、albums=相册、videos=视频。
/// 老后端只返回 libraries 时，albums/videos 用 decodeIfPresent 兜底为空，不炸解码。
struct PersonLibraryBreakdown: Codable, Sendable {
    var libraries: [PersonLibraryStat] = []
    var albums: [PersonLibraryStat] = []
    var videos: [PersonLibraryStat] = []

    // 自定义 init(from:) 会抑制编译器合成无参 init，这里显式补回（空分布兜底用）
    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        libraries = (try? c.decode([PersonLibraryStat].self, forKey: .libraries)) ?? []
        albums = (try? c.decode([PersonLibraryStat].self, forKey: .albums)) ?? []
        videos = (try? c.decode([PersonLibraryStat].self, forKey: .videos)) ?? []
    }

    enum CodingKeys: String, CodingKey {
        case libraries, albums, videos
    }
}

struct PersonVideo: Identifiable, Codable, Sendable, Hashable {
    let mediaId: Int
    var libraryId: Int = 0
    var title: String = ""
    var year: String = ""
    var folderName: String = ""
    var coverURL: URL? = nil
    var backdropURL: URL? = nil
    var sim: Double = 0
    var verdict: String = ""
    var reviewedAt: String = ""
    var note: String = ""
    var hitId: Int? = nil

    var id: Int { mediaId }

    /// 展示名：标题优先，退回目录名
    var displayTitle: String { title.isEmpty ? folderName : title }

    enum CodingKeys: String, CodingKey {
        case mediaId = "media_id"
        case libraryId = "library_id"
        case title, year
        case folderName = "folder_name"
        case coverURL = "cover_url"
        case backdropURL = "backdrop_url"
        case sim, verdict
        case reviewedAt = "reviewed_at"
        case note
        case hitId = "hit_id"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mediaId = (try? c.decode(Int.self, forKey: .mediaId)) ?? 0
        libraryId = (try? c.decode(Int.self, forKey: .libraryId)) ?? 0
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        year = (try? c.decode(String.self, forKey: .year)) ?? ""
        folderName = (try? c.decode(String.self, forKey: .folderName)) ?? ""
        // 后端可能返回 ""，URL(string: "") 会得到空 URL，这里过滤掉
        if let s = try? c.decode(String.self, forKey: .coverURL), !s.isEmpty {
            coverURL = URL(string: s)
        }
        if let s = try? c.decode(String.self, forKey: .backdropURL), !s.isEmpty {
            backdropURL = URL(string: s)
        }
        sim = (try? c.decode(Double.self, forKey: .sim)) ?? 0
        verdict = (try? c.decode(String.self, forKey: .verdict)) ?? ""
        reviewedAt = (try? c.decode(String.self, forKey: .reviewedAt)) ?? ""
        note = (try? c.decode(String.self, forKey: .note)) ?? ""
        hitId = try? c.decode(Int.self, forKey: .hitId)
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
    /// 服务端随详情下发的 ffmpeg 口径探测结果（playback_info 缓存，零探测）。
    /// 对应 videoFiles 首个文件；有值可本地判内核，nil 回退实时探测。
    var probeCodec: String? = nil
    var probeTag: String? = nil
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
        probeCodec = optString(c, .probeCodec)
        probeTag = optString(c, .probeTag)
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
        case probeCodec = "probe_codec"
        case probeTag = "probe_tag"
        case stills, folderPath = "folder_path"
        case issues
    }
}

// MARK: - 短视频
struct ShortVideo: Identifiable, Codable, Sendable, Hashable {
    let id: Int
    var poolId: Int = 0
    var fileName: String = ""
    var title: String? = nil
    var year: Int? = nil
    /// ⚠️ short_videos.duration 在库里 100% 是 REAL，按 Double 解
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

    /// 服务端随列表下发的 ffmpeg 口径探测结果（playback_info 缓存，零探测）。
    /// 有值即可本地判内核，不用再请求 /api/playback/info；nil = 未回填，回退实时探测。
    var probeCodec: String? = nil
    var probeTag: String? = nil

    /// 展示层统一剥掉「站点@」水印（`WWW.98T.LA@…`、`www.98t.la@…` 都命中）：
    /// 复用已有的 `String.strippingSitePrefix`（和影视标题同一套规则），不另写一套判据。
    /// ⚠️ fileName / filePath 保留原值：播放路径、related 同目录匹配、搜索都依赖它们。
    static func displayName(_ raw: String) -> String { raw.strippingSitePrefix }

    var titleText: String {
        Self.displayName(title?.isEmpty == false ? title! : fileName)
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
        case probeCodec = "probe_codec"
        case probeTag = "probe_tag"
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
        // ⚠️ 后端 /api/shorts/pools 的 listPools 是直接往 map 里塞
        // pools[i]["coverUrl"]（camelCase），不是 snake_case 的 cover_url。
        // 写成 cover_url 时 decodeIfPresent 永远拿不到值 → 所有池卡都只剩
        // 渐变占位（数据其实 6 个池全都有封面）。别和上面 Library 的
        // coverURL = "cover_url" 混为一谈，那是另一条接口。
        case coverUrl
    }
}

// MARK: - 搜索结果项
// 对应 /api/search 返回的单条；type 区分 movie/tv/album/photo
//
// ⚠️⚠️ 后端各类型返回的字段差别极大，解码必须全部容错：
//   · media（movie/tv）→ 有 title / type / year / rating / poster_image_id
//   · 相册 photo_albums   → 只有 folder_name / display_name / cover_photo_id / photo_count，**没有 title、type**
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
// 搜索接口只返回一套扁平字段，而三类内容的展示卡（MediaCard / AlbumCard /
// 照片瀑布流）分别吃 MediaItem / Album / Photo。
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

// MARK: - 字符串清理
// ⚠️ 原定义在 ShootDetailView.swift，拍摄集下掉删文件时必须把这段搬过来 ——
// 短视频 ShortVideo.displayName 还在用，不能跟着删。
extension String {
    /// 剥掉站点目录名前缀："www.98T.la@蜃楼-02E4K MP4.mp4" → "蜃楼-02E4K MP4.mp4"。
    /// 规则保守：第一个 @ 左边「含点且不含空格」才剥，正常文案原样返回。
    var strippingSitePrefix: String {
        guard let at = firstIndex(of: "@"), at > startIndex else { return self }
        let prefix = self[startIndex..<at]
        guard prefix.contains(".") && !prefix.contains(" ") else { return self }
        return String(self[index(after: at)...])
    }
}

// MARK: - 云端浏览器（cloudlib 本地入库轻表）

/// 后端 GET /api/cloudlib/status 里的一个配置入库目录（root）。
/// net_path 是网盘绝对路径（如 /云下载/06_待归类），当作 root 筛选值传给 items 接口；
/// active_items 来自 status.per_root，由 APIClient 按 root_net_path 合并进来。
struct CloudRoot: Identifiable, Codable, Hashable, Sendable {
    var netPath: String = ""
    var mount: String = ""
    var activeItems: Int = 0
    var id: String { netPath }
    var key: String { netPath.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }

    /// 🔴 后端 roots[] 没有 active_items（计数只在 per_root[]），
    /// 这里绝不能声明该 key —— 否则 Codable 解码缺字段抛 keyNotFound，
    /// 整个 fetchCloudStatus 失败 → 云端目录首页进错误态。
    /// activeItems 由 APIClient 从 per_root 合并后手动赋值，保持默认值 0 即可。
    enum CodingKeys: String, CodingKey {
        case netPath = "net_path"
        case mount
    }
}

/// GET /api/cloudlib/status 响应（只取目录列表需要的字段）
struct CloudStatusResponse: Codable, Sendable {
    var ok: Bool = false
    var roots: [CloudRoot] = []
    var perRoot: [CloudPerRootCount] = []
    var activeItems: Int = 0

    enum CodingKeys: String, CodingKey {
        case ok, roots
        case perRoot = "per_root"
        case activeItems = "active_items"
    }
}

/// per_root 单项：按 rootNetPath 把条目数并到 CloudRoot.activeItems
struct CloudPerRootCount: Codable, Sendable {
    var rootNetPath: String = ""
    var mount: String = ""
    var activeItems: Int = 0

    enum CodingKeys: String, CodingKey {
        case rootNetPath = "root_net_path"
        case mount
        case activeItems = "active_items"
    }
}

/// 后端 GET /api/cloudlib/items 的条目。字段稳定，合成 Codable + CodingKeys 即可。
/// 🔴 size 在目录树快照里恒为 0（快照文本只有路径），别用它做展示判断。
struct CloudItem: Identifiable, Codable, Sendable {
    let id: Int
    var relPath: String = ""
    var fileName: String = ""
    var dirPath: String = ""
    /// Windows 挂载路径 X:\115open\...，缩略图/原图/播放都用它（原样传给后端，不转义）
    var localPath: String = ""
    var ext: String = ""
    var mediaType: String = "other"   // image / video / other
    var size: Int64 = 0
    var status: String = "active"
    var rootKey: String = ""
    var snapshotFile: String = ""

    var isImage: Bool { mediaType == "image" }
    var isVideo: Bool { mediaType == "video" }

    /// 剥掉站点水印后的展示名（沿用全局 strippingSitePrefix）
    var displayName: String { fileName.strippingSitePrefix }

    enum CodingKeys: String, CodingKey {
        case id
        case relPath = "rel_path"
        case fileName = "file_name"
        case dirPath = "dir_path"
        case localPath = "local_path"
        case ext
        case mediaType = "media_type"
        case size
        case status
        case rootKey = "root_key"
        case snapshotFile = "snapshot_file"
    }

    /// 转成瀑布流 Photo：id 复用 cloudlib id（唯一），thumb/full URL 由 APIClient 填。
    /// 云端快照无宽高 → aspectRatio 走 Photo 默认 2:3，图片加载后 cell 会按真实比例回填重排。
    func asPhoto(thumb: URL?, full: URL?) -> Photo {
        var p = Photo(id: id)
        p.fileName = fileName
        p.thumbURL = thumb
        p.fullURL = full
        p.cloudDirPath = dirPath   // 看图器「打开所在文件夹」用
        return p
    }
}

/// GET /api/cloudlib/items 响应
struct CloudItemsResponse: Codable, Sendable {
    var ok: Bool = false
    var total: Int = 0
    var limit: Int = 0
    var offset: Int = 0
    var items: [CloudItem] = []
    var error: String? = nil
}
