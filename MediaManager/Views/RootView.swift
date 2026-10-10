import SwiftUI
import UIKit

// MARK: - UIKit 干预：禁用 SplitView 边缘滑出 sidebar 的手势
// 列表页（.detailOnly）要求「右滑 = 返回上一页」，而不是滑出 sidebar。
// NavigationSplitView 底层是 UISplitViewController，默认 presentsWithGesture=true，
// 会在左缘右滑时临时滑出 sidebar，抢走 NavigationStack 的返回手势。
// 禁用它，让右滑交还给导航栈的 pop。
private func disableSplitSwipeGesture() {
    for scene in UIApplication.shared.connectedScenes {
        guard let ws = scene as? UIWindowScene else { continue }
        for window in ws.windows {
            if let split = findSplitVC(window.rootViewController) {
                split.presentsWithGesture = false
            }
        }
    }
}

private func findSplitVC(_ vc: UIViewController?) -> UISplitViewController? {
    guard let vc else { return nil }
    if let split = vc as? UISplitViewController { return split }
    for child in vc.children {
        if let found = findSplitVC(child) { return found }
    }
    return nil
}

// MARK: - 侧边栏导航项
enum SidebarSection: String, CaseIterable, Identifiable {
    case browse
    case library

    var id: String { rawValue }

    var title: String {
        switch self {
        case .browse: return "浏览"
        case .library: return "媒体库"
        }
    }
}

enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case home, resume, favorites, recent, discover
    case movie, photo, shoot, short

    var id: String { rawValue }

    var section: SidebarSection {
        switch self {
        case .home, .resume, .favorites, .recent, .discover: return .browse
        case .movie, .photo, .shoot, .short: return .library
        }
    }

    var title: String {
        switch self {
        case .home: return "首页"
        case .resume: return "继续观看"
        case .favorites: return "我的收藏"
        case .recent: return "最近入库"
        case .discover: return "发现"
        case .movie: return "电影"
        case .photo: return "相册"
        case .shoot: return "拍摄集"
        case .short: return "短视频"
        }
    }

    var systemImage: String {
        switch self {
        case .home: return "house.fill"
        case .resume: return "clock.fill"
        case .favorites: return "heart.fill"
        case .recent: return "bolt.fill"
        case .discover: return "sparkles"
        case .movie: return "film"
        case .photo: return "camera"
        case .shoot: return "photo.on.rectangle.angled"
        case .short: return "play.rectangle.fill"
        }
    }
}

// MARK: - 侧边栏可见性控制
// 需求：库卡片墙（tab 根页面）显示侧边栏；push 进「库内容列表页」后隐藏侧边栏且不可拉出。
// 通过共享 store 让根页面与列表页各自在 onAppear 时设置目标可见性。
final class SidebarStore: ObservableObject {
    static let shared = SidebarStore()
    @Published var visibility: NavigationSplitViewVisibility = .all
}

// MARK: - 根视图：三栏骨架
struct RootView: View {
    @StateObject private var viewModel = HomeViewModel()
    @ObservedObject private var sidebar = SidebarStore.shared
    @State private var selection: SidebarItem? = .home

    var body: some View {
        NavigationSplitView(columnVisibility: $sidebar.visibility) {
            List(selection: $selection) {
                ForEach(SidebarSection.allCases) { section in
                    Section(section.title) {
                        ForEach(SidebarItem.allCases.filter { $0.section == section }) { item in
                            Label(item.title, systemImage: item.systemImage)
                                .tag(item)
                        }
                    }
                }
                Section {
                    Button(role: .destructive) {
                        AppSession.shared.logout()
                    } label: {
                        Label("登出", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
            }
            .navigationTitle("媒体库")
        } detail: {
            NavigationStack {
                switch selection {
                case .home, .none:
                    HomeView(viewModel: viewModel)
                case .movie:
                    LibraryPickerView(type: "movie")
                case .photo:
                    LibraryPickerView(type: "photo")
                case .shoot:
                    LibraryPickerView(type: "shoot")
                case .short:
                    ShortsView()
                default:
                    PlaceholderView(item: selection ?? .home)
                }
            }
        }
        // 切换 tab（侧边栏选择变化）时恢复侧边栏显示，覆盖 ShortsView / 占位页等根页面
        .onChange(of: selection) { _, _ in
            sidebar.visibility = .all
        }
        .onAppear {
            // NavigationSplitView 的 UISplitViewController 在首帧后才完全就绪，
            // 延迟一帧再禁用其边缘滑出 sidebar 的手势
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                disableSplitSwipeGesture()
            }
        }
    }
}

// MARK: - 占位页（后续逐个实现）
struct PlaceholderView: View {
    let item: SidebarItem

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: item.systemImage)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text(item.title)
                .font(.title3.weight(.semibold))
            Text("该页面将在后续迭代中接入")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
