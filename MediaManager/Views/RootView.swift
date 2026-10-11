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
    @State private var tab: RootTab = .home

    var body: some View {
        ZStack {
            NavigationStack { HomeView(viewModel: viewModel) }
                .opacity(tab == .home ? 1 : 0)
                .allowsHitTesting(tab == .home)

            NavigationStack { LibraryHomeView() }
                .opacity(tab == .library ? 1 : 0)
                .allowsHitTesting(tab == .library)

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
        }
    }
}

// MARK: - 底 bar
struct BottomTabBar: View {
    @Binding var selection: RootTab

    /// 底 bar 内容的宽度上限（四个 tab 在这条宽度里均分）。
    /// iPad 横屏有 1000+pt，均分铺满的话图标相距 250pt 以上，视线来回跑；
    /// 收到 360（每格 90）居中，既聚拢又不至于挤到「短视频」这种三字标签。
    private static let maxContentWidth: CGFloat = 360

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
        .frame(height: 52)  // 标准 tab bar 高度，不厚
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

    @State private var category: Category = .movie

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
    }
}
