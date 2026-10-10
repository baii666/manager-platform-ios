import SwiftUI
import UIKit

// MARK: - 影视列表状态
// 对齐网页端 MediaListPage：selectedLibID 为 nil 时不传 lib，后端返回用户可见媒体库的全集
final class MediaListViewModel: ObservableObject {
    /// 排序方式（对齐网页版 MediaListPage 的 SORT_OPTIONS + 后端 /api/media sortMap）
    enum Sort: String, CaseIterable, Sendable {
        case updated = "updated_desc"
        case title = "title"
        case titleDesc = "title_desc"
        case year = "year_desc"
        case rating = "rating_desc"
        case premiered = "premiered_desc"
        var label: String {
            switch self {
            case .updated: return "最新更新"
            case .title: return "标题 A→Z"
            case .titleDesc: return "标题 Z→A"
            case .year: return "年份"
            case .rating: return "评分"
            case .premiered: return "上映日期"
            }
        }
    }

    let type: String
    /// 固定库模式：从「媒体库卡片墙」点进来时传入，直接看该库内容，不再拉库列表/显示筛选菜单
    let fixedLibrary: Library?

    @Published var items: [MediaItem] = []
    @Published var libraries: [Library] = []
    @Published var selectedLibID: Int?
    @Published var sort: Sort = .updated
    @Published var searchText = ""
    @Published var totalCount = 0
    @Published var isLoading = false
    @Published var errorMessage: String?

    private var page = 1
    private let pageSize = 60
    private var hasMore = true

    private var client: APIClient? { AppSession.shared.client }

    var selectedLibrary: Library? { libraries.first { $0.id == selectedLibID } }

    init(type: String, library: Library? = nil) {
        self.type = type
        self.fixedLibrary = library
        self.selectedLibID = library?.id
    }

    @MainActor
    func loadLibraries() async {
        guard let client else {
            errorMessage = "未连接服务器"
            return
        }
        // 固定库模式：库已由外层指定，直接加载内容
        if fixedLibrary != nil {
            if items.isEmpty { await reload() }
            return
        }
        // 库列表和内容并行：库列表只喂顶部筛选菜单，不该阻塞内容首屏。
        // 之前是串行（先 await 库列表再 reload），库列表里 photo 库的 COUNT 慢时会拖慢整页。
        async let libsTask = client.mediaLibraries(ofMediaType: type)
        // 同 AlbumListView：从详情返回本页时 .task 可能重跑，此时 reload 会清空 items
        // 让 ScrollView 弹回顶部。已有数据就跳过，保住滚动位置。
        if items.isEmpty {
            await reload()
        }
        do {
            libraries = try await libsTask
        } catch {
            // 库列表拉不到不阻塞内容加载，退化成「全部」
            libraries = []
        }
    }

    @MainActor
    func selectLibrary(_ id: Int?) async {
        selectedLibID = id
        await reload()
    }

    @MainActor
    func setSort(_ s: Sort) async {
        guard sort != s else { return }
        sort = s
        await reload()
    }

    @MainActor
    func reload() async {
        items = []
        page = 1
        hasMore = true
        await loadMore()
    }

    @MainActor
    func loadMore() async {
        guard let client, !isLoading, hasMore else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let (batch, total) = try await client.fetchMedia(type: type, libID: selectedLibID, page: page, size: pageSize, sort: sort.rawValue, q: searchText.isEmpty ? nil : searchText)
            totalCount = total
            items.append(contentsOf: batch)
            page += 1
            hasMore = !batch.isEmpty && items.count < total
        } catch {
            errorMessage = "加载失败 · \(describe(error))"
        }
    }

    private func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

// MARK: - 影视列表页（电影 / 剧集通用）
struct MediaListView: View {
    let type: String
    let library: Library?

    @StateObject private var viewModel: MediaListViewModel
    @StateObject private var layout: CardLayoutController
    @State private var selected: MediaItem?
    /// 捏合手势起始宽度（MagnificationGesture 的 scale 相对手势开始，需记下起始值）
    @State private var pinchStartWidth: CGFloat = 0

    /// 根据容器宽算列布局：列数 + 每列宽。
    /// 对齐网页版 `grid-template-columns: repeat(auto-fill, minmax(size, 1fr))`：
    /// 列宽 = 均分（≥ cardWidth），卡片填满整列，不留空隙。之前用
    /// adaptive(minimum:) 时列宽可能大于卡片固定宽，卡片居中留白导致「间隙太大」。
    private func gridLayout(containerWidth: CGFloat) -> (columns: [GridItem], itemWidth: CGFloat) {
        let spacing: CGFloat = 18
        let padding: CGFloat = 16
        let gridW = max(containerWidth - padding * 2, 0)
        let n = max(1, Int((gridW + spacing) / (layout.cardWidth + spacing)))
        let itemW = (gridW - spacing * CGFloat(n - 1)) / CGFloat(n)
        let cols = Array(repeating: GridItem(.flexible(), spacing: spacing), count: n)
        return (cols, itemW)
    }

    init(type: String, library: Library? = nil) {
        self.type = type
        self.library = library
        _viewModel = StateObject(wrappedValue: MediaListViewModel(type: type, library: library))
        _layout = StateObject(wrappedValue: CardLayoutController(
            baseKey: "mediaList", libID: library?.id,
            portraitDefault: 150, landscapeDefault: 240,
            portraitRange: 100...260, landscapeRange: 160...400
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            // 顶部状态栏（独立、美观）
            VStack(spacing: 10) {
                ListSearchBar(text: $viewModel.searchText, placeholder: "搜索标题、演员、类型…")
                HStack(spacing: 8) {
                    sortMenu
                    ToolChip(label: layout.landscape ? "横版" : "竖版",
                             icon: layout.landscape ? "rectangle" : "rectangle.portrait",
                             highlighted: layout.landscape) {
                        layout.toggleOrientation()
                    }
                    ToolSlider(icon: "arrow.up.left.and.arrow.down.right", layout: layout)
                    Spacer()
                    Text("\(viewModel.items.count) / \(viewModel.totalCount)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 4)

            // 网格：用 GeometryReader 测容器宽（稳定值，非 cell 高度），
            // 自己算列数让卡片填满列宽，捏合时列数跳变但卡片始终铺满、无间隙。
            GeometryReader { geo in
                let grid = gridLayout(containerWidth: geo.size.width)
                ScrollView {
                    LazyVGrid(columns: grid.columns, spacing: 18) {
                        ForEach(viewModel.items) { item in
                            let cover = AppSession.shared.client?.mediaCoverURL(item, landscape: layout.landscape)
                            MediaCard(item: item, coverURL: cover, width: grid.itemWidth, landscape: layout.landscape) {
                                selected = item
                            }
                            .task {
                                if item.id == viewModel.items.last?.id {
                                    await viewModel.loadMore()
                                }
                            }
                        }
                    }
                    .padding(16)
                    // 列数跳变时用弹簧动画平滑过渡，别让卡片尺寸「突然跳」
                    .animation(.spring(response: 0.28, dampingFraction: 0.85), value: grid.columns.count)
                    if viewModel.isLoading {
                        ProgressView().frame(maxWidth: .infinity).padding()
                    }
                }
                // 双指捏合缩放卡片大小（对齐网页版 usePinchToResize）
                .simultaneousGesture(pinchGesture)
            }
        }
        .navigationTitle(library?.name ?? (type == "tv" ? "剧集" : "电影"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // 固定库模式不显示库筛选（只有一个库）
                if library == nil && !viewModel.libraries.isEmpty { libraryMenu }
            }
        }
        // ⚠️ iOS 17 起 onChange(of:) 零参闭包
        .onChange(of: viewModel.searchText) {
            Task {
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled else { return }
                await viewModel.reload()
            }
        }
        .overlay {
            if viewModel.items.isEmpty && !viewModel.isLoading {
                ContentUnavailableView(
                    viewModel.errorMessage ?? "暂无内容",
                    systemImage: viewModel.errorMessage == nil ? "film" : "exclamationmark.triangle"
                )
            }
        }
        .task { await viewModel.loadLibraries() }
        .navigationDestination(item: $selected) { item in
            MediaDetailView(media: item)
        }
    }

    /// 排序选择（对齐网页版列表页顶部状态栏）
    private var sortMenu: some View {
        ToolMenuChip(label: viewModel.sort.label, icon: "arrow.up.arrow.down") {
            ForEach(MediaListViewModel.Sort.allCases, id: \.self) { s in
                Button {
                    Task { await viewModel.setSort(s) }
                } label: {
                    if viewModel.sort == s { Label(s.label, systemImage: "checkmark") }
                    else { Text(s.label) }
                }
            }
        }
    }

    /// 双指捏合缩放卡片大小。scale 相对手势开始，所以记下起始宽度再乘比例。
    /// 拖动中只改内存（resize 不落盘），松手才 commit 落盘，避免高频写 UserDefaults 卡顿。
    private var pinchGesture: some Gesture {
        MagnificationGesture()
            .onChanged { scale in
                if pinchStartWidth == 0 { pinchStartWidth = layout.cardWidth }
                layout.resize(to: pinchStartWidth * scale)
            }
            .onEnded { _ in
                pinchStartWidth = 0
                layout.commit()
            }
    }

    /// 库选择放导航栏下拉菜单（iOS 常见样式），不再挤在顶部占一整行
    private var libraryMenu: some View {
        Menu {
            Button {
                Task { await viewModel.selectLibrary(nil) }
            } label: {
                if viewModel.selectedLibID == nil {
                    Label("全部", systemImage: "checkmark")
                } else {
                    Text("全部")
                }
            }
            ForEach(viewModel.libraries) { lib in
                Button {
                    Task { await viewModel.selectLibrary(lib.id) }
                } label: {
                    if lib.id == viewModel.selectedLibID {
                        Label(lib.name, systemImage: "checkmark")
                    } else {
                        Text(lib.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(viewModel.selectedLibrary?.name ?? "全部")
                    .font(.subheadline.weight(.medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(Theme.brand)
        }
    }
}

// MARK: - 影视卡
struct MediaCard: View {
    let item: MediaItem
    var coverURL: URL?
    var width: CGFloat = 150
    /// 横版封面（16:9）还是竖版海报（2:3）
    var landscape: Bool = false
    var onTap: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topTrailing) {
                RemoteImage(
                    url: coverURL,
                    fallbackIcon: item.type == "tv" ? "tv" : "film",
                    fallbackColors: Theme.placeholderGradient(for: .media)
                )
                .imageFilled()
                .frame(width: width, height: width * (landscape ? 9.0 / 16.0 : 3.0 / 2.0))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                // 横版右上角评分徽章（对齐网页版 MediaCard 的 ★ rating）
                if landscape, let r = item.rating, r > 0 {
                    Text(String(format: "★ %.1f", r))
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.6), in: Capsule())
                        .padding(6)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(width: width, alignment: .leading)
        }
        .frame(width: width)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color(uiColor: .separator).opacity(0.6), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.10), radius: 8, x: 0, y: 3)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}
