import SwiftUI

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

// MARK: - 根视图：三栏骨架
struct RootView: View {
    @StateObject private var viewModel = HomeViewModel()
    @State private var selection: SidebarItem? = .home
    /// 强制侧边栏常驻（横竖屏都显示）。
    /// 默认 .automatic 在 iPad 竖屏会把 sidebar 折叠成 overlay ——
    /// 一旦折叠，① 点进内容页时系统会自动展开 sidebar 盖住内容；
    /// ② 左缘右滑被「展开 sidebar」手势接管，NavigationStack 的返回手势失效。
    /// 常驻后两者都不再发生：右滑恢复为正常返回。
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
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
