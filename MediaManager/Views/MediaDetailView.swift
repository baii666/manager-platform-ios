import SwiftUI
import UIKit

// MARK: - 影视详情页
// 对齐网页端 MediaDetailPage：backdrop + 海报 + 标题/年份/评分/类型 + 简介（可展开）
// + 演员横滚 + 详情网格 + 文件路径 + 剧照画廊（点开进看图器）+ 播放
struct MediaDetailView: View {
    let media: MediaItem

    @State private var detail: MediaDetail?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var overviewExpanded = false
    @State private var playRequest: PlaybackRequest?
    @State private var playError: String?
    @State private var isFavorite = false
    @State private var favLoading = false

    /// Hero 背景高度（海报 180 + 上方露出 ~50）
    private let heroHeight: CGFloat = 230

    private var client: APIClient? { AppSession.shared.client }

    var body: some View {
        Group {
            if isLoading {
                ProgressView("加载中…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                ContentUnavailableView(errorMessage, systemImage: "exclamationmark.triangle")
            } else if let detail {
                content(detail)
            }
        }
        .navigationTitle(detail?.title ?? media.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .fullScreenCover(item: $playRequest) { request in
            PlayerHostView(request: request)
        }
        .alert("无法播放", isPresented: Binding(
            get: { playError != nil },
            set: { if !$0 { playError = nil } }
        )) {
            Button("好", role: .cancel) { playError = nil }
        } message: {
            Text(playError ?? "")
        }
        // 剧照看图器走全局 overlay（PhotoViewerPresenter），不再用 fullScreenCover
    }

    // MARK: 内容
    @ViewBuilder
    private func content(_ d: MediaDetail) -> some View {
        ScrollView {
            // ── Hero ──
            ZStack(alignment: .bottomLeading) {
                // 背景图三级逻辑，对齐网页端 MediaDetailPage：
                //   ① 有 fanart → 铺满 + 顶部对齐裁切（网页 object-cover object-top）
                //   ② 没有 fanart（或加载失败）→ 海报模糊放大打底（网页 blur-2xl scale-110）
                //   ③ 都没有 → 渐变占位
                // 遮罩对三档统一生效（网页端遮罩 div 也是常驻的）
                HeroBackground(backdropURL: d.backdropURL, posterURL: d.posterURL, height: heroHeight)
                    .overlay(LinearGradient(
                        colors: [.black.opacity(0.1), .black.opacity(0.85)],
                        startPoint: .top, endPoint: .bottom))

                HStack(alignment: .bottom, spacing: 16) {
                    RemoteImage(url: d.posterURL, fallbackIcon: "film",
                                fallbackColors: Theme.placeholderGradient(for: .media))
                        .imageFilled()
                        .frame(width: 120, height: 180)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .shadow(radius: 8)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(d.title).font(.title2.weight(.bold))
                            .foregroundStyle(.white)
                            .fixedSize(horizontal: false, vertical: true)
                        if let ot = d.originalTitle, ot != d.title {
                            Text(ot).font(.subheadline).foregroundStyle(.white.opacity(0.6))
                        }
                        HStack(spacing: 10) {
                            if let year = d.year, year > 0 {
                                Label("\(year)", systemImage: "calendar").font(.footnote)
                            }
                            if let rating = d.rating, rating > 0 {
                                Label(String(format: "%.1f", rating), systemImage: "star.fill")
                                    .font(.footnote).foregroundStyle(.yellow)
                            }
                            if let rt = d.runtimeText {
                                Label(rt, systemImage: "clock").font(.footnote)
                            }
                        }
                        .foregroundStyle(.white.opacity(0.85))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }

            VStack(alignment: .leading, spacing: 20) {
                // 类型标签 + 播放 + 收藏
                HStack(spacing: 10) {
                    if d.playable {
                        Button {
                            startPlayback(d)
                        } label: {
                            Label("播放", systemImage: "play.fill")
                                .font(.headline)
                                .foregroundStyle(.black)
                                .padding(.horizontal, 22).padding(.vertical, 10)
                                .background(Capsule().fill(.white))
                        }
                    }
                    Button {
                        toggleFavorite()
                    } label: {
                        Label(isFavorite ? "已收藏" : "收藏", systemImage: isFavorite ? "heart.fill" : "heart")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(isFavorite ? Color.red : .primary)
                            .padding(.horizontal, 18).padding(.vertical, 10)
                            .appSurface(in: Capsule())
                    }
                    .disabled(favLoading)
                }

                if !d.genres.isEmpty {
                    FlowLayout(spacing: 8) {
                        ForEach(d.genres, id: \.self) { g in
                            Text(g).font(.footnote)
                                .padding(.horizontal, 12).padding(.vertical, 5)
                                .appSurface(in: Capsule())
                        }
                    }
                }

                // 简介
                if let plot = d.plot, !plot.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("简介").font(.headline)
                        Text(plot)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(overviewExpanded ? nil : 4)
                        if plot.count > 80 {
                            Button(overviewExpanded ? "收起" : "展开全部") {
                                overviewExpanded.toggle()
                            }
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(Theme.brand)
                        }
                    }
                }

                // 演员
                if !d.actors.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("演员").font(.headline)
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 14) {
                                ForEach(d.actors) { actor in
                                    ActorChip(actor: actor)
                                }
                            }
                            .padding(.horizontal, 2)
                        }
                    }
                }

                // 详情网格
                VStack(alignment: .leading, spacing: 10) {
                    Text("详情").font(.headline)
                    VStack(alignment: .leading, spacing: 8) {
                        if let director = d.director, !director.isEmpty {
                            InfoRow(label: "导演", value: director)
                        }
                        if let studio = d.studio, !studio.isEmpty {
                            InfoRow(label: "制片厂", value: studio)
                        }
                        if let country = d.country, !country.isEmpty {
                            InfoRow(label: "国家", value: country)
                        }
                        if let releaseDate = d.releaseDate, !releaseDate.isEmpty {
                            InfoRow(label: "上映", value: releaseDate.prefix(10).description)
                        }
                        if let year = d.year, year > 0 {
                            InfoRow(label: "年份", value: "\(year)")
                        }
                        if let rt = d.runtimeText {
                            InfoRow(label: "时长", value: rt)
                        }
                        if let rating = d.rating, rating > 0 {
                            InfoRow(label: "评分", value: String(format: "%.1f", rating))
                        }
                    }
                }

                // 文件路径
                if let fp = d.folderPath, !fp.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("文件").font(.headline)
                        Text(fp).font(.caption).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

                // 剧照画廊
                if !stillsPhotos.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("剧照").font(.headline)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8)], spacing: 8) {
                            ForEach(stillsPhotos.indices, id: \.self) { i in
                                Button {
                                    PhotoViewerPresenter.shared.show(stillsPhotos, index: i)
                                } label: {
                                    RemoteImage(url: stillsPhotos[i].thumbURL, fallbackIcon: "photo",
                                                fallbackColors: Theme.placeholderGradient(for: .media))
                                        .imageFilled()
                                        .frame(height: 90)
                                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                Spacer(minLength: 20)
            }
            .padding(16)
            .bottomBarClearance()
        }
        .appBackground()
    }

    // 把剧照 URL 适配成 Photo（看图器需要）
    private var stillsPhotos: [Photo] {
        guard let d = detail else { return [] }
        return d.stills.enumerated().map { i, url in
            var p = Photo(id: i + 1)
            p.thumbURL = url
            p.fullURL = url
            return p
        }
    }

    // MARK: 数据
    private func load() async {
        guard let client else { errorMessage = "未连接服务器"; isLoading = false; return }
        do {
            let d = try await client.fetchMediaDetail(id: media.id)
            detail = d
            if let f = try? await client.fetchFavorite(type: "media", id: media.id) {
                isFavorite = f
            }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isLoading = false
    }

    private func toggleFavorite() {
        guard let client else { return }
        let target = !isFavorite
        favLoading = true
        Task {
            do {
                isFavorite = try await client.setFavorite(type: "media", id: media.id, on: target)
            } catch {}
            favLoading = false
        }
    }

    /// 播放。地址不是同步拼出来的：非 MP4 容器要服务端开 HLS 会话。
    /// 这里只交出去一个「请求」，真正拿地址的等待由 PlayerHostView 接手（立刻全屏 + 阶段反馈）。
    private func startPlayback(_ d: MediaDetail) {
        guard let path = d.videoFiles.first, !path.isEmpty else {
            playError = "《\(d.title)》没有可播放的文件"
            return
        }
        playRequest = PlaybackRequest(path: path,
                                      title: d.title,
                                      assetType: "media",
                                      assetID: d.id,
                                      startAt: nil,
                                      // ⚠️ 必须给：非直连容器走 HLS，FFmpeg 没跑完前 AVPlayer 的
                                      // duration 是 indefinite(0)，进度条换算与快进钳位都依赖它，
                                      // 缺了会表现成「进度条/快进拖了没反应」（全算成 0）。
                                      // runtime 是分钟（nfo 元数据）。
                                      knownDuration: d.runtime.map { Double($0) * 60 })
    }
}

// MARK: - Hero 背景图（对齐网页端三级展示逻辑）
// 网页端 MediaDetailPage 的 hero 背景（src/pages/MediaDetailPage.tsx）：
//   ① media.backdrop_path → object-cover object-top
//   ② media.poster_path   → object-cover object-center blur-2xl scale-110
//   ③ 都没有              → bg-gradient-to-br from-surface to-background
// 之前 iOS 只有 ①③ 两档：没有 fanart 的影片 Hero 是一块纯渐变，而海报就在手边。
// 现在补上 ②；fanart 加载失败也退到 ②，不留空。
private struct HeroBackground: View {
    let backdropURL: URL?
    let posterURL: URL?
    let height: CGFloat

    @State private var backdrop: UIImage?
    /// fanart 加载失败：退到海报模糊档
    @State private var backdropFailed = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let backdrop, backdrop.size.height > 0, backdrop.size.width > 0 {
                    topCover(backdrop, box: geo.size)
                } else if backdropURL != nil, !backdropFailed {
                    // fanart 还在加载：渐变占位（RemoteImage 同款观感）
                    placeholder
                } else if let posterURL {
                    // ② 海报模糊打底：先模糊再放大，模糊边缘才不会露出虚边
                    RemoteImage(url: posterURL, fallbackIcon: "film",
                                fallbackColors: Theme.placeholderGradient(for: .media))
                        .imageFilled()
                        // 网页 blur-2xl=40px 是按 ~480px 高的 Hero 定的，
                        // 这里 Hero 只有 230，按同比例折算到 24
                        .blur(radius: 24)
                        .scaleEffect(1.1)
                } else {
                    placeholder
                }
            }
        }
        .frame(height: height)
        .clipped()
        .task(id: backdropURL) { await loadBackdrop() }
    }

    /// ① fanart：object-cover object-top。
    /// imageFilled() 是居中裁切，会把画面主体切掉 —— iPad 上 Hero 矮宽，
    /// 竖幅 fanart 垂直溢出两百多 pt，居中切两头吃亏。这里自己算缩放比例
    /// 铺满容器、顶边对齐，向下溢出由外层 .clipped() 裁掉。
    @ViewBuilder
    private func topCover(_ image: UIImage, box: CGSize) -> some View {
        let scale = max(box.width / image.size.width, box.height / image.size.height)
        let w = image.size.width * scale
        let h = image.size.height * scale
        Image(uiImage: image)
            .resizable()
            .frame(width: w, height: h)
            .position(x: box.width / 2, y: h / 2)
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: Theme.placeholderGradient(for: .media),
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "film")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.white.opacity(0.85))
        }
    }

    @MainActor
    private func loadBackdrop() async {
        guard let backdropURL else {
            backdrop = nil
            backdropFailed = false
            return
        }
        backdrop = nil
        backdropFailed = false
        if let img = await ImageCache.shared.load(from: backdropURL) {
            backdrop = img
        } else {
            backdropFailed = true
        }
    }
}

// MARK: - 演员头像
private struct ActorChip: View {
    let actor: Actor
    var body: some View {
        VStack(spacing: 6) {
            RemoteImage(url: actor.thumbURL, fallbackIcon: "person.fill",
                        fallbackColors: [Color.gray.opacity(0.3), Color.gray.opacity(0.1)])
                .imageFilled()
                .frame(width: 64, height: 64)
                .clipShape(Circle())
            Text(actor.name).font(.caption2).lineLimit(1).frame(width: 64)
            if let role = actor.role, !role.isEmpty {
                Text(role).font(.caption2).foregroundStyle(.secondary).lineLimit(1).frame(width: 64)
            }
        }
    }
}

// MARK: - 详情行
private struct InfoRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label).font(.subheadline).foregroundStyle(.secondary).frame(width: 48, alignment: .leading)
            Text(value).font(.subheadline).foregroundStyle(.primary)
        }
    }
}

// MARK: - 流式布局（类型标签）
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    static var layoutProperties: LayoutProperties { LayoutProperties() }

    func sizeThatFits(proposal: ProposedViewSize, subviews: LayoutSubviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(proposal) }
        let maxWidth = proposal.width ?? .infinity
        var width: CGFloat = 0
        var height: CGFloat = 0
        var currentRowWidth: CGFloat = 0
        var currentRowHeight: CGFloat = 0
        for size in sizes {
            if currentRowWidth + size.width + spacing > maxWidth, currentRowWidth > 0 {
                width = max(width, currentRowWidth - spacing)
                height += currentRowHeight + spacing
                currentRowWidth = 0
                currentRowHeight = 0
            }
            currentRowWidth += size.width + spacing
            currentRowHeight = max(currentRowHeight, size.height)
        }
        width = max(width, currentRowWidth - spacing)
        height += currentRowHeight
        return CGSize(width: min(width, maxWidth), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: LayoutSubviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(proposal) }
        var x = bounds.minX
        var y = bounds.minY
        var currentRowHeight: CGFloat = 0
        for index in subviews.indices {
            let size = sizes[index]
            if x + size.width + spacing > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += currentRowHeight + spacing
                currentRowHeight = 0
            }
            subviews[index].place(at: CGPoint(x: x, y: y), proposal: proposal)
            x += size.width + spacing
            currentRowHeight = max(currentRowHeight, size.height)
        }
    }
}
