import SwiftUI

// MARK: - 媒体库选择页（电影 / 相册 / 拍摄集 共用）
// 这三个 tab 现在先进来看到「有哪些媒体库」的卡片墙，
// 点某张库卡片再进该库的具体内容，而不是一进来就铺开全部内容。
struct LibraryPickerView: View {
    /// movie / photo / shoot
    let type: String

    @State private var libraries: [Library] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    /// 已加载过的分类。配合 loadIfNeeded 避免返回本页时重复加载
    @State private var loadedType: String?

    private let columns = [GridItem(.adaptive(minimum: 200), spacing: 16)]

    var body: some View {
        ScrollView {
            if libraries.isEmpty && !isLoading {
                ContentUnavailableView(errorMessage ?? "暂无媒体库",
                                       systemImage: errorMessage == nil ? emptyIcon : "exclamationmark.triangle")
                    .frame(maxWidth: .infinity, minHeight: 400)
            } else {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(libraries) { lib in
                        NavigationLink(value: lib) {
                            LibraryCard(library: lib)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(24)
                if isLoading {
                    ProgressView().frame(maxWidth: .infinity).padding()
                }
            }
        }
        // 顶 bar 已显示「电影 / 相册 / 拍摄集」，这里隐藏导航栏
        .toolbar(.hidden, for: .navigationBar)
        // ⚠️ 用 task(id: type)：顶 bar 切换分类时重新加载对应类型的媒体库
        .task(id: type) { await loadIfNeeded() }
        // 下拉刷新：保留旧数据，加载完替换（避免闪空）
        .refreshable { await load(clear: false) }
    }

    private var emptyIcon: String {
        switch type {
        case "movie": return "film"
        case "photo": return "camera"
        case "shoot": return "photo.on.rectangle.angled"
        default: return "externaldrive"
        }
    }

    /// 只在「没加载过当前分类」或「加载过但列表是空的（上次失败）」时才请求。
    ///
    /// ⚠️ 原来 .task 直接调 `load(clear: true)`，而它第一件事就是 `libraries = []`。
    /// 本页挂在「媒体库」tab 的 TabView(.page) 里 —— 从内容列表页右滑返回，
    /// 或在顶 bar 三个分类之间滑动切换，TabView 都会让本页重新 appear 并触发 .task，
    /// 于是卡片墙被清空再重新拉一次，表现就是「返回时闪一下、白屏一瞬」。
    /// 现在已有数据就原地不动，滚动位置也保住；真要刷新走下拉（.refreshable）。
    @MainActor
    private func loadIfNeeded() async {
        // 判 loadedType 而不是只判空：万一 SwiftUI 复用本页去显示别的分类，
        // 光看 libraries.isEmpty 会跳过加载，结果留着上一个分类的库卡片
        guard loadedType != type || libraries.isEmpty else { return }
        loadedType = type
        await load()
    }

    @MainActor
    private func load(clear: Bool = true) async {
        guard let client = AppSession.shared.client else {
            errorMessage = "未连接服务器"
            isLoading = false
            return
        }
        // 切换分类/首次加载才显示加载指示；下拉刷新（clear=false）用系统转圈，
        // ⚠️ 下拉刷新不碰 isLoading：isLoading 触发 body 重算会让 .refreshable 的
        // 刷新 Task 被取消（请求取消）。
        if clear {
            isLoading = true
            libraries = []  // 切换分类时清空，避免短暂显示上一分类的库
        }
        defer { if clear { isLoading = false } }
        do {
            libraries = try await client.libraries(ofType: type)
        } catch {
            libraries = []
            errorMessage = "加载媒体库失败"
        }
    }
}

// MARK: - 媒体库卡片
// 封面（库缩略图）+ 名称 + 条目数。卡片高度保持常量，避免网格重排。
private struct LibraryCard: View {
    let library: Library

    private var thumb: URL? {
        AppSession.shared.client?.resolve(library.thumbURL)
    }

    private var fallbackColors: [Color] {
        switch library.type {
        case "photo": return Theme.placeholderGradient(for: .photo)
        case "shoot": return Theme.placeholderGradient(for: .shoot)
        default: return Theme.placeholderGradient(for: .media)
        }
    }

    private var countText: String {
        switch library.type {
        case "photo": return "\(library.itemCount) 张照片"
        case "shoot": return "\(library.itemCount) 个拍摄集"
        default: return "\(library.itemCount) 部"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RemoteImage(url: thumb, fallbackIcon: "folder.fill",
                        fallbackColors: fallbackColors)
                .imageFilled()
                .frame(height: 130)
                .frame(maxWidth: .infinity)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(library.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(countText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 2)
            .padding(.top, 8)
            .padding(.bottom, 4)
        }
    }
}
