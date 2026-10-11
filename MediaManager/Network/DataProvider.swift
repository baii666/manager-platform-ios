import Foundation

// MARK: - 行为类型
// 统一行为层 asset_actions 的 action 名（后端 GET /api/actions/list?action=…）
enum AssetActionKind: String, Sendable {
    case favorite
    case history

    var title: String {
        switch self {
        case .favorite: return "我的收藏"
        case .history: return "观看记录"
        }
    }
}

// MARK: - 数据提供协议
// 首页所有数据都通过这个协议获取，UI 不关心数据来自 mock 还是真实后端。
// 后续接入真实服务时，只需新增一个「走 HTTP 的实现」，UI 零改动。
protocol DataProviding: Sendable {
    func fetchStats() async throws -> HomeStats
    func fetchResume(limit: Int) async throws -> [UnifiedAsset]
    func fetchFavorites(limit: Int) async throws -> [UnifiedAsset]
    func fetchHistory(limit: Int) async throws -> [UnifiedAsset]
    /// 分页拉取某类行为的资产（收藏 / 观看记录）。「我的」tab 里的完整列表走这个
    func fetchActionAssets(action: AssetActionKind, page: Int, size: Int) async throws -> (items: [UnifiedAsset], total: Int)
    func fetchRecent(limit: Int) async throws -> [RecentItem]
    func search(query: String) async throws -> [UnifiedAsset]
    func fetchPhotos(limit: Int, offset: Int) async throws -> [Photo]
}

// MARK: - 错误
enum DataError: LocalizedError {
    case notImplemented
    case server(String)
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .notImplemented: return "该数据源尚未实现"
        case .server(let message): return message
        case .http(let code): return "请求失败（HTTP \(code)）"
        }
    }
}
