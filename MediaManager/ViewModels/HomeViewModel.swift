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
        // 下拉刷新期间绝不碰任何 @Published（isLoading / failures / stats… 都会触发
        // body 重算，让 .refreshable 的刷新 Task 被取消 → 请求报「取消」）。
        // 刷新转圈由系统 refreshable 承担。
        if showSpinner { isLoading = true }
        defer { if showSpinner { isLoading = false } }

        // ⚠️ 四块必须各自容错：若用一次 try await 同时等待，
        // 任何一个接口报错（401 / 字段不匹配）都会让整页数据全部丢弃变成空白
        async let statsTask = provider.fetchStats()
        async let resumeTask = provider.fetchResume(limit: 14)
        async let favTask = provider.fetchFavorites(limit: 24)
        async let recentTask = provider.fetchRecent(limit: 24)

        // 先把结果收进局部变量，等四个请求全部结束后再一次性提交，
        // 避免「请求进行中」触发 body 重算取消刷新 Task
        var newStats = stats
        var newResume = resume
        var newFavorites = favorites
        var newRecent = recent
        var newFailures: [String] = []

        do { newStats = try await statsTask }
        catch { newStats = HomeStats(); newFailures.append("统计 · \(describe(error))") }

        do { newResume = try await resumeTask }
        catch { newResume = []; newFailures.append("继续观看 · \(describe(error))") }

        do { newFavorites = try await favTask }
        catch { newFavorites = []; newFailures.append("我的收藏 · \(describe(error))") }

        do { newRecent = try await recentTask }
        catch { newRecent = []; newFailures.append("最近入库 · \(describe(error))") }

        stats = newStats
        resume = newResume
        favorites = newFavorites
        recent = newRecent
        failures = newFailures
        errorMessage = newFailures.isEmpty ? nil : "部分数据加载失败"
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
