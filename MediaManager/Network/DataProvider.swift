import Foundation

// MARK: - 数据提供协议
// 首页所有数据都通过这个协议获取，UI 不关心数据来自 mock 还是真实后端。
// 后续接入真实服务时，只需新增一个「走 HTTP 的实现」，UI 零改动。
protocol DataProviding: Sendable {
    func fetchStats() async throws -> HomeStats
    func fetchResume(limit: Int) async throws -> [UnifiedAsset]
    func fetchFavorites(limit: Int) async throws -> [UnifiedAsset]
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
