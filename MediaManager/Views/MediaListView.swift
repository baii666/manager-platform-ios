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
    /// 视图方向：false = 竖版海报，true = 横版封面（fanart）
    @Published var landscape = false
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
    @State private var selected: MediaItem?
    /// 卡片最小宽度（尺寸档位：小 120 / 中 150 / 大 190）
    @State private var cardWidth: CGFloat = 150

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: cardWidth), spacing: 18)]
    }

    init(type: String, library: Library? = nil) {
        self.type = type
        self.library = library
        _viewModel = StateObject(wrappedValue: MediaListViewModel(type: type, library: library))
    }

    var body: some View {
        VStack(spacing: 0) {
            // 顶部状态栏（独立、美观）
            VStack(spacing: 10) {
                ListSearchBar(text: $viewModel.searchText, placeholder: "搜索标题、演员、类型…")
                HStack(spacing: 8) {
                    sortMenu
                    ToolChip(label: viewModel.landscape ? "横版" : "竖版",
                             icon: viewModel.landscape ? "rectangle" : "rectangle.portrait",
                             highlighted: viewModel.landscape) {
                        viewModel.landscape.toggle()
                    }
                    sizeMenu
                    Spacer()
                    Text("\(viewModel.items.count) / \(viewModel.totalCount)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 4)

            ScrollView {
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(viewModel.items) { item in
                        let cover = AppSession.shared.client?.mediaCoverURL(item, landscape: viewModel.landscape)
                        MediaCard(item: item, coverURL: cover, landscape: viewModel.landscape) {
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
                if viewModel.isLoading {
                    ProgressView().frame(maxWidth: .infinity).padding()
                }
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

    /// 尺寸档位
    private var sizeMenu: some View {
        ToolMenuChip(label: sizeLabel, icon: "arrow.up.left.and.arrow.down.right") {
            Button { cardWidth = 120 } label: { Label("小", systemImage: cardWidth == 120 ? "checkmark" : "square") }
            Button { cardWidth = 150 } label: { Label("中", systemImage: cardWidth == 150 ? "checkmark" : "square") }
            Button { cardWidth = 190 } label: { Label("大", systemImage: cardWidth == 190 ? "checkmark" : "square") }
        }
    }

    private var sizeLabel: String {
        switch cardWidth {
        case 120: return "小"
        case 190: return "大"
        default: return "中"
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
            RemoteImage(
                url: coverURL,
                fallbackIcon: item.type == "tv" ? "tv" : "film",
                fallbackColors: Theme.placeholderGradient(for: .media)
            )
            .imageFilled()
            .frame(width: width, height: width * (landscape ? 9.0 / 16.0 : 3.0 / 2.0))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

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
