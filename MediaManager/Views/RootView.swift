import SwiftUI

// MARK: - 根 tab（底 bar）
enum RootTab: String, CaseIterable, Identifiable {
    case home, library, short

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "首页"
        case .library: return "媒体库"
        case .short: return "短视频"
        }
    }

    var systemImage: String {
        switch self {
        case .home: return "house.fill"
        case .library: return "square.grid.2x2.fill"
        case .short: return "play.rectangle.fill"
        }
    }
}

// MARK: - 根视图：底 bar 三 tab 骨架
// 改版：去掉侧边栏（NavigationSplitView），改常驻底 bar 三个 tab ——
// 首页 / 媒体库 / 短视频。每个 tab 各自持有一个 NavigationStack，
// 用 opacity + allowsHitTesting 切换，保留各 tab 的导航栈状态。
struct RootView: View {
    @StateObject private var viewModel = HomeViewModel()
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
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            BottomTabBar(selection: $tab)
        }
    }
}

// MARK: - 底 bar
struct BottomTabBar: View {
    @Binding var selection: RootTab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(RootTab.allCases) { tab in
                Button {
                    selection = tab
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.systemImage)
                            .font(.system(size: 22, weight: .semibold))
                        Text(tab.title)
                            .font(.caption2.weight(.medium))
                    }
                    .foregroundStyle(selection == tab ? Theme.brand : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .background(Color(uiColor: .systemBackground))
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
            // 顶 bar：电影 / 相册 / 拍摄集
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
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            // 库卡片墙
            LibraryPickerView(type: category.type)
        }
    }
}
