import Foundation

// MARK: - Mock 数据实现
// 完全离线、与现有项目零耦合。用内置假数据撑起首页各区块，
// 方便在没有后端的环境里预览 iPad 界面与交互。
// 封面用渐变占位 + SF Symbol 图标（不依赖任何远程图片），保证离线可跑。
struct MockDataProvider: DataProviding {

    func fetchStats() async throws -> HomeStats {
        try await Task.sleep(nanoseconds: 300_000_000) // 模拟网络延迟
        return HomeStats(
            libraryCount: 6,
            movieCount: 1284,
            seriesCount: 356,
            photoCount: 20_480,
            shootCount: 65,
            shortCount: 512
        )
    }

    func fetchResume(limit: Int) async throws -> [UnifiedAsset] {
        try await Task.sleep(nanoseconds: 400_000_000)
        return Self.resumeAssets.prefix(limit).map { $0 }
    }

    func fetchFavorites(limit: Int) async throws -> [UnifiedAsset] {
        try await Task.sleep(nanoseconds: 350_000_000)
        return Self.favoriteAssets.prefix(limit).map { $0 }
    }

    func fetchRecent(limit: Int) async throws -> [RecentItem] {
        try await Task.sleep(nanoseconds: 320_000_000)
        return Self.recentItems.prefix(limit).map { $0 }
    }

    func search(query: String) async throws -> [UnifiedAsset] {
        try await Task.sleep(nanoseconds: 250_000_000)
        let q = query.lowercased()
        let pool = Self.resumeAssets + Self.favoriteAssets
        guard !q.isEmpty else { return [] }
        return pool.filter { $0.title.lowercased().contains(q) }
    }

    func fetchPhotos(limit: Int, offset: Int) async throws -> [Photo] {
        try await Task.sleep(nanoseconds: 300_000_000)
        return Self.makePhotos(from: offset, count: limit)
    }

    // MARK: 假数据

    /// 演示用 HLS 流（Apple 官方测试流），让播放器离线也能跑通
    static let demoHLS = URL(string: "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_ts/master.m3u8")

    /// 按 offset 生成一批照片（picsum 占位图，宽高比轮换制造瀑布流错落），模拟无限翻页
    static func makePhotos(from offset: Int, count: Int) -> [Photo] {
        let sizes: [(Int, Int)] = [(600, 800), (600, 450), (600, 600), (600, 900), (600, 750), (600, 500)]
        return (0..<count).map { i in
            let idx = offset + i
            let (w, h) = sizes[idx % sizes.count]
            let pic = 1000 + (idx % 80) // picsum 固定 id 池
            return Photo(
                id: idx + 1,
                thumbURL: URL(string: "https://picsum.photos/id/\(pic)/\(w)/\(h)"),
                fullURL: URL(string: "https://picsum.photos/id/\(pic)/1200/1600"),
                width: w,
                height: h
            )
        }
    }

    static let resumeAssets: [UnifiedAsset] = [
        UnifiedAsset(id: 1, type: .media, title: "星际穿越", subtitle: "电影 · 2h49m",
                     position: 4020, duration: 10140, playbackURL: Self.demoHLS),
        UnifiedAsset(id: 2, type: .media, title: "绝命毒师 第一季", subtitle: "剧集 · 第 3 集",
                     position: 1220, duration: 2820, playbackURL: Self.demoHLS),
        UnifiedAsset(id: 3, type: .short, title: "短视频 · 街头掠影", subtitle: "短视频",
                     position: 18, duration: 45, playbackURL: Self.demoHLS),
        UnifiedAsset(id: 4, type: .shoot, title: "2026-10-02 外景拍摄", subtitle: "拍摄集 · 128 张",
                     position: 12, duration: 60),
        UnifiedAsset(id: 5, type: .photo, title: "写真 · 京都之秋", subtitle: "相册 · 96 张",
                     position: 24, duration: 120),
        UnifiedAsset(id: 6, type: .media, title: "银翼杀手 2049", subtitle: "电影 · 2h43m",
                     position: 600, duration: 9840, playbackURL: Self.demoHLS),
        UnifiedAsset(id: 7, type: .media, title: "风骚律师", subtitle: "剧集 · 第 5 集",
                     position: 2100, duration: 2760, playbackURL: Self.demoHLS),
        UnifiedAsset(id: 8, type: .short, title: "短视频 · 城市夜景", subtitle: "短视频",
                     position: 0, duration: 30, playbackURL: Self.demoHLS),
    ]

    static let favoriteAssets: [UnifiedAsset] = [
        UnifiedAsset(id: 101, type: .media, title: "盗梦空间", subtitle: "电影 · 2010"),
        UnifiedAsset(id: 102, type: .media, title: "切尔诺贝利", subtitle: "剧集 · 2019"),
        UnifiedAsset(id: 103, type: .photo, title: "写真 · 北海道", subtitle: "相册 · 214 张"),
        UnifiedAsset(id: 104, type: .shoot, title: "2026-09-18 棚拍", subtitle: "拍摄集 · 45 张"),
        UnifiedAsset(id: 105, type: .media, title: "搏击俱乐部", subtitle: "电影 · 1999"),
        UnifiedAsset(id: 106, type: .media, title: "黑镜", subtitle: "剧集 · 2011"),
        UnifiedAsset(id: 107, type: .short, title: "短视频 · 海边", subtitle: "短视频"),
        UnifiedAsset(id: 108, type: .photo, title: "写真 · 东京塔", subtitle: "相册 · 178 张"),
    ]

    static let recentItems: [RecentItem] = [
        RecentItem(id: 201, kind: .movie, title: "沙丘 2", year: 2024, libraryName: "电影库"),
        RecentItem(id: 202, kind: .series, title: "王冠 第六季", year: 2023, libraryName: "剧集库"),
        RecentItem(id: 203, kind: .album, title: "2026-10-05 扫街", libraryName: "相册库", photoCount: 156),
        RecentItem(id: 204, kind: .movie, title: "奥本海默", year: 2023, libraryName: "电影库"),
        RecentItem(id: 205, kind: .series, title: "继承之战 第四季", year: 2023, libraryName: "剧集库"),
        RecentItem(id: 206, kind: .album, title: "2026-09-30 人像", libraryName: "相册库", photoCount: 88),
        RecentItem(id: 207, kind: .movie, title: "可怜的东西", year: 2023, libraryName: "电影库"),
        RecentItem(id: 208, kind: .series, title: "怒呛人生", year: 2023, libraryName: "剧集库"),
    ]
}
