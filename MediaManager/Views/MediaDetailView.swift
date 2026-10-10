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
    @State private var playing = false
    @State private var showViewer = false
    @State private var viewerIndex = 0
    @State private var isFavorite = false
    @State private var favLoading = false

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
        .fullScreenCover(isPresented: $playing) {
            if let detail, let path = detail.videoFiles.first,
               let url = client?.makeURL("/stream", queryItems: [URLQueryItem(name: "path", value: path)]) {
                NavigationStack {
                    VideoPlayerView(url: url, title: detail.title, assetType: "media", assetID: detail.id)
                        .toolbar { ToolbarItem(placement: .cancellationAction) {
                            Button("关闭") { playing = false }
                        } }
                }
            }
        }
        .fullScreenCover(isPresented: $showViewer) {
            if !stillsPhotos.isEmpty {
                PhotoViewerView(photos: stillsPhotos, index: viewerIndex, onClose: { showViewer = false })
            }
        }
    }

    // MARK: 内容
    @ViewBuilder
    private func content(_ d: MediaDetail) -> some View {
        ScrollView {
            // ── Hero ──
            ZStack(alignment: .bottomLeading) {
                if let backdrop = d.backdropURL {
                    RemoteImage(url: backdrop, fallbackIcon: "film",
                                fallbackColors: Theme.placeholderGradient(for: .media))
                        .imageFilled()
                        .frame(height: 230)
                        .clipped()
                        .overlay(LinearGradient(
                            colors: [.black.opacity(0.1), .black.opacity(0.85)],
                            startPoint: .top, endPoint: .bottom))
                } else {
                    Rectangle().fill(LinearGradient(colors: Theme.placeholderGradient(for: .media),
                                                   startPoint: .top, endPoint: .bottom)).frame(height: 230)
                }

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
                            playing = true
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
                            .background(Capsule().fill(Color(uiColor: .secondarySystemBackground)))
                    }
                    .disabled(favLoading)
                }

                if !d.genres.isEmpty {
                    FlowLayout(spacing: 8) {
                        ForEach(d.genres, id: \.self) { g in
                            Text(g).font(.footnote)
                                .padding(.horizontal, 12).padding(.vertical, 5)
                                .background(Capsule().fill(Color(uiColor: .secondarySystemBackground)))
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
                                    viewerIndex = i
                                    showViewer = true
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
        }
        .background(Color(uiColor: .systemBackground))
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
