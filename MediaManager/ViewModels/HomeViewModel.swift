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

    private let provider: DataProviding

    init(provider: DataProviding? = nil) {
        self.provider = provider ?? AppSession.shared.client ?? MockDataProvider()
    }

    // MARK: 加载

    @MainActor
    func load() async {
        isLoading = true
        errorMessage = nil
        async let statsTask = provider.fetchStats()
        async let resumeTask = provider.fetchResume(limit: 14)
        async let favTask = provider.fetchFavorites(limit: 24)
        async let recentTask = provider.fetchRecent(limit: 24)

        do {
            let (s, r, f, rc) = try await (statsTask, resumeTask, favTask, recentTask)
            stats = s
            resume = r
            favorites = f
            recent = rc
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
