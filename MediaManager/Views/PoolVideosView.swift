import SwiftUI

// MARK: - 池内视频墙
// 从 ShortsView 的池卡网格推进来：一个池（或「全部」）的视频封面墙。
// 结构 = 原短视频页的墙：搜索 + 排序 + 封面网格 + 点开连播 + 无限滚动。
//
// ⚠️ 与池网格的分工：这一页管「内容」，池网格管「选池」—— 对齐
// 相册详情 / 拍摄集详情与列表页的关系。标题不再用 navigationTitle：
// 页名跟在 ListSearchBarItem 的搜索框后面，同其他列表页。
struct PoolVideosView: View {
    let poolId: Int?
    let poolName: String

    @StateObject private var viewModel: ShortsViewModel
    /// 刷流呈现器：挂根层 overlay，右滑退出露出的是本页
    @ObservedObject private var feedPresenter = ShortFeedPresenter.shared
    /// 播放地址构造失败时给出明确原因，而不是静默什么都不发生
    @State private var playError: String?
    /// 窄屏（iPhone）：搜索框缩短、计数隐藏，避免导航栏一行塞不下。
    /// 与电影/相册/拍摄集列表同一判据，保证各页顶栏行为一致
    @Environment(\.horizontalSizeClass) private var hSizeClass

    private let gridSpacing: CGFloat = 12
    private let edgePadding: CGFloat = 16
    /// 封面高度写死成常量，不跟列宽挂钩。
    ///
    /// 短视频封面是 FFmpeg 抽帧，横屏 1920×1080 / 竖屏 1080×1920 / 4K 混在一起，
    /// 尺寸完全没有统一标准。只要行高还会随内容变（列宽测量、图片加载完成），
    /// LazyVGrid 就不会重算已布局的行 —— 表现就是卡片互相压住。
    /// 所以这里连列宽都不自己量，改用 adaptive 交给系统，高度保持常量。
    private let coverHeight: CGFloat = 240
    /// 标题区高度也写死，让整卡高度成为常量
    private let titleHeight: CGFloat = 28

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 160, maximum: 220), spacing: gridSpacing)]
    }

    init(poolId: Int?, poolName: String) {
        self.poolId = poolId
        self.poolName = poolName
        _viewModel = StateObject(wrappedValue: ShortsViewModel(poolId: poolId))
    }

    var body: some View {
        ScrollView {
            if viewModel.items.isEmpty && !viewModel.isLoading {
                ContentUnavailableView(viewModel.errorMessage ?? "暂无短视频",
                                       systemImage: viewModel.errorMessage == nil ? "play.rectangle.fill" : "exclamationmark.triangle")
                    .frame(maxWidth: .infinity, minHeight: 400)
            } else {
                LazyVGrid(columns: columns, spacing: gridSpacing) {
                    ForEach(viewModel.items) { v in
                        ShortCard(video: v, client: viewModel.client,
                                  coverHeight: coverHeight,
                                  titleHeight: titleHeight,
                                  cardHeight: coverHeight + titleHeight) {
                            guard let path = v.filePath, !path.isEmpty else {
                                playError = "这条记录没有文件路径"
                                return
                            }
                            guard let idx = viewModel.items.firstIndex(where: { $0.id == v.id }) else { return }
                            // 刷流在根层 overlay 打开：背后仍是本页（池内视频墙），
                            // 右滑退出就回到这里
                            feedPresenter.open(viewModel: viewModel, startIndex: idx)
                        }
                        .task {
                            if v.id == viewModel.items.last?.id { await viewModel.loadMore() }
                        }
                    }
                }
                .padding(edgePadding)
                if viewModel.isLoading {
                    ProgressView().frame(maxWidth: .infinity).padding()
                }
            }
        }
        // ⚠️ 每个 tab / 每个 push 进来的页面都要自己垫一层背景：
        // NavigationStack 只渲染栈顶那一层，App 根的背景透不进来
        .appBackground()
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
        // ⚠️ 顶部栏与电影/相册/拍摄集/演员四个列表页完全同构（ ListTopBar.swift 那套）：
        // ListSearchBarItem（靠左死宽搜索框 + 页名）+ TrailingToolsItem
        // （排序 / 降序 / 随机 / 计数，间距由 ToolbarMetrics 统一）。
        // 搜索词的防抖 reload 仍走上面的 .onChange(of: searchText)，换组件不影响。
        .toolbar {
            ListSearchBarItem(text: $viewModel.searchText,
                              placeholder: "搜索文件名…",
                              title: poolName,
                              narrow: hSizeClass == .compact)
            // 右侧整组收进一个 ToolbarItem：间距由 ToolbarMetrics 说了算，
            // 不再吃 ToolbarItemGroup 的系统默认间距
            TrailingToolsItem {
                sortMenu
                // 升/降序开关：只图标，箭头朝向即当前方向
                ToolChip(label: "降序", icon: viewModel.descending ? "arrow.down" : "arrow.up",
                         highlighted: viewModel.descending, iconOnly: true) {
                    Task { await viewModel.toggleDirection() }
                }
                // 随机起播：池内随机（「全部」页就是全库随机，同首页「连播」卡）
                ToolChip(label: "随机", icon: "shuffle", iconOnly: true) {
                    guard !viewModel.items.isEmpty else { return }
                    let idx = Int.random(in: 0..<viewModel.items.count)
                    feedPresenter.open(viewModel: viewModel, startIndex: idx)
                }
                if hSizeClass == .regular {
                    Text("\(viewModel.items.count) / \(viewModel.totalCount)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        // ⚠️ 不加 fixedSize：工具栏空间紧张时 Text 会被压缩换行，
                        // 变成「1234 / 5678」上下两行，把导航栏撑高
                        .fixedSize(horizontal: true, vertical: false)
                        .lineLimit(1)
                        // ⚠️ 给计数留固定槽位：整排锚定屏幕右缘，数字位数一变
                        // 整排按钮就被推着左右挪
                        .frame(minWidth: ToolbarMetrics.countMinWidth, alignment: .trailing)
                        // 与前面按钮的间隔独立于按钮间距（见 ToolbarMetrics.countGap）
                        .padding(.leading, ToolbarMetrics.countGap)
                }
            }
        }
        .tint(Theme.brand)
        .alert("无法播放", isPresented: Binding(
            get: { playError != nil },
            set: { if !$0 { playError = nil } }
        )) {
            Button("好", role: .cancel) { playError = nil }
        } message: {
            Text(playError ?? "")
        }
    }

    // MARK: 顶部栏控件（与电影/相册/拍摄集/演员列表同一套组件）

    /// 排序字段。ToolMenuChip 的 label 样式与工具栏其他胶囊一致
    private var sortMenu: some View {
        ToolMenuChip(label: viewModel.sort.label) {
            ForEach(ShortsViewModel.Sort.allCases, id: \.self) { s in
                Button {
                    Task { await viewModel.setSort(s) }
                } label: {
                    if viewModel.sort == s { Label(s.label, systemImage: "checkmark") }
                    else { Text(s.label) }
                }
            }
        }
    }
}
