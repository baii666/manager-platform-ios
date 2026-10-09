import Foundation

// MARK: - 资产类型
// 与后端 asset_type 对齐：四类内容共用一套资产模型
// media=影视 / photo=写真 / short=短视频 / shoot=拍摄集
enum AssetType: String, Codable, CaseIterable, Identifiable, Sendable {
    case media
    case photo
    case short
    case shoot

    var id: String { rawValue }

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
// 对应后端的统一行为层 asset_actions：
// 「继续观看」「我的收藏」都返回这种结构，天然覆盖四类内容
struct UnifiedAsset: Identifiable, Codable, Sendable {
    let id: Int
    let type: AssetType
    let title: String
    var subtitle: String?
    var coverURL: URL?
    var backdropURL: URL?
    var position: Double?
    var duration: Double?

    /// 播放进度 0...1（继续观看卡片的进度条）
    var progress: Double {
        guard let position, let duration, duration > 0 else { return 0 }
        return min(1, max(0, position / duration))
    }
}

// MARK: - 最近入库
// 对应 /api/recent 返回的条目：电影 / 剧集 / 相册
struct RecentItem: Identifiable, Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case movie
        case series
        case album

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
    var year: Int?
    var coverURL: URL?
    var libraryName: String?
    var photoCount: Int?
}

// MARK: - 媒体库
struct Library: Identifiable, Codable, Sendable {
    let id: Int
    let name: String
    let type: String // movie / series / photo / shoot / mixed
    var itemCount: Int
    var thumbURL: URL?

    var displayType: String {
        switch type {
        case "movie": return "电影"
        case "series": return "剧集"
        case "photo": return "相册"
        case "shoot": return "拍摄集"
        default: return type
        }
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
