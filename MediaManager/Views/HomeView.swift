import SwiftUI
import UIKit

// MARK: - 首页
// 信息架构对齐现有 Web 端 HomePageV3 的消费视角：
// 搜索 + 统计 → 继续观看 → 我的收藏 → 最近入库 → 发现
struct HomeView: View {
    @ObservedObject var viewModel: HomeViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                hero
                if !viewModel.resume.isEmpty { resumeSection }
                if !viewModel.favorites.isEmpty { favoritesSection }
                if !viewModel.recent.isEmpty { recentSection }
                discoverSection
            }
            .padding(.vertical, 24)
            .padding(.horizontal, 24)
        }
        .background(Color(uiColor: .systemBackground))
        .navigationTitle("首页")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if viewModel.stats.libraryCount == 0 {
                await viewModel.load()
            }
        }
        .overlay {
            if viewModel.isLoading {
                ProgressView("加载中…")
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }

    // MARK: Hero：搜索 + 统计

    private var hero: some View {
        VStack(spacing: 20) {
            VStack(spacing: 6) {
                Text("想看什么？")
                    .font(.largeTitle.weight(.bold))
                Text("影视、写真、短视频、拍摄集 —— 一个搜索框全部找到")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            SearchBar(
                text: $viewModel.searchText,
                semantic: $viewModel.semanticSearch,
                onSubmit: {}
            )
            .frame(maxWidth: 640)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                ForEach(statEntries) { entry in
                    StatCard(icon: entry.icon, label: entry.label, value: entry.value, tint: entry.tint)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    // MARK: 继续观看

    private var resumeSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(icon: "clock.fill", title: "继续观看")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 16)], spacing: 16) {
                ForEach(viewModel.resume) { asset in
                    ResumeCard(asset: asset)
                }
            }
        }
    }

    // MARK: 我的收藏

    private var favoritesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(icon: "heart.fill", title: "我的收藏")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 16) {
                ForEach(viewModel.favorites) { asset in
                    AssetPosterCard(asset: asset)
                }
            }
        }
    }

    // MARK: 最近入库

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(icon: "bolt.fill", title: "最近入库")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 16)], spacing: 16) {
                ForEach(viewModel.recent) { item in
                    RecentPosterCard(item: item)
                }
            }
        }
    }

    // MARK: 发现

    private var discoverSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(icon: "sparkles", title: "发现")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                DiscoverCard(icon: "shuffle", title: "随机照片", subtitle: "从图库里随便逛", tint: .green)
                DiscoverCard(icon: "person.2.fill", title: "人物", subtitle: "人脸聚类结果", tint: .cyan)
                DiscoverCard(icon: "photo.on.rectangle.angled", title: "拍摄集", subtitle: "按拍摄批次浏览", tint: .pink)
                DiscoverCard(icon: "play.rectangle.fill", title: "短视频连播", subtitle: "刷起来停不下", tint: .orange)
            }
        }
    }

    // MARK: 统计配置

    private var statEntries: [StatEntry] {
        [
            StatEntry(id: "lib", icon: "folder.fill", label: "媒体库", value: viewModel.stats.libraryCount, tint: Theme.brand),
            StatEntry(id: "movie", icon: "film", label: "电影", value: viewModel.stats.movieCount, tint: .blue),
            StatEntry(id: "series", icon: "tv", label: "剧集", value: viewModel.stats.seriesCount, tint: .purple),
            StatEntry(id: "photo", icon: "camera", label: "图片", value: viewModel.stats.photoCount, tint: .green),
            StatEntry(id: "shoot", icon: "photo.on.rectangle.angled", label: "拍摄集", value: viewModel.stats.shootCount, tint: .pink),
            StatEntry(id: "short", icon: "play.rectangle.fill", label: "短视频", value: viewModel.stats.shortCount, tint: .orange),
        ]
    }
}

private struct StatEntry: Identifiable {
    let id: String
    let icon: String
    let label: String
    let value: Int
    let tint: Color
}
