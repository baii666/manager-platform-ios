import Foundation

// MARK: - 真实后端客户端（预留，未启用）
// 现有系统后端是纯 HTTP JSON（约 257 个 REST 端点，默认 http://<host>:19876）。
// 接入时只需实现 DataProviding，把下面的端点映射成 Models 里的结构：
//
//   统计     GET /api/libraries            -> HomeStats
//   继续观看 GET /api/actions/resume       -> [UnifiedAsset]
//   收藏     GET /api/actions/favorites    -> [UnifiedAsset]
//   最近入库 GET /api/recent?limit=N       -> [RecentItem]
//   搜索     GET /api/search?q=...         -> [UnifiedAsset]
//   认证     POST /api/auth/login          -> 返回 session cookie（后续请求带上）
//
// 封面通过 /media-image?id=xxx&size=600、/photo?id=xxx&size=600 访问。

final class APIClient: DataProviding, @unchecked Sendable {
    private let baseURL: URL
    private let session: URLSession

    init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    func fetchStats() async throws -> HomeStats { throw DataError.notImplemented }
    func fetchResume(limit: Int) async throws -> [UnifiedAsset] { throw DataError.notImplemented }
    func fetchFavorites(limit: Int) async throws -> [UnifiedAsset] { throw DataError.notImplemented }
    func fetchRecent(limit: Int) async throws -> [RecentItem] { throw DataError.notImplemented }
    func search(query: String) async throws -> [UnifiedAsset] { throw DataError.notImplemented }
}
