import SwiftUI

// MARK: - 拍摄集列表页
// 对齐网页端 ShootListPage：网格 + 搜索 + 排序 + 库选择
struct ShootListView: View {
    let library: Library?

    @StateObject private var viewModel: ShootListViewModel
    @State private var selected: Shoot?
    /// 窄屏（iPhone）下隐藏计数，避免导航栏一行塞不下
    @Environment(\.horizontalSizeClass) private var hSizeClass

    private let columns = [GridItem(.adaptive(minimum: 200), spacing: 16)]

    init(library: Library? = nil) {
        self.library = library
        _viewModel = StateObject(wrappedValue: ShootListViewModel(library: library))
    }

    var body: some View {
        ScrollView {
            if viewModel.items.isEmpty && !viewModel.isLoading {
                ContentUnavailableView(viewModel.errorMessage ?? "暂无拍摄集",
                                       systemImage: viewModel.errorMessage == nil ? "photo.on.rectangle.angled" : "exclamationmark.triangle")
                    .frame(maxWidth: .infinity, minHeight: 400)
            } else {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(viewModel.items) { shoot in
                        ShootCard(shoot: shoot, client: viewModel.client) {
                            selected = shoot
                        }
                        .task {
                            if shoot.id == viewModel.items.last?.id { await viewModel.loadMore() }
                        }
                    }
                }
                .padding(16)
                if viewModel.isLoading {
                    ProgressView().frame(maxWidth: .infinity).padding()
                }
            }
        }
        // ⚠️ 导航栏必须保持可见（隐藏会让系统右滑返回失效，而 NavigationStack
        // push 后不渲染下一层，自定义手势只能推出白屏）。搜索框放 principal 位，
        // 导航栏因而不额外占高度，系统返回按钮正好在搜索框左边。
        // ⚠️ 系统返回按钮必须留着：藏了它右滑手势会一起没（见 MediaListView 注释）
        .toolbar {
            // 靠左 + 固定宽度（ListSearchBarItem.width），三个列表页共用同一个组件；
            // 媒体库名跟在搜索框后面（可拉长，宽度不够才尾部省略）
            ListSearchBarItem(text: $viewModel.searchText,
                              placeholder: "搜索拍摄集…",
                              title: library?.name ?? "拍摄集",
                              narrow: hSizeClass == .compact)
            // 原来网格上方的工具行整行收进导航栏，页面只剩导航栏一行
            ToolbarItemGroup(placement: .topBarTrailing) {
                sortMenu
                // 固定库模式不显示库筛选
                if library == nil && !viewModel.libraries.isEmpty { libraryMenu }
                if hSizeClass == .regular {
                    Text("\(viewModel.items.count) / \(viewModel.totalCount)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        // ⚠️ 不加 fixedSize：工具栏空间紧张时 Text 会被压缩换行，
                        // 变成「1234 / 5678」上下两行，把导航栏撑高
                        .fixedSize(horizontal: true, vertical: false)
                        .lineLimit(1)
                }
            }
            .withoutGlass()
        }
        .tint(Theme.brand)
        .navigationBarTitleDisplayMode(.inline)
        // 下拉刷新
        .refreshable { await viewModel.refresh() }
        // ⚠️ iOS 17 起 `onChange(of:) { newValue in }`（单参数）已废弃，用零参数闭包
        .onChange(of: viewModel.searchText) {
            Task {
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled else { return }
                await viewModel.reload()
            }
        }
        .task { await viewModel.loadInitial() }
        .navigationDestination(item: $selected) { shoot in
            ShootDetailView(shoot: shoot)
        }
    }

    /// 排序选择（对齐电影/相册列表页的胶囊样式）
    private var sortMenu: some View {
        ToolMenuChip(label: viewModel.sort.label) {
            ForEach(ShootListViewModel.Sort.allCases, id: \.self) { s in
                Button {
                    Task { await viewModel.setSort(s) }
                } label: {
                    if viewModel.sort == s { Label(s.label, systemImage: "checkmark") }
                    else { Text(s.label) }
                }
            }
        }
    }

    private var libraryMenu: some View {
        Menu {
            Button { Task { await viewModel.selectLibrary(nil) } } label: {
                if viewModel.selectedLibID == nil { Label("全部", systemImage: "checkmark") } else { Text("全部") }
            }
            ForEach(viewModel.libraries) { lib in
                Button { Task { await viewModel.selectLibrary(lib.id) } } label: {
                    if lib.id == viewModel.selectedLibID { Label(lib.name, systemImage: "checkmark") }
                    else { Text(lib.name) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(viewModel.selectedLibrary?.name ?? "全部")
                    .font(.subheadline.weight(.medium))
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
            }
            // 与整条状态栏（含计数）统一成次级灰
            .foregroundStyle(.secondary)
        }
        // ⚠️ Menu 是控件，页面上的 .tint(Theme.brand) 会盖掉 label 里的
        // foregroundStyle（标题和展开后的菜单都变品牌色），必须给控件本身换 tint
        .tint(Color.secondary)
    }
}

// MARK: - 拍摄集列表 VM
final class ShootListViewModel: ObservableObject {
    enum Sort: String, CaseIterable, Sendable {
        case mtime, name, size
        var label: String {
            switch self { case .mtime: return "最新修改"; case .name: return "名称"; case .size: return "大小" }
        }
    }

    /// 固定库模式：从「媒体库卡片墙」点进来时传入，直接看该库内容
    let fixedLibrary: Library?

    @Published var items: [Shoot] = []
    @Published var libraries: [Library] = []
    @Published var selectedLibID: Int?
    @Published var searchText = ""
    @Published var sort: Sort = .mtime
    @Published var totalCount = 0
    @Published var isLoading = false
    @Published var errorMessage: String?

    var client: APIClient? { AppSession.shared.client }
    var selectedLibrary: Library? { libraries.first { $0.id == selectedLibID } }

    private var page = 1
    private let pageSize = 30
    private var hasMore = true

    init(library: Library? = nil) {
        self.fixedLibrary = library
        self.selectedLibID = library?.id
    }

    @MainActor
    func loadInitial() async {
        if fixedLibrary != nil {
            // 固定库：直接加载内容，不拉库列表
            guard items.isEmpty else { return }
            await reload()
            return
        }
        await loadLibraries()
        // 同 AlbumListView：从详情返回本页时 .task 可能重跑，此时 reload 会清空 items
        // 让 ScrollView 弹回顶部。已有数据就跳过，保住滚动位置。
        // 搜索 / 换库 / 换排序仍各自直接调 reload()，不受影响。
        guard items.isEmpty else { return }
        await reload()
    }

    @MainActor
    func loadLibraries() async {
        guard let client else { return }
        // ⚠️ 用精确 type 匹配（shoot 库 type 就是 "shoot"，不是 movie/mixed）
        do { libraries = try await client.libraries(ofType: "shoot") } catch { libraries = [] }
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
        // 搜索词变化由 searchable 的 onAppear/change 触发，这里统一重置
        items = []
        page = 1
        hasMore = true
        await loadMore()
    }

    /// 下拉刷新：保留旧列表，加载第一页后替换（避免闪空）。
    /// ⚠️ 不碰 isLoading（触发 body 重算会让 .refreshable 的刷新 Task 被取消），
    /// 刷新指示由系统 refreshable 转圈承担。
    @MainActor
    func refresh() async {
        guard let client, !isLoading else { return }
        page = 1
        hasMore = true
        do {
            let (batch, total) = try await client.fetchShoots(
                libraryId: selectedLibID, page: page, size: pageSize,
                sort: sort.rawValue, search: searchText.isEmpty ? nil : searchText)
            totalCount = total
            items = batch
            page += 1
            hasMore = !batch.isEmpty && items.count < total
        } catch {
            errorMessage = "加载失败 · \(describe(error))"
        }
    }

    @MainActor
    func loadMore(replacing: Bool = false) async {
        guard let client, !isLoading, hasMore else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let (batch, total) = try await client.fetchShoots(
                libraryId: selectedLibID, page: page, size: pageSize,
                sort: sort.rawValue, search: searchText.isEmpty ? nil : searchText)
            totalCount = total
            if replacing {
                items = batch
            } else {
                items.append(contentsOf: batch)
            }
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

// MARK: - 拍摄集卡
struct ShootCard: View {
    let shoot: Shoot
    let client: APIClient?
    var onTap: () -> Void

    private var coverURL: URL? {
        client?.shootCoverURL(shoot.id, size: 600)
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 0) {
                RemoteImage(url: coverURL, fallbackIcon: "photo.on.rectangle.angled",
                            fallbackColors: Theme.placeholderGradient(for: .shoot))
                    // 同短视频卡：封面是抽帧产物，横竖分辨率不一，必须钉进容器尺寸里
                    .imageFilled()
                    .frame(height: 130)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .overlay(alignment: .topTrailing) {
                        HStack(spacing: 6) {
                            if shoot.videoCount > 0 {
                                badge("\(shoot.videoCount)", systemImage: "film")
                            }
                            if shoot.photoCount > 0 {
                                badge("\(shoot.photoCount)", systemImage: "photo")
                            }
                        }
                        .padding(6)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if shoot.totalDuration > 0 {
                            Text(formatDuration(Int(shoot.totalDuration)))
                                .font(.caption2.weight(.semibold)).monospacedDigit()
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(.black.opacity(0.6), in: Capsule())
                                .padding(6)
                        }
                    }

                VStack(alignment: .leading, spacing: 4) {
                    Text(shoot.title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    HStack(spacing: 8) {
                        if let size = formatSize(shoot.totalSize) {
                            Label(size, systemImage: "internaldrive").font(.caption2)
                        }
                        if shoot.totalDuration > 0 {
                            Label(formatDuration(Int(shoot.totalDuration)), systemImage: "clock").font(.caption2)
                        }
                    }
                    .foregroundStyle(.secondary)
                }
                .padding(10)
            }
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.separator))
        }
        .buttonStyle(.plain)
    }

    private func badge(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(.black.opacity(0.6), in: Capsule())
    }
}

// MARK: - 格式化
func formatDuration(_ seconds: Int) -> String {
    guard seconds > 0 else { return "0:00" }
    let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
    return h > 0 ? "\(h):\(String(format: "%02d:%02d", m, s))" : "\(m):\(String(format: "%02d", s))"
}

func formatSize(_ bytes: Int64) -> String? {
    guard bytes > 0 else { return nil }
    let units = ["B", "KB", "MB", "GB", "TB"]
    let i = min(units.count - 1, Int(log(Double(bytes)) / log(1024)))
    return String(format: "%.1f %@", Double(bytes) / pow(1024, Double(i)), units[i])
}
