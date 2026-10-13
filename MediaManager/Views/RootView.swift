import SwiftUI

// MARK: - 全屏覆盖层状态
// 短视频刷流用 ZStack overlay 在 ShortsView 内呈现，但底 bar 在 RootView 的
// safeAreaInset 里、层级更高，刷流盖不住它。用这个共享单例在刷流打开时隐藏底 bar。
final class FullscreenOverlay: ObservableObject {
    static let shared = FullscreenOverlay()
    @Published var active = false
}

// MARK: - 根 tab（底 bar）
enum RootTab: String, CaseIterable, Identifiable {
    case home, library, short, mine

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "首页"
        case .library: return "媒体库"
        case .short: return "短视频"
        case .mine: return "我的"
        }
    }

    var systemImage: String {
        switch self {
        case .home: return "house.fill"
        case .library: return "square.grid.2x2.fill"
        case .short: return "play.rectangle.fill"
        case .mine: return "person.fill"
        }
    }
}

// MARK: - 根视图：底 bar 四 tab 骨架
// 改版：去掉侧边栏（NavigationSplitView），改常驻底 bar ——
// 首页 / 媒体库 / 短视频 / 我的。每个 tab 各自持有一个 NavigationStack，
// 用 opacity + allowsHitTesting 切换，保留各 tab 的导航栈状态。
// 「我的」tab 是 iOS 端唯一的账户入口（服务器信息 + 退出登录），
// 之前想换账号只能杀 App 重进。
struct RootView: View {
    @StateObject private var viewModel = HomeViewModel()
    @ObservedObject private var overlay = FullscreenOverlay.shared
    // 全局看图器：挂在最外层 overlay，替代各页面的 .fullScreenCover
    //（fullScreen 呈现会把底层页面移出窗口层级，退出时露出的不是上一级而是空窗口 → 闪白）
    @ObservedObject private var photoViewer = PhotoViewerPresenter.shared
    /// 短视频刷流（根层 overlay）：从哪个 tab 进来，右滑退出就露出哪个 tab
    @ObservedObject private var shortsFeed = ShortFeedPresenter.shared
    @State private var tab: RootTab = .home
    // 各 tab 的导航栈（正常页面跳转用；看图器「进入相册」不走导航栈，见下面的相册层）
    @State private var homePath = NavigationPath()
    @State private var libraryPath = NavigationPath()
    /// 媒体库 tab 内的二级分类（电影/相册/拍摄集）：提升到根，首页「拍摄集」卡
    /// 切 tab 的同时能落准分类（只切 tab 会落在默认的电影分类，卡等于半死）。
    /// 与 tab 对称：用户手动切分类也改这里，两边始终同源。
    @State private var libraryCategory: LibraryHomeView.Category = .movie

    var body: some View {
        ZStack {
            NavigationStack(path: $homePath) { HomeView(viewModel: viewModel, path: $homePath, tab: $tab, libraryCategory: $libraryCategory) }
                .opacity(tab == .home ? 1 : 0)
                .allowsHitTesting(tab == .home)

            NavigationStack(path: $libraryPath) { LibraryHomeView(category: $libraryCategory) }
                .opacity(tab == .library ? 1 : 0)
                .allowsHitTesting(tab == .library)

            // 短视频刷流（tab = .short 时初始化，之后不再传）
            NavigationStack { ShortsView() }
                .opacity(tab == .short ? 1 : 0)
                .allowsHitTesting(tab == .short)

            // 与首页共用同一份 viewModel：收藏 / 观看记录只拉一次，两边都能用
            NavigationStack { MineView(viewModel: viewModel) }
                .opacity(tab == .mine ? 1 : 0)
                .allowsHitTesting(tab == .mine)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            BottomTabBar(selection: $tab)
                .opacity(overlay.active ? 0 : 1)
                .allowsHitTesting(!overlay.active)
                // 渐隐渐显：硬切出现的话，退出刷流时会看到底栏「啪」地跳出来。
                // 时长对齐刷流滑出（0.28s），底栏是「随页面滑开慢慢浮现」而不是抢在前面冒头
                .animation(.easeOut(duration: 0.25), value: overlay.active)
        }
        // ⚠️ overlay 必须挂在 safeAreaInset **之后**（外层）：safeAreaInset 的内容
        // 合成在主内容之上，挂在它里面/之前会被底栏压住。看图器要盖住底栏。
        // 看图器和相册层放**同一个 ZStack** 里用 zIndex 排序：
        //  · 从详情卡片「进入相册」→ 相册层(z2)盖在看图器(z1)上；
        //  · 相册页里点照片 → 看图器临时升到 z3（viewerAboveAlbum）。
        // ⚠️ 相册层不能用系统 push：push 到 tab 导航栈的话看图器 overlay 比它高，
        // 只能先把看图器藏起来 → 交互式返回滑到一半时 path 还没变，半路露出照片流。
        // 相册层盖在看图器上，看图器全程可见，滑返回时下面实时露出看图器+详情卡片。
        .overlay {
            ZStack {
                if photoViewer.isVisible {
                    PhotoViewerView(
                        photos: photoViewer.photos,
                        index: photoViewer.startIndex,
                        hasMore: photoViewer.hasMore,
                        onLoadMore: photoViewer.onLoadMore,
                        onClose: { photoViewer.dismiss() }
                    )
                    // ⚠️ 用 generation 驱动重建：photos/index 是 PhotoViewerView 创建时的快照，
                    // 不响应 presenter.photos 变化。点击相似图单图覆盖（show 换照片数组）时，
                    // 必须重建视图才能显示新图，否则状态错乱黑屏。
                    .id(photoViewer.generation)
                    // 打开动画**内化**在 PhotoViewerView 里（图片层 openFade/openScale
                    // 缩放浮现），这里不给 transition：整层渐显会让黑底慢半拍才盖上，
                    // 状态栏只能延迟隐藏（消失得慢）。黑底必须插入即不透明。
                    // 退出同理不依赖 transition：close(after:) 自己把整层 closingFade
                    // 淡到 0，0.27s 后 dismiss 移除时层已全透明，无感。
                    .zIndex(photoViewer.viewerAboveAlbum ? 3 : 1)
                }
                if photoViewer.albumPageTarget != nil {
                    AlbumPageLayer(
                        target: photoViewer.albumPageTarget!,
                        // 根的背景 = openAlbum 时抓的整屏快照（看图器+详情卡片）。
                        // 透明根在系统 push/pop 过渡中背后是窗口底色（浅色=白）→ 大白屏，
                        // 详见 PhotoViewer.swift 里 AlbumPageLayer 的注释。
                        backdrop: photoViewer.albumBackdrop,
                        onClose: { photoViewer.closeAlbum() }
                    )
                    // 每次「进入相册」都重建图层（openAlbum 里 generation 自增）：
                    // 返回后有约 350ms 撤层等待期，期内再次进入也必须能重新 push。
                    .id(photoViewer.albumOpenGeneration)
                    .zIndex(2)
                    // 看图器叠在相册页之上时（相册页里点开了照片），相册页被全屏
                    // 盖住 → 关掉它的交互：省得它的 UIScrollView / 导航返回手势
                    // 识别器在图解器里跟看图器的下拉退出手势抢触摸。
                    .allowsHitTesting(!photoViewer.viewerAboveAlbum)
                }
                // 短视频刷流：挂在 tab 层之上（z4），右滑退出时露出的是它背后的
                // 那个 tab —— 首页卡进的露首页，短视频页点卡片进的露短视频页。
                // ⚠️ 不能挂在 ShortsView 内部：那样右滑露出的永远是短视频列表页。
                if shortsFeed.isActive, let vm = shortsFeed.viewModel {
                    ShortFeedView(viewModel: vm, startIndex: shortsFeed.startIndex,
                                  onClose: { shortsFeed.close() },
                                  onBeginExit: { shortsFeed.beginExit() })
                        // 每次打开都重建：起始下标是 init 时的快照（@State currentIndex）
                        .id(shortsFeed.generation)
                        .transition(.move(edge: .trailing))
                        .zIndex(4)
                }
            }
        }
        .animation(.easeIn(duration: 0.15), value: photoViewer.isVisible)
        // 刷流插入/移除动画（右滑入场 + 底栏同步淡出）
        .animation(.easeIn(duration: 0.15), value: shortsFeed.isActive)
        // overlay 里 .statusBarHidden 可能不生效，在根上按看图器显隐统一控制。
        // ⚠️ 绑 statusBarHidden 而不是 isVisible：退出淡出动画期间（isVisible 仍 true）
        // 状态栏就要开始恢复，与 closingFade 同步 —— 绑 isVisible 会晚 0.27s（dismiss
        // 那一刻才出现），背景页「先无状态栏、后突然有」就是退出时那一「抖」。
        // ⚠️ 必须叠 isVisible：只看图器可见时才允许它藏状态栏。
        // 否则任何一条退出路径漏恢复（异常退出、手势被系统取消、相册层组合），
        // 残留的 statusBarHidden=true 会让整个 App 永久没有状态栏。
        .statusBarHidden(photoViewer.isVisible && photoViewer.statusBarHidden)
        // ⚠️ 刷流**不参与**状态栏隐藏（试过两版都不行，见 ShortFeedView 注释）：
        // 状态栏的显示/隐藏是系统级的、无法动画，它一出现窗口 safeArea 就变，
        // 背后页面随之重排 —— 无论把恢复时机提前到动画开始还是等 close，
        // 用户都能看到那一下「闪」。所以刷流期间状态栏一直在，退出时零变化。
    }
}

// MARK: - 底 bar
struct BottomTabBar: View {
    @Binding var selection: RootTab

    /// 底 bar 内容的宽度上限（四个 tab 在这条宽度里均分）。
    /// iPad 横屏有 1000+pt，均分铺满的话图标相距 250pt 以上，视线来回跑；
    /// 收到 360（每格 90）居中，既聚拢又不至于挤到「短视频」这种三字标签。
    private static let maxContentWidth: CGFloat = 360

    /// 底栏高度。页面滚动内容的底部净空（bottomBarClearance）引用它，
    /// 改这里一处，所有页面的避让高度跟着变。
    static let height: CGFloat = 52

    var body: some View {
        // ⚠️ 别写死 spacing：三个 tab 时 44 还够，四个 tab 在窄屏（iPhone）上
        // 会挤出屏幕外。改成每格 maxWidth:.infinity 均分，tab 增减都不用调数字。
        HStack(spacing: 0) {
            ForEach(RootTab.allCases) { tab in
                Button {
                    selection = tab
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: tab.systemImage)
                            .font(.system(size: 21, weight: .semibold))
                        Text(tab.title)
                            .font(.caption2.weight(.medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(selection == tab ? Theme.brand : Color.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        // 内容不铺满整屏：四个 tab 均分到 iPad 的宽屏上会散得很开，
        // 限一个宽度上限并居中，让图标往中间聚拢。
        // ⚠️ 用 maxWidth 而不是 width：屏幕比它更窄时（小屏 iPhone）自动退回铺满，
        //    不会因为撑不下而溢出去。要再紧一点就把这个数字调小。
        .frame(maxWidth: Self.maxContentWidth)
        .frame(maxWidth: .infinity)
        .frame(height: Self.height)  // 标准 tab bar 高度，不厚
        .padding(.horizontal, 8)
        .background(
            // 底栏毛玻璃：直接用材质。它会自动模糊身后 App 根的那张背景图
            //（MediaManagerApp 根上有全局 .appBackground()），同时透出图。
            //
            // ⚠️⚠️ 这里绝对不能放 AppBackgroundView / ignoresSafeArea 的大图层：
            // 底栏在 safeAreaInset 里，这一层合成在主内容**之上**，
            // 内部视图一 ignoresSafeArea 就被提案成全屏 —— 整条毛玻璃会盖到
            // 所有页面内容上面（真实事故：海报被拦腰糊住、文字全看不见）。
            .ultraThinMaterial
        )
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color(uiColor: .separator).opacity(0.5))
                .frame(height: 0.5)
        }
    }
}

// MARK: - 底栏净空
// ⚠️ 为什么需要它：RootView 用 safeAreaInset 挂底栏，理论上滚动内容会自动避让，
// 但实测滚动内容滑到底还是会被底栏盖住（「我的」页的退出登录按钮尤其明显）——
// 页面根上的 .appBackground()（背景层 ignoresSafeArea）会让 NavigationStack 里的
// UIScrollView 丢掉底部安全区避让，safeAreaInset 的附加安全区也传不进去。
//
// 所以给每个竖向滚动页的内容加一段纯布局 padding 兜底：不依赖安全区机制，
// 任何机型都不会失手。加在滚动内容**里面**（而不是 ScrollView 上），
// 不影响页面自身的背景铺满，也不影响页面内的横滑行。
extension View {
    func bottomBarClearance() -> some View {
        padding(.bottom, BottomTabBar.height)
    }
}

// MARK: - 媒体库页（顶 bar 切换电影 / 相册 / 拍摄集）
struct LibraryHomeView: View {
    enum Category: String, CaseIterable, Identifiable {
        case movie, photo, shoot

        var id: String { rawValue }

        var title: String {
            switch self {
            case .movie: return "电影"
            case .photo: return "相册"
            case .shoot: return "拍摄集"
            }
        }

        var type: String { rawValue }
    }

    /// 当前二级分类：由根视图持有（binding），首页「拍摄集」卡跨 tab 落准分类用
    @Binding var category: Category

    var body: some View {
        VStack(spacing: 0) {
            // 顶 bar：电影 / 相册 / 拍摄集（居中）
            HStack(spacing: 6) {
                ForEach(Category.allCases) { c in
                    Button {
                        category = c
                    } label: {
                        Text(c.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(category == c ? Color.white : Color.primary)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 8)
                            .background(
                                category == c
                                    ? Theme.brand
                                    : Color(uiColor: .secondarySystemBackground),
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            // 三个分类可左右滑动切换（顶 bar 点击与滑动双向同步）
            TabView(selection: $category) {
                ForEach(Category.allCases) { c in
                    LibraryPickerView(type: c.type)
                        .tag(c)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        // navigationDestination 统一挂在这里（而不是每个 LibraryPickerView 各挂一个）。
        // TabView(.page) 会同时挂载三个 page，三个 page 各自声明同类型 destination
        // 会互相冲突 → NavigationLink push 失效（卡片点了没反应）。这里只声明一次。
        .navigationDestination(for: Library.self) { lib in
            switch category {
            case .movie: MediaListView(type: "movie", library: lib)
            case .photo: AlbumListView(library: lib)
            case .shoot: ShootListView(library: lib)
            }
        }
        // ⚠️ TabView(.page) 底层是 UIPageViewController，它自带不透明底色，
        // 只靠 App 根的那层背景透不出来 —— 本页必须自己垫一层
        .appBackground()
    }
}
