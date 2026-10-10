import Foundation
import SwiftUI

// MARK: - 首页状态
final class HomeViewModel: ObservableObject {

    @Published var stats = HomeStats()
    @Published var resume: [UnifiedAsset] = []
    @Published var favorites: [UnifiedAsset] = []
    @Published var recent: [RecentItem] = []

    @Published var isLoading = false
    @Published var errorMessage: String?

    // 搜索
    @Published var searchText = ""
    @Published var semanticSearch = false
    @Published var searchResults: [UnifiedAsset] = []
    @Published var isSearching = false

    private let provider: DataProviding

    init(provider: DataProviding? = nil) {
        self.provider = provider ?? AppSession.shared.client ?? MockDataProvider()
    }

    // MARK: 加载

    /// 记录每个板块的失败原因，便于首页提示（不再静默变空白）
    @Published var failures: [String] = []

    @MainActor
    func load(showSpinner: Bool = true) async {
        // 下拉刷新不碰 isLoading：isLoading 触发 body 重算会让 .refreshable 的
        // 刷新 Task 被取消（请求取消），刷新转圈由系统 refreshable 承担
        if showSpinner { isLoading = true }
        errorMessage = nil
        failures = []
        defer { if showSpinner { isLoading = false } }

        // ⚠️ 四块必须各自容错：若用一次 try await 同时等待，
        // 任何一个接口报错（401 / 字段不匹配）都会让整页数据全部丢弃变成空白
        async let statsTask = provider.fetchStats()
        async let resumeTask = provider.fetchResume(limit: 14)
        async let favTask = provider.fetchFavorites(limit: 24)
        async let recentTask = provider.fetchRecent(limit: 24)

        do { stats = try await statsTask }
        catch { stats = HomeStats(); failures.append("统计 · \(describe(error))") }

        do { resume = try await resumeTask }
        catch { resume = []; failures.append("继续观看 · \(describe(error))") }

        do { favorites = try await favTask }
        catch { favorites = []; failures.append("我的收藏 · \(describe(error))") }

        do { recent = try await recentTask }
        catch { recent = []; failures.append("最近入库 · \(describe(error))") }

        errorMessage = failures.isEmpty ? nil : "部分数据加载失败"
    }

    private func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    /// 搜索框提交（影视 / 照片 / 相册 / 拍摄集全类型）
    @MainActor
    func performSearch() async {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            searchResults = []
            return
        }
        isSearching = true
        defer { isSearching = false }
        do {
            searchResults = try await provider.search(query: q)
        } catch {
            searchResults = []
            errorMessage = "搜索失败 · \(describe(error))"
        }
    }
}
