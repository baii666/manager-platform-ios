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

    // MARK: Hero 布局尺寸（iPhone / iPad 两套）
    // ⚠️ 主要使用设备是 13 寸 iPad（满宽 1024pt，无侧边栏）。之前整套数字
    // 是按 iPhone 390pt 定的：海报 200pt 在 iPad 上只占 20% 屏宽，又小又散。
    // 现在按 horizontalSizeClass 分两套，regular = iPad。
    private var isWide: Bool { hSizeClass == .regular }
    /// 左右内边距
    private var heroPad: CGFloat { isWide ? 32 : 16 }
    /// 封面区顶部内边距（海报/信息顶缘）
    private var posterTopPad: CGFloat { isWide ? 24 : 12 }
    /// 海报宽：iPad 380 / iPhone 200
    private var posterWidth: CGFloat { isWide ? 380 : 200 }
    /// 封面背景区高度
    private var coverHeight: CGFloat { isWide ? 440 : 300 }
    /// 海报底缘越过封面区扎进白屏的深度（穿越量）
    private var posterCross: CGFloat { isWide ? 150 : 64 }
    /// 海报与信息列间距 / 白屏区列距分界线的间距
    private var heroGap: CGFloat { isWide ? 20 : 12 }
    /// 海报高：由「封面区高 + 穿越量」反推，底缘正好越过封面区 posterCross。
    /// iPad: 440+150-24 = 566（380 宽 → 1.49≈2:3，几乎不裁）；
    /// iPhone: 300+64-12 = 352（信息列高，必须够高才盖得住，2:3 略裁一点）
    private var posterHeight: CGFloat { coverHeight + posterCross - posterTopPad }
    /// 字号：iPad 上同一档 SwiftUI 字号偏小，整体上调一级
    private var titleFont: Font { isWide ? .title : .title3 }
    private var metaFont: Font { isWide ? .footnote : .caption }
    private var tagFont: Font { isWide ? .caption : .caption2 }
    private var sectionFont: Font { isWide ? .title3 : .headline }
    private var bodyFont: Font { isWide ? .body : .subheadline }
    private var buttonFont: Font { isWide ? .subheadline : .caption }
    /// 海报圆角（大海报按比例放大一点）
    private var posterRadius: CGFloat { isWide ? 20 : 16 }
    /// 信息列内部行距
    private var infoSpacing: CGFloat { isWide ? 10 : 6 }

    @Environment(\.horizontalSizeClass) private var hSizeClass

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
            // ══ Hero（对齐草图）：海报左置放大、加高自然溢出穿越封面进白屏 ══
            // ① 背景层：封面图 + 双层遮罩，用 .background 垫在内容下面，不占空间
            // ② 封面区：海报在左（比封面区高，底缘自然扎进白屏 = 穿越）；
            //    标题/原名/meta/tag/按钮在海报右侧，整块沉到分界线上方（不贴顶）
            // ③ 白屏区：只剩简介（在海报下探部分的右侧）
            VStack(spacing: 0) {
                // ② 封面区内容：海报（左置、比封面区高 → 底缘扎进白屏）+ 信息列
                // 信息列首部 Spacer 把整块内容压到列底：沉在分界线上方，不再贴顶
                HStack(alignment: .top, spacing: heroGap) {
                    RemoteImage(url: d.posterURL, fallbackIcon: "film",
                                fallbackColors: Theme.placeholderGradient(for: .media))
                        .imageFilled()
                        .frame(width: posterWidth, height: posterHeight)
                        .clipShape(RoundedRectangle(cornerRadius: posterRadius, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: posterRadius, style: .continuous)
                            .stroke(.white.opacity(0.12), lineWidth: 1))
                        .shadow(color: .black.opacity(0.45), radius: 16, y: 8)

                    // 信息列（封面区，白字）——整体沉到分界线上方，不贴顶：
                    // Spacer 吃掉上方空白，把内容压到列底（网页版 items-end 同款观感）
                    VStack(alignment: .leading, spacing: infoSpacing) {
                        Spacer(minLength: 0)

                        Text(d.title).font(titleFont.weight(.bold))
                            .foregroundStyle(.white)
                            .fixedSize(horizontal: false, vertical: true)
                            .lineLimit(2)
                        if let ot = d.originalTitle, ot != d.title {
                            Text(ot).font(metaFont).foregroundStyle(.white.opacity(0.6))
                                .lineLimit(2)
                        }

                        // 元信息横排可换行（网页 flex-wrap，评分黄色加粗）
                        FlowLayout(spacing: heroGap) {
                            if let year = d.year, year > 0 {
                                Label("\(year)", systemImage: "calendar").font(metaFont)
                            }
                            if let rating = d.rating, rating > 0 {
                                Label(String(format: "%.1f", rating), systemImage: "star.fill")
                                    .font(metaFont.weight(.semibold)).foregroundStyle(.yellow)
                            }
                            if let rt = d.runtimeText {
                                Label(rt, systemImage: "clock").font(metaFont)
                            }
                        }
                        .foregroundStyle(.white.opacity(0.8))

                        // 类型标签：玻璃胶囊（网页 bg-white/10 + border-white/10）
                        if !genreTags.isEmpty {
                            FlowLayout(spacing: 6) {
                                ForEach(genreTags, id: \.self) { g in
                                    Text(g).font(tagFont)
                                        // ⚠️ 标签自己内部不许断行：换行由外层 FlowLayout 负责。
                                        // 一个长标签在胶囊里折成两行时，实际高度会和布局量到的
                                        // 高度对不上 —— 这就是「标签压到下面内容」的来源。
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                        .foregroundStyle(.white.opacity(0.85))
                                        .padding(.horizontal, isWide ? 14 : 10)
                                        .padding(.vertical, isWide ? 6 : 4)
                                        .background(.white.opacity(0.1), in: Capsule())
                                        .overlay(Capsule().stroke(.white.opacity(0.15), lineWidth: 1))
                                }
                            }
                        }

                        // 播放 + 收藏：小胶囊一行，紧跟标签下方、贴着分界线上方。
                        // 深色封面上用白底主按钮 + 玻璃次按钮（不再是白屏区的浅色样式）
                        FlowLayout(spacing: isWide ? 14 : 8) {
                            if d.playable {
                                Button {
                                    startPlayback(d)
                                } label: {
                                    Label("播放", systemImage: "play.fill")
                                        .font(buttonFont.weight(.semibold))
                                        .foregroundStyle(.black)
                                        .padding(.horizontal, isWide ? 22 : 14)
                                        .padding(.vertical, isWide ? 11 : 7)
                                        .background(Capsule().fill(.white))
                                }
                            }
                            Button {
                                toggleFavorite()
                            } label: {
                                Label(isFavorite ? "已收藏" : "收藏",
                                      systemImage: isFavorite ? "heart.fill" : "heart")
                                    .font(buttonFont.weight(.medium))
                                    .foregroundStyle(isFavorite ? .red : .white)
                                    .padding(.horizontal, isWide ? 22 : 14)
                                    .padding(.vertical, isWide ? 11 : 7)
                                    .background(.white.opacity(0.12), in: Capsule())
                                    .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 1))
                            }
                            .disabled(favLoading)
                        }
                    }
                    // 内容底缘距分界线留 heroGap，不直接压线上
                    .padding(.bottom, heroGap)
                }
                .padding(.horizontal, heroPad)
                .padding(.top, posterTopPad)
                .frame(height: coverHeight, alignment: .top)
                // ① 背景层：必须用 .background 垫在内容**下面**——不占布局空间。
                // ⚠️ 之前写成 VStack 里的兄弟块，它自己吃掉 coverHeight 那段高度，
                // 海报与信息列被整块挤到封面图下方（背景上面空一大块，穿越/白字
                // 叠封面全部失效，整个页面看着就是乱的）。
                .background(alignment: .top) {
                    ZStack {
                        // 背景图三级逻辑，对齐网页端 MediaDetailPage：
                        //   ① 有 fanart → 铺满 + 顶部对齐裁切（网页 object-cover object-top）
                        //   ② 没有 fanart（或加载失败）→ 海报模糊放大打底（网页 blur-2xl scale-110）
                        //   ③ 都没有 → 渐变占位
                        // height: nil → 铺满外层（= 封面区高度 coverHeight）
                        HeroBackground(backdropURL: d.backdropURL, posterURL: d.posterURL, height: nil)

                        // 双层遮罩（网页：底部 from-background 渐隐 + 右侧 from-background/80 压深）
                        // ⚠️ 两层都直接铺满：ZStack 里 Color.clear 会和渐变均分空间，渐变只盖一半
                        // 底部：压暗 + 与白屏衔接；右侧：信息列压深，保证亮 backdrop 上白字可读
                        LinearGradient(stops: [.init(color: .clear, location: 0),
                                               .init(color: .black.opacity(0.35), location: 0.5),
                                               .init(color: .black.opacity(0.85), location: 1)],
                                       startPoint: .top, endPoint: .bottom)
                        LinearGradient(stops: [.init(color: .clear, location: 0.3),
                                               .init(color: .black.opacity(0.55), location: 1)],
                                       startPoint: .leading, endPoint: .trailing)
                    }
                }

                // ③ 白屏区：只剩简介（按钮已移入封面区信息列底部）
                // 左侧是海报下探占的地盘，故右移让开；minHeight 保证即使没有简介，
                // 下一区块也不会被海报下探部分压住（海报底缘 = coverHeight + posterCross）
                if let plot = d.plot, !plot.isEmpty {
                    VStack(alignment: .leading, spacing: isWide ? 8 : 6) {
                        Text("简介").font(sectionFont)
                        Text(plot)
                            .font(bodyFont)
                            .foregroundStyle(.secondary)
                            .lineLimit(overviewExpanded ? nil : 4)
                        if plot.count > 80 {
                            Button(overviewExpanded ? "收起" : "展开全部") {
                                overviewExpanded.toggle()
                            }
                            .font((isWide ? Font.body : Font.footnote).weight(.medium))
                            .foregroundStyle(Theme.brand)
                        }
                    }
                    .padding(.top, heroGap)
                    .padding(.leading, heroPad + posterWidth + heroGap)
                    .padding(.trailing, heroPad)
                    .frame(minHeight: posterCross + heroGap, alignment: .top)
                } else {
                    // 无简介时也要让开海报下探部分
                    Spacer().frame(height: posterCross + heroGap)
                }
            }

            VStack(alignment: .leading, spacing: 20) {
                // 简介已移到 Hero 白屏区右列（海报右下，与封面区分界线衔接）

                // 演员（有 id 的跳演员详情页；后端 2026-10-13 起在 actors 里输出 id，
                // 老数据 / JSON 兜底没有 id → 保持不可点，不会坏）
                if !d.actors.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("演员").font(.headline)
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 14) {
                                ForEach(d.actors) { actor in
                                    if let actorId = actor.actorId {
                                        NavigationLink(value: ActorRoute(id: actorId)) {
                                            ActorChip(actor: actor)
                                        }
                                        .buttonStyle(.plain)
                                    } else {
                                        ActorChip(actor: actor)
                                    }
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
        // 演员头像 → 演员详情页（ActorRoute 包一层，避免与栈里其它 Int value 撞车）
        .navigationDestination(for: ActorRoute.self) { route in
            ActorDetailView(actorId: route.id)
        }
    }

    /// 类型标签：去空白 + 去重（保序）。见调用处的 id 说明。
    private var genreTags: [String] {
        var seen = Set<String>()
        return (detail?.genres ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
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
    /// nil = 高度自适应（铺满外层容器）；网页版 Hero 就是内容多高它多高
    let height: CGFloat?

    @State private var backdrop: UIImage?
    /// fanart 加载失败：退到海报模糊档
    @State private var backdropFailed = false

    var body: some View {
        base.modifier(HeroFrame(height: height))
    }

    private var base: some View {
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
                        // 这里自适应高度典型 ~330，按同比例折算到 28
                        .blur(radius: 28)
                        .scaleEffect(1.1)
                } else {
                    placeholder
                }
            }
        }
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

/// height 有值钉死高度；nil 时铺满外层（配合 .background 由内容决定 Hero 高度）
private struct HeroFrame: ViewModifier {
    let height: CGFloat?
    func body(content: Content) -> some View {
        if let height {
            content.frame(height: height)
        } else {
            content.frame(maxHeight: .infinity)
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
// 手写 wrapping layout 有两条铁律，之前踩的都是这两条：
//   ① **测量和摆放必须用同一份尺寸**。老实现两处都把父视图给的 proposal 原封不动
//      往下传：那个 proposal 的宽度是整行宽，子视图量出来的和真正摆出来的不是一回事，
//      于是胶囊互相压，整块还会压到下面的简介。现在统一用 .unspecified 量「理想尺寸」，
//      摆放时把这个尺寸原样当 proposal 传进去 —— 渲染尺寸 == 测量尺寸，结构上不可能重叠。
//   ② **换行判定里 x 已经是下一个的左边缘**（放完一个就 += width + spacing），
//      所以判定写成 `x + width > maxX`，不能再加一个 spacing。
//      老实现写成 `x + w + spacing > maxX`，本该放得下的标签会被挤到下一行。
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    static var layoutProperties: LayoutProperties { LayoutProperties() }

    /// 量一次，sizeThatFits 与 placeSubviews 共用（见 ①）
    private func idealSizes(_ subviews: LayoutSubviews, maxWidth: CGFloat) -> [CGSize] {
        subviews.map { s in
            var size = s.sizeThatFits(.unspecified)
            // 单个超宽标签夹回一行内，靠 lineLimit 截断，不许它撑破整行
            size.width = min(size.width, maxWidth)
            return size
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: LayoutSubviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let maxWidth = proposal.width ?? .greatestFiniteMagnitude
        let sizes = idealSizes(subviews, maxWidth: maxWidth)

        var x: CGFloat = 0          // 下一个标签的左边缘（已含与前一个的 spacing）
        var rowHeight: CGFloat = 0
        var total: CGFloat = 0
        var widest: CGFloat = 0
        for size in sizes {
            if x > 0, x + size.width > maxWidth {
                total += rowHeight + spacing
                widest = max(widest, x - spacing)
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        total += rowHeight
        widest = max(widest, max(0, x - spacing))
        // 宽度报满容器：这样摆放时拿到的 bounds 宽度 == 测量时的 maxWidth，行断点完全一致
        let width = maxWidth == .greatestFiniteMagnitude ? widest : maxWidth
        return CGSize(width: width, height: total)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: LayoutSubviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let sizes = idealSizes(subviews, maxWidth: bounds.width)

        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for index in subviews.indices {
            let size = sizes[index]
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subviews[index].place(at: CGPoint(x: x, y: y),
                                  anchor: .topLeading,
                                  proposal: ProposedViewSize(width: size.width, height: size.height))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
